defmodule C3Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use C3Web, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The layout of every page: the C3 header and the flash. `admin` adds the admin's
  navigation and logout; `wide` drops the reading width for the admin tables.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :admin, :boolean, default: false, doc: "show the admin navigation"
  attr :wide, :boolean, default: false, doc: "use the full width"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-base-300 px-4 sm:px-6">
      <div class={[
        "mx-auto flex items-center justify-between gap-4 py-3",
        if(@wide, do: "max-w-7xl", else: "max-w-3xl")
      ]}>
        <.link
          navigate={if @admin, do: ~p"/admin", else: ~p"/"}
          class="flex items-baseline gap-2"
        >
          <span class="font-mono text-lg font-bold tracking-tight">C3</span>
          <span :if={@admin} class="text-xs uppercase tracking-widest text-base-content/60">
            admin
          </span>
        </.link>
        <nav class="flex items-center gap-3 text-sm">
          <.link
            :if={@admin}
            navigate={~p"/admin"}
            class="rounded px-2 py-1 hover:bg-base-200 transition-colors"
          >
            Sessions
          </.link>
          <.link
            :if={@admin}
            id="admin-logout"
            href={~p"/admin/logout"}
            method="delete"
            class="rounded px-2 py-1 hover:bg-base-200 transition-colors"
          >
            Log out
          </.link>
          <.theme_toggle />
        </nav>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6">
      <div class={["mx-auto space-y-6", if(@wide, do: "max-w-7xl", else: "max-w-3xl")]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
