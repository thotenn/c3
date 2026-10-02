defmodule C3.Metrics do
  @moduledoc """
  The operational numbers of C3 (spec, *Roadmap › Pulido*): counters fed by `:telemetry`
  events the domain emits, and gauges read from the database when asked.

  | Metric | Kind | Source |
  |---|---|---|
  | `c3_sessions_created_total` | counter | `[:c3, :session, :created]` |
  | `c3_sessions_closed_total{reason}` | counter | `[:c3, :session, :closed]` (`manual`, `idle`, `max_ttl`, `admin`) |
  | `c3_join_failures_total{reason}` | counter | `[:c3, :join, :failed]` (`invalid_secret`, `unknown_code`, `session_closed`, `joins_locked`) |
  | `c3_ip_bans_total{reason}` | counter | `[:c3, :ip, :banned]` |
  | `c3_long_poll_duration_seconds{outcome}` | histogram | `[:c3, :long_poll, :stop]` — `immediate` (events were there), `woken` (one arrived while waiting), `timeout` |
  | `c3_sessions_open` · `c3_agents_active` · `c3_ip_bans_active` · `c3_attachments_bytes` | gauge | the database, at read time |

  Counters live in an ETS table owned by this process and start at zero with the node: a
  Prometheus server computes rates from them, and the admin shows them "since start". They
  are served as Prometheus text at `GET /metrics` (`C3Web.MetricsController`, only with
  `C3_METRICS_TOKEN`) and as a panel of the admin pages (`snapshot/0`).
  """
  use GenServer

  import Ecto.Query

  alias C3.Repo
  alias C3.Security.IpBan
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.Attachment

  @table __MODULE__
  @buckets [0.1, 0.5, 1, 5, 10, 20, 30, 60]

  @events [
    [:c3, :session, :created],
    [:c3, :session, :closed],
    [:c3, :join, :failed],
    [:c3, :ip, :banned],
    [:c3, :long_poll, :stop]
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :telemetry.attach_many("c3-metrics", @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach("c3-metrics")

  @doc false
  def handle_event([:c3, :session, :created], _m, _meta, _),
    do: inc({:sessions_created, nil})

  def handle_event([:c3, :session, :closed], _m, meta, _),
    do: inc({:sessions_closed, meta.reason})

  def handle_event([:c3, :join, :failed], _m, meta, _), do: inc({:join_failures, meta.reason})
  def handle_event([:c3, :ip, :banned], _m, meta, _), do: inc({:ip_bans, meta.reason})

  def handle_event([:c3, :long_poll, :stop], %{duration: duration}, meta, _) do
    seconds = System.convert_time_unit(duration, :native, :microsecond) / 1_000_000
    outcome = meta.outcome

    for le <- @buckets, seconds <= le, do: inc({:long_poll_bucket, outcome, le})
    inc({:long_poll_count, outcome})
    add({:long_poll_sum_us, outcome}, round(seconds * 1_000_000))
  end

  defp inc(key), do: add(key, 1)

  # A no-op before the table exists (a test that runs a domain function without the app).
  defp add(key, n) do
    :ets.update_counter(@table, key, n, {key, 0})
  rescue
    ArgumentError -> :ok
  end

  ## Emitting (called by the domain)

  @doc "Emits a C3 telemetry event with no measurements."
  def emit(event, meta \\ %{}), do: :telemetry.execute([:c3 | event], %{}, meta)

  ## Reading

  @doc "The current value of every metric, for the admin panel."
  def snapshot do
    counters = counters()

    %{
      gauges: gauges(),
      sessions_created: Map.get(counters, {:sessions_created, nil}, 0),
      sessions_closed: labelled(counters, :sessions_closed),
      join_failures: labelled(counters, :join_failures),
      ip_bans: labelled(counters, :ip_bans),
      long_poll:
        for {{:long_poll_count, outcome}, count} <- counters, into: %{} do
          sum = Map.get(counters, {:long_poll_sum_us, outcome}, 0) / 1_000_000
          {outcome, %{count: count, mean_seconds: if(count > 0, do: sum / count, else: 0.0)}}
        end
    }
  end

  @doc "Every metric in the Prometheus text exposition format."
  def prometheus do
    counters = counters()
    gauges = gauges()

    [
      counter("c3_sessions_created_total", "Sessions created", [
        {[], Map.get(counters, {:sessions_created, nil}, 0)}
      ]),
      counter(
        "c3_sessions_closed_total",
        "Sessions closed, by reason",
        by(counters, :sessions_closed, "reason")
      ),
      counter(
        "c3_join_failures_total",
        "Failed joins, by reason",
        by(counters, :join_failures, "reason")
      ),
      counter("c3_ip_bans_total", "IP bans issued, by reason", by(counters, :ip_bans, "reason")),
      histogram(counters),
      gauge("c3_sessions_open", "Open sessions", gauges.sessions_open),
      gauge("c3_agents_active", "Active agents in open sessions", gauges.agents_active),
      gauge("c3_ip_bans_active", "IP bans in force", gauges.ip_bans_active),
      gauge("c3_attachments_bytes", "Bytes of attachments stored", gauges.attachments_bytes)
    ]
    |> IO.iodata_to_binary()
  end

  defp counters do
    @table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  defp labelled(counters, name) do
    for {{^name, label}, value} <- counters, into: %{}, do: {label, value}
  end

  defp by(counters, name, label) do
    counters
    |> labelled(name)
    |> Enum.sort()
    |> Enum.map(fn {value, n} -> {[{label, value}], n} end)
  end

  defp gauges do
    now = DateTime.utc_now()

    %{
      sessions_open: Repo.aggregate(from(s in Session, where: s.status == :open), :count),
      agents_active:
        Repo.aggregate(
          from(a in Agent,
            join: s in Session,
            on: s.id == a.session_id,
            where: a.status == :active and s.status == :open
          ),
          :count
        ),
      ip_bans_active:
        Repo.aggregate(
          from(b in IpBan, where: b.banned_until > ^now and is_nil(b.lifted_at)),
          :count
        ),
      attachments_bytes: attachments_bytes()
    }
  end

  defp attachments_bytes do
    files =
      from a in Attachment,
        group_by: [a.session_id, a.storage_key],
        select: %{size: max(a.size_bytes)}

    Repo.one(from f in subquery(files), select: coalesce(sum(f.size), 0)) || 0
  end

  defp counter(name, help, samples) do
    [
      header(name, help, "counter")
      | Enum.map(samples, fn {labels, v} -> sample(name, labels, v) end)
    ]
  end

  defp gauge(name, help, value), do: [header(name, help, "gauge"), sample(name, [], value)]

  defp histogram(counters) do
    name = "c3_long_poll_duration_seconds"

    outcomes =
      for {{:long_poll_count, outcome}, _} <- counters, do: outcome

    samples =
      for outcome <- Enum.sort(outcomes) do
        labels = [{"outcome", outcome}]
        count = Map.fetch!(counters, {:long_poll_count, outcome})
        sum = Map.get(counters, {:long_poll_sum_us, outcome}, 0) / 1_000_000

        buckets =
          for le <- @buckets do
            n = Map.get(counters, {:long_poll_bucket, outcome, le}, 0)
            sample(name <> "_bucket", labels ++ [{"le", le}], n)
          end

        [
          buckets,
          sample(name <> "_bucket", labels ++ [{"le", "+Inf"}], count),
          sample(name <> "_sum", labels, sum),
          sample(name <> "_count", labels, count)
        ]
      end

    [header(name, "Long-poll wait, by outcome", "histogram") | samples]
  end

  defp header(name, help, type),
    do: ["# HELP ", name, " ", help, "\n# TYPE ", name, " ", type, "\n"]

  defp sample(name, [], value), do: [name, " ", number(value), "\n"]

  defp sample(name, labels, value) do
    pairs = Enum.map_join(labels, ",", fn {k, v} -> ~s(#{k}="#{v}") end)
    [name, "{", pairs, "} ", number(value), "\n"]
  end

  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp number(value), do: to_string(value)
end
