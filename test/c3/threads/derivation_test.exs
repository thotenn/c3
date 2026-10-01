defmodule C3.Threads.DerivationTest do
  use ExUnit.Case, async: true

  alias C3.Threads.Derivation

  r = fn state, to, claimed_by -> %{state: state, to: to, claimed_by: claimed_by} end

  # {case, finished?, requests, status, awaiting, processing_by}
  cases = [
    {"no requests at all", false, [], :answered, [], []},
    {"one open request", false, [r.(:open, "AG2", nil)], :pending, ["AG2"], []},
    {"two open, one per target", false, [r.(:open, "AG2", nil), r.(:open, "AG3", nil)], :pending,
     ["AG2", "AG3"], []},
    {"AG2 answered, AG3 still open", false, [r.(:done, "AG2", "AG2"), r.(:open, "AG3", nil)],
     :pending, ["AG3"], []},
    {"open wins over claimed", false, [r.(:claimed, "AG2", "AG2"), r.(:open, "AG3", nil)],
     :pending, ["AG3"], ["AG2"]},
    {"only claimed", false, [r.(:claimed, "any", "AG4")], :processing, [], ["AG4"]},
    {"two claimers", false, [r.(:claimed, "AG2", "AG2"), r.(:claimed, "label:qa", "AG5")],
     :processing, [], ["AG2", "AG5"]},
    {"everything done", false, [r.(:done, "AG2", "AG2"), r.(:done, "any", "AG3")], :answered, [],
     []},
    {"done and cancelled", false, [r.(:done, "AG2", "AG2"), r.(:cancelled, "AG3", nil)],
     :answered, [], []},
    {"label and any targets", false, [r.(:open, "label:backend", nil), r.(:open, "any", nil)],
     :pending, ["label:backend", "any"], []},
    {"repeated target listed once", false,
     [r.(:open, "AG2", nil), r.(:done, "AG2", "AG2"), r.(:open, "AG2", nil)], :pending, ["AG2"],
     []},
    {"finished, nothing pending", true, [r.(:done, "AG2", "AG2")], :finished, [], []},
    {"finished after force", true, [r.(:cancelled, "AG2", nil), r.(:cancelled, "any", nil)],
     :finished, [], []},
    {"finished wins over everything (rule 1)", true,
     [r.(:open, "AG2", nil), r.(:claimed, "AG3", "AG3")], :finished, ["AG2"], ["AG3"]}
  ]

  for {name, finished?, requests, status, awaiting, processing_by} <- cases do
    test name do
      assert Derivation.derive(unquote(finished?), unquote(Macro.escape(requests))) == %{
               status: unquote(status),
               awaiting: unquote(awaiting),
               processing_by: unquote(processing_by)
             }
    end
  end
end
