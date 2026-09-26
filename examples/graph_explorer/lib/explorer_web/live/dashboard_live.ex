defmodule ExplorerWeb.DashboardLive do
  use ExplorerWeb, :live_view

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Overview") |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:overview, GraphOps.overview())
    |> assign(:graph, GraphOps.whole_graph())
    |> assign(:central, central())
    |> ExplorerWeb.Nav.refresh_counts()
  end

  # The `rank` attribute is written straight into the graph by PageRank, then
  # read back here with an ordinary Ash sort — the round trip this app is for.
  defp central do
    for r <- Catalog.resources() do
      top =
        r.resource
        |> Ash.Query.filter(not is_nil(rank))
        |> Ash.Query.sort(rank: :desc)
        |> Ash.Query.limit(5)
        |> Ash.read!()

      {r, top}
    end
  end

  @impl true
  def handle_event("pagerank", _params, socket) do
    {:ok, %{micros: us}} = GraphOps.algorithm("pagerank", write: true)

    {:noreply,
     socket
     |> load()
     |> put_flash(:info, "PageRank written to every node's rank in #{fmt_micros(us)}")}
  end

  def handle_event("reset", _params, socket) do
    Explorer.Seeds.reset!()
    {:noreply, socket |> load() |> put_flash(:info, "Demo data restored")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} counts={@counts} current_path={@current_path}>
      <header class="page-head">
        <div>
          <h1>Overview</h1>
          <p class="sub">
            The whole graph at a glance. Records are Ash resources stored as glider nodes.
          </p>
        </div>
        <div class="actions">
          <button class="btn" phx-click="pagerank">Recompute PageRank</button>
          <.confirm_button
            id="reset"
            event="reset"
            class="btn ghost"
            confirm="Wipe the graph and reseed?"
          >
            Reset demo data
          </.confirm_button>
        </div>
      </header>

      <section class="stats">
        <div class="stat"><strong>{@overview.nodes}</strong><span>nodes</span></div>
        <div class="stat"><strong>{@overview.edges}</strong><span>edges</span></div>
        <div class="stat"><strong>{length(@overview.labels)}</strong><span>labels</span></div>
        <div class="stat"><strong>{length(@overview.edge_types)}</strong><span>edge types</span></div>
        <div class="stat"><strong>{length(@overview.indexes)}</strong><span>indexes</span></div>
      </section>

      <div class="grid-2-1">
        <section class="card">
          <h2>The graph</h2>
          <.graph_canvas id="overview-graph" graph={@graph} height={560} />
        </section>

        <div class="stack">
          <section class="card">
            <h2>Labels</h2>
            <table class="table compact">
              <tr :for={l <- @overview.labels}>
                <td><.label_chip label={l.name} /></td>
                <td class="num">{l.count}</td>
                <td class="right">
                  <.link :if={r = Catalog.by_label(l.name)} navigate={"/r/#{r.slug}"}>browse</.link>
                </td>
              </tr>
            </table>
          </section>

          <section class="card">
            <h2>Edge types</h2>
            <table class="table compact">
              <tr :for={e <- @overview.edge_types}>
                <td><code class="rel">:{e.name}</code></td>
                <td class="num">{e.count}</td>
              </tr>
            </table>
          </section>

          <section class="card">
            <h2>Most central <small>by PageRank</small></h2>
            <div :for={{r, top} <- @central} class="central">
              <h3><span class="dot" style={"background: #{r.color}"}></span>{r.plural}</h3>
              <ol>
                <li :for={rec <- top}>
                  <.link navigate={Catalog.path(rec)}>{rec.name}</.link>
                  <span class="num muted">{Float.round(rec.rank, 4)}</span>
                </li>
                <li :if={top == []} class="muted">no ranks yet</li>
              </ol>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
