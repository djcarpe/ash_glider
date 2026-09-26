defmodule ExplorerWeb.QueryLive do
  @moduledoc """
  Three ways to ask the graph a question:

    * **Ash query** — a filter builder over any resource, showing the Elixir it
      corresponds to and how the data layer splits the work with glider.
    * **Cypher** — glider's own query language, rendered as a table and a graph.
    * **Algorithms** — PageRank, centrality, communities and friends.
  """
  use ExplorerWeb, :live_view

  alias Explorer.QueryBuilder

  @examples [
    {"Who works where", ~S|MATCH (p:Person)-[r:WORKS_AT]->(c:Company) RETURN p, r, c|},
    {"Friends of friends of José",
     ~S|MATCH (a:Person {name: "José Valim"})-[:KNOWS*1..2]-(b:Person) RETURN DISTINCT b|},
    {"Elixir ecosystem",
     ~S|MATCH (p:Project)-[r:DEPENDS_ON*1..3]->(e:Project {name: "Erlang/OTP"}) RETURN DISTINCT p, e|},
    {"Most connected",
     ~S|MATCH (n) RETURN n.name, labels(n), degree(n) AS degree ORDER BY degree DESC LIMIT 10|},
    {"Commits per project",
     ~S|MATCH (p:Person)-[c:CONTRIBUTES_TO]->(pr:Project) RETURN pr.name, sum(c.commits) AS commits ORDER BY commits DESC|},
    {"Funding", ~S|MATCH (c:Company)-[s:SPONSORS]->(p:Project) RETURN c, s, p|},
    {"Schema", "SCHEMA"}
  ]

  @presets [
    {"Engineers in Seattle", "people",
     [
       %{"field" => "role", "op" => "eq", "value" => "engineer"},
       %{"field" => "city", "op" => "eq", "value" => "Seattle"}
     ], "name", "asc"},
    {"Elixir projects by stars", "projects",
     [%{"field" => "language", "op" => "eq", "value" => "Elixir"}], "stars", "desc"},
    {"60+ and knows compilers", "people",
     [
       %{"field" => "age", "op" => "gte", "value" => "60"},
       %{"field" => "skills", "op" => "has", "value" => "compilers"}
     ], "age", "desc"},
    {"Most central people", "people", [%{"field" => "rank", "op" => "present", "value" => ""}],
     "rank", "desc"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Query", examples: @examples, presets: @presets)
     |> assign(cypher: elem(hd(@examples), 1), cypher_result: nil)
     |> assign(
       algo: %{"name" => "pagerank", "top" => "15", "type" => "", "dir" => "", "write" => "false"}
     )
     |> assign(algo_result: nil, edge_types: Enum.map(Catalog.edge_types(), & &1.type))
     |> set_builder(
       "people",
       [%{"field" => "city", "op" => "eq", "value" => "Seattle"}],
       "name",
       "asc",
       "25"
     )
     |> run_builder()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in ~w(ash cypher algorithms), do: params["tab"], else: "ash"
    {:noreply, assign(socket, :tab, tab)}
  end

  # ------------------------------------------------------------- ash builder

  defp set_builder(socket, slug, conditions, sort, dir, limit) do
    meta = Catalog.by_slug(slug) || hd(Catalog.resources())
    attrs = Catalog.display_attributes(meta.resource)
    names = Enum.map(attrs, &to_string(&1.name))

    conditions =
      conditions
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        field = if c["field"] in names, do: c["field"], else: hd(names -- ["id"])
        attr = Enum.find(attrs, &(to_string(&1.name) == field))
        ops = QueryBuilder.ops_for(attr)
        op = if c["op"] in ops, do: c["op"], else: hd(ops)
        %{"i" => i, "field" => field, "op" => op, "value" => c["value"] || "", "ops" => ops}
      end)

    assign(socket,
      b_meta: meta,
      b_attrs: attrs,
      b_conditions: conditions,
      b_sort: if(sort in names, do: sort, else: "name"),
      b_dir: if(dir == "desc", do: "desc", else: "asc"),
      b_limit: limit
    )
  end

  defp run_builder(socket) do
    a = socket.assigns

    limit =
      case Integer.parse(to_string(a.b_limit)) do
        {n, _} when n > 0 -> n
        _ -> nil
      end

    sort = a.b_sort |> String.to_existing_atom()
    result = QueryBuilder.run(a.b_meta.resource, a.b_conditions, sort, a.b_dir, limit)
    assign(socket, :b_result, result)
  end

  @impl true
  def handle_event("builder", %{"b" => b}, socket) do
    conditions =
      b
      |> Map.get("c", %{})
      |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
      |> Enum.map(&elem(&1, 1))

    # Switching resource invalidates the conditions' fields.
    conditions = if b["resource"] != socket.assigns.b_meta.slug, do: [], else: conditions

    {:noreply,
     socket
     |> set_builder(b["resource"], conditions, b["sort"], b["dir"], b["limit"])
     |> run_builder()}
  end

  def handle_event("add_condition", _params, socket) do
    a = socket.assigns
    conditions = a.b_conditions ++ [%{"field" => "name", "op" => "contains", "value" => ""}]
    {:noreply, set_builder(socket, a.b_meta.slug, conditions, a.b_sort, a.b_dir, a.b_limit)}
  end

  def handle_event("remove_condition", %{"i" => i}, socket) do
    a = socket.assigns
    conditions = Enum.reject(a.b_conditions, &(to_string(&1["i"]) == i))

    {:noreply,
     socket
     |> set_builder(a.b_meta.slug, conditions, a.b_sort, a.b_dir, a.b_limit)
     |> run_builder()}
  end

  def handle_event("preset", %{"i" => i}, socket) do
    {_name, slug, conditions, sort, dir} = Enum.at(@presets, String.to_integer(i))
    {:noreply, socket |> set_builder(slug, conditions, sort, dir, "25") |> run_builder()}
  end

  # ------------------------------------------------------------------ cypher

  def handle_event("cypher_run", %{"cypher" => text}, socket) do
    result =
      case GraphOps.cypher(text) do
        {:ok, r, us} ->
          viz = if r.graph.nodes == [], do: nil, else: GraphOps.viz(r.graph)
          {:ok, r, us, viz}

        {:error, reason} ->
          {:error, reason}
      end

    {:noreply,
     socket
     |> assign(cypher: text, cypher_result: result)
     |> ExplorerWeb.Nav.refresh_counts()}
  end

  def handle_event("cypher_example", %{"i" => i}, socket) do
    {_, text} = Enum.at(@examples, String.to_integer(i))
    handle_event("cypher_run", %{"cypher" => text}, socket)
  end

  # -------------------------------------------------------------- algorithms

  def handle_event("algo_run", %{"algo" => p}, socket) do
    top =
      case Integer.parse(p["top"] || "") do
        {n, _} when n > 0 -> n
        _ -> nil
      end

    type = if p["type"] in socket.assigns.edge_types, do: p["type"]
    dir = if p["dir"] in ~w(out in both), do: p["dir"]
    write = p["write"] == "true"

    result = GraphOps.algorithm(p["name"], top: top, type: type, dir: dir, write: write)
    {:noreply, assign(socket, algo: p, algo_result: result)}
  end

  # ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} counts={@counts} current_path={@current_path}>
      <header class="page-head">
        <div>
          <h1>Query</h1>
          <p class="sub">Ask through Ash, through Cypher, or through the graph algorithms.</p>
        </div>
      </header>

      <nav class="tabs">
        <.link patch="/query?tab=ash" class={["tab", @tab == "ash" && "active"]}>Ash query</.link>
        <.link patch="/query?tab=cypher" class={["tab", @tab == "cypher" && "active"]}>Cypher</.link>
        <.link patch="/query?tab=algorithms" class={["tab", @tab == "algorithms" && "active"]}>
          Algorithms
        </.link>
      </nav>

      <.ash_tab :if={@tab == "ash"} {assigns} />
      <.cypher_tab :if={@tab == "cypher"} {assigns} />
      <.algo_tab :if={@tab == "algorithms"} {assigns} />
    </Layouts.app>
    """
  end

  defp ash_tab(assigns) do
    ~H"""
    <div class="presets">
      <span class="muted">Try:</span>
      <button
        :for={{{name, _, _, _, _}, i} <- Enum.with_index(@presets)}
        class="btn ghost small"
        phx-click="preset"
        phx-value-i={i}
      >
        {name}
      </button>
    </div>

    <section class="card">
      <.form for={%{}} as={:b} id="builder" phx-change="builder" phx-submit="builder" class="builder">
        <div class="row">
          <label>
            Resource
            <select name="b[resource]">
              <option :for={r <- Catalog.resources()} value={r.slug} selected={r.slug == @b_meta.slug}>
                {r.label}
              </option>
            </select>
          </label>
          <label>
            Sort by
            <select name="b[sort]">
              <option :for={a <- @b_attrs} value={a.name} selected={to_string(a.name) == @b_sort}>
                {a.name}
              </option>
            </select>
          </label>
          <label>
            Order
            <select name="b[dir]">
              <option value="asc" selected={@b_dir == "asc"}>ascending</option>
              <option value="desc" selected={@b_dir == "desc"}>descending</option>
            </select>
          </label>
          <label class="narrow">
            Limit <input type="number" name="b[limit]" value={@b_limit} min="1" phx-debounce="300" />
          </label>
        </div>

        <h3>Where</h3>
        <div :for={c <- @b_conditions} class="row condition" id={"cond-#{c["i"]}"}>
          <select name={"b[c][#{c["i"]}][field]"}>
            <option :for={a <- @b_attrs} value={a.name} selected={to_string(a.name) == c["field"]}>
              {a.name}
            </option>
          </select>
          <select name={"b[c][#{c["i"]}][op]"}>
            <option :for={op <- c["ops"]} value={op} selected={op == c["op"]}>
              {QueryBuilder.op_label(op)}
            </option>
          </select>
          <input
            :if={c["op"] not in ["is_nil", "present"]}
            type="text"
            name={"b[c][#{c["i"]}][value]"}
            value={c["value"]}
            placeholder={if c["op"] == "in", do: "a, b, c", else: "value"}
            phx-debounce="300"
          />
          <button
            type="button"
            class="icon-btn"
            phx-click="remove_condition"
            phx-value-i={c["i"]}
            aria-label="remove condition"
          >
            ×
          </button>
        </div>
        <p :if={@b_conditions == []} class="muted">No conditions: every {@b_meta.label}.</p>
        <button type="button" class="btn ghost small" phx-click="add_condition">+ condition</button>
      </.form>
    </section>

    <%= case @b_result do %>
      <% {:error, msg} -> %>
        <section class="card">
          <p class="error">{msg}</p>
        </section>
      <% {:ok, r} -> %>
        <div class="grid-2">
          <section class="card">
            <h2>Elixir</h2>
            <pre class="code">{r.code}</pre>
          </section>
          <section class="card">
            <h2>What glider sees</h2>
            <pre class="code">{r.plan.cypher}</pre>
            <ul class="plan">
              <li :for={c <- r.plan.pushed}>
                <span class="pill ok">pushed down</span>
                <code>{QueryBuilder.describe(c)}</code>
                <span :if={c.attr.name in r.plan.indexed} class="muted">index seek</span>
              </li>
              <li :for={c <- r.plan.runtime}>
                <span class="pill warn">in Elixir</span>
                <code>{QueryBuilder.describe(c)}</code>
                <span class="muted">Ash.Filter.Runtime</span>
              </li>
              <li :if={r.plan.pushed == [] and r.plan.runtime == []} class="muted">
                label scan, no filter
              </li>
            </ul>
            <p class="hint">
              Only <code>attribute == literal</code>
              becomes part of the <code>MATCH</code>.
              Everything else is filtered after a scan of
              <code>:{AshGlider.Info.label(@b_meta.resource)}</code>
              nodes, so cost tracks the label's size.
            </p>
          </section>
        </div>

        <section class="card">
          <div class="card-head">
            <h2>{length(r.records)} {if length(r.records) == 1, do: "result", else: "results"}</h2>
            <span class="muted">{fmt_micros(r.micros)}</span>
          </div>
          <table class="table">
            <thead>
              <tr>
                <th :for={a <- @b_attrs} :if={a.name != :id}>{a.name}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={rec <- r.records}>
                <td :for={a <- @b_attrs} :if={a.name != :id}>
                  <.link :if={a.name == :name} navigate={Catalog.path(rec)} class="strong">
                    {rec.name}
                  </.link>
                  <.value :if={a.name != :name} value={Map.get(rec, a.name)} />
                </td>
              </tr>
              <tr :if={r.records == []}>
                <td colspan={length(@b_attrs)} class="empty">No matches.</td>
              </tr>
            </tbody>
          </table>
        </section>
    <% end %>
    """
  end

  defp cypher_tab(assigns) do
    ~H"""
    <div class="presets">
      <span class="muted">Examples:</span>
      <button
        :for={{{name, _}, i} <- Enum.with_index(@examples)}
        class="btn ghost small"
        phx-click="cypher_example"
        phx-value-i={i}
      >
        {name}
      </button>
    </div>

    <section class="card">
      <form id="cypher-form" phx-submit="cypher_run">
        <textarea
          id="cypher-input"
          name="cypher"
          class="cypher"
          rows="4"
          spellcheck="false"
          phx-hook="SubmitOnCtrlEnter"
        >{@cypher}</textarea>
        <div class="row between">
          <p class="hint">
            Runs directly on the graph. Writes here skip Ash validations, so prefer the resource pages for data changes.
            Ctrl+Enter to run.
          </p>
          <button class="btn">Run</button>
        </div>
      </form>
    </section>

    <%= case @cypher_result do %>
      <% nil -> %>
      <% {:error, reason} -> %>
        <section class="card">
          <p class="error">glider: {reason}</p>
        </section>
      <% {:ok, r, us, viz} -> %>
        <section class="card">
          <div class="card-head">
            <h2>
              {length(r.rows)} {if length(r.rows) == 1, do: "row", else: "rows"}
              <span :if={r.message} class="muted">· {r.message}</span>
            </h2>
            <span class="muted">{fmt_micros(us)}</span>
          </div>
          <.graph_canvas :if={viz} id="cypher-graph" graph={viz} height={380} />
          <table :if={r.columns != []} class="table">
            <thead>
              <tr>
                <th :for={c <- r.columns}>{c}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- Enum.take(r.rows, 500)}>
                <td :for={cell <- row}><.cell value={cell} /></td>
              </tr>
            </tbody>
          </table>
        </section>
    <% end %>
    """
  end

  attr :value, :any, required: true

  defp cell(%{value: %Glider.Node{} = n} = assigns) do
    assigns =
      assign(assigns, n: n, label: List.first(n.labels) || "?", path: Catalog.node_path(n))

    ~H"""
    <.node_ref name={@n.props["name"] || "##{@n.id}"} label={@label} path={@path} />
    """
  end

  defp cell(%{value: %Glider.Rel{} = r} = assigns) do
    assigns = assign(assigns, :r, r)

    ~H"""
    <code class="rel">:{@r.type}</code>
    <span :for={{k, v} <- Enum.sort(@r.props)} :if={not is_nil(v)} class="prop">
      {k}: <strong>{v}</strong>
    </span>
    """
  end

  defp cell(assigns), do: ~H"<.value value={@value} />"

  defp algo_tab(assigns) do
    ~H"""
    <section class="card">
      <.form for={%{}} as={:algo} id="algo-form" phx-submit="algo_run" class="row">
        <label>
          Algorithm
          <select name="algo[name]">
            <option :for={a <- GraphOps.algorithms()} value={a} selected={a == @algo["name"]}>
              {a}
            </option>
          </select>
        </label>
        <label>
          Edge type
          <select name="algo[type]">
            <option value="">any</option>
            <option :for={t <- @edge_types} value={t} selected={t == @algo["type"]}>:{t}</option>
          </select>
        </label>
        <label>
          Direction
          <select name="algo[dir]">
            <option value="">default</option>
            <option :for={d <- ~w(out in both)} value={d} selected={d == @algo["dir"]}>{d}</option>
          </select>
        </label>
        <label class="narrow">Top
        <input type="number" name="algo[top]" value={@algo["top"]} min="1" /></label>
        <label class="check">
          <input type="hidden" name="algo[write]" value="false" />
          <input type="checkbox" name="algo[write]" value="true" checked={@algo["write"] == "true"} />
          write to <code>rank</code>
        </label>
        <button class="btn">Run</button>
      </.form>
      <p class="hint">
        Calls <code>AshGlider.Edge.algorithm/3</code>. With "write to rank", every node's score is stored in its
        <code>rank</code>
        attribute, which is then sortable from the Ash query tab and the resource pages.
      </p>
    </section>

    <%= case @algo_result do %>
      <% nil -> %>
      <% {:error, reason} -> %>
        <section class="card">
          <p class="error">glider: {reason}</p>
        </section>
      <% {:ok, r} -> %>
        <section class="card">
          <div class="card-head">
            <h2>{@algo["name"]}</h2>
            <span class="muted">{fmt_micros(r.micros)}</span>
          </div>
          <table class="table">
            <thead>
              <tr>
                <th>#</th><th>Node</th><th class="right">Value</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{row, i} <- Enum.with_index(r.rows, 1)}>
                <td class="muted">{i}</td>
                <td>
                  <.node_ref name={row.name || "##{row.id}"} label={row.label} path={row.path} />
                </td>
                <td class="right"><.value value={row.value} /></td>
              </tr>
            </tbody>
          </table>
        </section>
    <% end %>
    """
  end
end
