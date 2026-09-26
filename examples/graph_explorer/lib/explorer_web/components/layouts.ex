defmodule ExplorerWeb.Layouts do
  use ExplorerWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title default="Graph Explorer" suffix=" · ash_glider">
          {assigns[:page_title]}
        </.live_title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/vendor/phoenix/phoenix.min.js">
        </script>
        <script defer src="/vendor/lv/phoenix_live_view.min.js">
        </script>
        <script defer src="/assets/graph.js">
        </script>
        <script defer src="/assets/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  attr :flash, :map, required: true
  attr :counts, :map, default: %{}
  attr :current_path, :string, default: "/"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="shell">
      <aside class="sidebar">
        <.link navigate="/" class="brand">
          <span class="brand-mark">◉</span>
          <span>
            <strong>Graph Explorer</strong>
            <small>Ash + glider</small>
          </span>
        </.link>

        <nav>
          <.nav_link path="/" current={@current_path} icon="▦">Overview</.nav_link>
          <.nav_link path="/query" current={@current_path} icon="⌕">Query</.nav_link>

          <div class="nav-heading">Resources</div>
          <.nav_link
            :for={r <- Catalog.resources()}
            path={"/r/#{r.slug}"}
            current={@current_path}
            prefix
          >
            <span class="dot" style={"background: #{r.color}"}></span>
            {r.plural}
            <span class="count">{Map.get(@counts, r.label, 0)}</span>
          </.nav_link>
        </nav>

        <div class="sidebar-foot">
          Every record is a node in one glider file. Every connection is a real edge.
        </div>
      </aside>

      <main class="main">
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :current, :string, required: true
  attr :icon, :string, default: nil
  attr :prefix, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    active =
      if assigns.prefix,
        do: String.starts_with?(assigns.current || "", assigns.path),
        else: assigns.current == assigns.path

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link navigate={@path} class={["nav-link", @active && "active"]}>
      <span :if={@icon} class="nav-icon">{@icon}</span>
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
