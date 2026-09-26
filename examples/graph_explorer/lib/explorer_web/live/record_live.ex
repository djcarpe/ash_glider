defmodule ExplorerWeb.RecordLive do
  @moduledoc """
  One record: its attributes (Ash), its edges (glider), its neighbourhood on a
  canvas, and the graph-native questions you can ask from it — traversal to
  any depth and shortest paths to any other record.
  """
  use ExplorerWeb, :live_view

  require Ash.Query

  @impl true
  def mount(%{"resource" => slug}, _session, socket) do
    case Catalog.by_slug(slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "No such resource") |> push_navigate(to: "/")}

      meta ->
        {:ok,
         assign(socket,
           meta: meta,
           resource: meta.resource,
           record: nil,
           depth: 1,
           editing_edge: nil,
           traverse_result: nil,
           path_result: nil
         )}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    same? = match?(%{id: ^id}, socket.assigns.record)

    case same? || Ash.get(socket.assigns.resource, id) do
      true ->
        {:noreply, apply_action(socket, socket.assigns.live_action)}

      {:ok, record} ->
        {:noreply,
         socket
         |> assign(
           record: record,
           page_title: record.name,
           traverse_result: nil,
           path_result: nil
         )
         |> init_forms()
         |> load_graph()
         |> apply_action(socket.assigns.live_action)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "That #{socket.assigns.meta.label} no longer exists")
         |> push_navigate(to: "/r/#{socket.assigns.meta.slug}")}
    end
  end

  defp apply_action(socket, :edit) do
    form =
      socket.assigns.record
      |> AshPhoenix.Form.for_update(:update, as: "record")
      |> to_form()

    assign(socket, :form, form)
  end

  defp apply_action(socket, :show), do: assign(socket, :form, nil)

  defp load_graph(socket) do
    %{record: record, depth: depth} = socket.assigns

    assign(socket,
      edges: GraphOps.edges_of(record),
      graph: GraphOps.neighborhood(record, depth)
    )
  end

  # --------------------------------------------------------------- side forms

  defp init_forms(socket) do
    choices = edge_choices(socket.assigns.resource)
    first = choices |> List.first() |> elem(1)

    socket
    |> assign(:edge_choices, choices)
    |> assign_edge_params(%{"choice" => first})
    |> assign(:traverse_params, %{
      "type" => first |> String.split(":") |> List.last(),
      "direction" => "out",
      "min" => "1",
      "max" => "2"
    })
    |> assign_path_params(%{"resource" => socket.assigns.meta.slug})
  end

  # "out:KNOWS" means this record is the edge's source; "in:KNOWS" the target.
  defp edge_choices(resource) do
    for spec <- Catalog.edge_types_for(resource),
        {dir, other} <- [{"out", spec.to}, {"in", spec.from}],
        (dir == "out" and spec.from == resource) or (dir == "in" and spec.to == resource) do
      other_label = Catalog.by_resource(other).label

      text =
        if dir == "out",
          do: "this → :#{spec.type} → #{other_label}",
          else: "#{other_label} → :#{spec.type} → this"

      {text, "#{dir}:#{spec.type}"}
    end
  end

  defp parse_choice(choice) do
    [dir, type] = String.split(choice, ":", parts: 2)
    spec = Catalog.edge_type(type)
    other = if dir == "out", do: spec.to, else: spec.from
    {dir, spec, other}
  end

  defp assign_edge_params(socket, params) do
    {dir, spec, other} = parse_choice(params["choice"])
    targets = options_for(other)

    target =
      if Enum.any?(targets, fn {_, id} -> id == params["target"] end),
        do: params["target"],
        else: targets |> List.first({nil, nil}) |> elem(1)

    assign(socket,
      edge_params: Map.put(params, "target", target),
      edge_spec: spec,
      edge_dir: dir,
      edge_targets: targets
    )
  end

  defp assign_path_params(socket, params) do
    meta = Catalog.by_slug(params["resource"]) || socket.assigns.meta

    targets =
      meta.resource
      |> options_for()
      |> Enum.reject(fn {_, id} -> id == socket.assigns.record.id end)

    target =
      if Enum.any?(targets, fn {_, id} -> id == params["target"] end),
        do: params["target"],
        else: targets |> List.first({nil, nil}) |> elem(1)

    assign(socket,
      path_params: %{"resource" => meta.slug, "target" => target},
      path_targets: targets
    )
  end

  defp options_for(resource) do
    resource
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!()
    |> Enum.map(&{&1.name, &1.id})
  end

  # ------------------------------------------------------------------ events

  @impl true
  def handle_event("depth", %{"depth" => depth}, socket) do
    {:noreply, socket |> assign(:depth, String.to_integer(depth)) |> load_graph()}
  end

  # -- record

  def handle_event("validate", %{"record" => params}, socket) do
    params = normalize_params(socket.assigns.resource, params)
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"record" => params}, socket) do
    params = normalize_params(socket.assigns.resource, params)

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, record} ->
        {:noreply,
         socket
         |> assign(:record, record)
         |> load_graph()
         |> put_flash(:info, "Saved #{record.name}")
         |> push_patch(to: Catalog.path(record))}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("delete_record", _params, socket) do
    %{record: record, meta: meta} = socket.assigns
    Ash.destroy!(record)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{record.name} and every edge touching it")
     |> push_navigate(to: "/r/#{meta.slug}")}
  end

  # -- edges

  def handle_event("edge_change", %{"edge" => params}, socket) do
    {:noreply, assign_edge_params(socket, params)}
  end

  def handle_event("edge_create", %{"edge" => params}, socket) do
    socket = assign_edge_params(socket, params)
    %{record: record, edge_spec: spec, edge_dir: dir, edge_params: p} = socket.assigns
    {_, _, other} = parse_choice(p["choice"])

    with id when is_binary(id) <- p["target"] || {:error, "pick a target"},
         {:ok, target} <- Ash.get(other, id),
         {from, to} = if(dir == "out", do: {record, target}, else: {target, record}),
         :ok <- GraphOps.create_edge(from, spec.type, to, Map.get(p, "props", %{})) do
      {:noreply,
       socket
       |> load_graph()
       |> put_flash(:info, "#{from.name} -[:#{spec.type}]-> #{to.name}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create edge: #{error_text(reason)}")}
    end
  end

  def handle_event("edge_delete", %{"id" => id}, socket) do
    :ok = GraphOps.delete_edge(to_int(id))
    {:noreply, socket |> load_graph() |> put_flash(:info, "Edge removed")}
  end

  def handle_event("edge_edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing_edge, to_int(id))}
  end

  def handle_event("edge_cancel", _params, socket) do
    {:noreply, assign(socket, :editing_edge, nil)}
  end

  def handle_event("edge_update", %{"edge_id" => id} = params, socket) do
    case GraphOps.update_edge(to_int(id), Map.get(params, "props", %{})) do
      :ok ->
        {:noreply,
         socket |> assign(:editing_edge, nil) |> load_graph() |> put_flash(:info, "Edge updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not update edge: #{error_text(reason)}")}
    end
  end

  # -- traversal and paths

  def handle_event("traverse", %{"traverse" => p}, socket) do
    min = p["min"] |> to_int() |> max(1)
    max = p["max"] |> to_int() |> max(min) |> min(6)
    dir = String.to_existing_atom(p["direction"])
    p = %{p | "min" => to_string(min), "max" => to_string(max)}

    {micros, result} =
      :timer.tc(fn -> GraphOps.traverse(socket.assigns.record, p["type"], dir, min, max) end)

    {:noreply, assign(socket, traverse_params: p, traverse_result: {result, micros})}
  end

  def handle_event("path_change", %{"path" => p}, socket) do
    {:noreply, assign_path_params(socket, p)}
  end

  def handle_event("path_find", %{"path" => p}, socket) do
    socket = assign_path_params(socket, p)
    %{path_params: pp} = socket.assigns
    meta = Catalog.by_slug(pp["resource"])

    result =
      with id when is_binary(id) <- pp["target"] || {:error, "pick a target"},
           {:ok, target} <- Ash.get(meta.resource, id) do
        GraphOps.path(socket.assigns.record, target)
      end

    {:noreply, assign(socket, :path_result, result)}
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v),
    do:
      v
      |> to_string()
      |> Integer.parse()
      |> then(fn
        {n, _} -> n
        :error -> 1
      end)

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(%{__exception__: true} = e), do: Exception.message(e)
  defp error_text(reason), do: inspect(reason)

  defp traverse_types(resource) do
    resource |> Catalog.edge_types_for() |> Enum.map(& &1.type) |> Enum.uniq()
  end

  defp shown_props(props), do: props |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Enum.sort()

  # ------------------------------------------------------------------ render

  @impl true
  def render(%{record: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} counts={@counts} current_path={@current_path}>
      <p class="muted">Loading…</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} counts={@counts} current_path={@current_path}>
      <header class="page-head">
        <div>
          <p class="crumbs">
            <.link navigate={"/r/#{@meta.slug}"}>{@meta.plural}</.link> /
          </p>
          <h1><.label_chip label={@meta.label} /> {@record.name}</h1>
        </div>
        <div class="actions">
          <.link patch={"#{Catalog.path(@record)}/edit"} class="btn">Edit</.link>
          <.confirm_button
            id="delete-record"
            event="delete_record"
            confirm="Delete this and its edges?"
          >
            Delete
          </.confirm_button>
        </div>
      </header>

      <div class="grid-1-2">
        <section class="card">
          <h2>Attributes</h2>
          <dl class="attrs">
            <div :for={attr <- Catalog.display_attributes(@resource)}>
              <dt>{humanize(attr.name)}</dt>
              <dd class={attr.primary_key? && "mono"}>
                <.value value={Map.get(@record, attr.name)} />
              </dd>
            </div>
          </dl>
        </section>

        <section class="card">
          <div class="card-head">
            <h2>Neighbourhood</h2>
            <form id="depth" phx-change="depth" class="seg">
              <label :for={d <- [1, 2]} class={["seg-btn", @depth == d && "active"]}>
                <input type="radio" name="depth" value={d} checked={@depth == d} />
                {d} {if d == 1, do: "hop", else: "hops"}
              </label>
            </form>
          </div>
          <.graph_canvas id="neighbourhood" graph={@graph} height={400} />
        </section>
      </div>

      <section class="card">
        <div class="card-head">
          <h2>Edges <span class="muted">{length(@edges)}</span></h2>
        </div>

        <table class="table">
          <thead>
            <tr>
              <th>Direction</th><th>Type</th><th>Other end</th><th>Properties</th><th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @edges} id={"edge-#{e.id}"}>
              <td class="nowrap muted">
                {if e.direction == :out, do: "outgoing →", else: "← incoming"}
              </td>
              <td><code class="rel">:{e.type}</code></td>
              <td><.node_ref name={e.other.name} label={e.other.label} path={e.other.path} /></td>
              <td>
                <%= if @editing_edge == e.id do %>
                  <form phx-submit="edge_update" class="inline-form" id={"edge-form-#{e.id}"}>
                    <input type="hidden" name="edge_id" value={e.id} />
                    <label :for={{key, type} <- Catalog.edge_type(e.type).props}>
                      {key}
                      <input
                        type={if type == :integer, do: "number", else: "text"}
                        name={"props[#{key}]"}
                        value={e.props[to_string(key)]}
                      />
                    </label>
                    <button class="btn small">Save</button>
                    <button type="button" class="btn ghost small" phx-click="edge_cancel">Cancel</button>
                  </form>
                <% else %>
                  <span :for={{k, v} <- shown_props(e.props)} class="prop">
                    {k}: <strong>{v}</strong>
                  </span>
                  <span :if={shown_props(e.props) == []} class="muted">—</span>
                <% end %>
              </td>
              <td class="right nowrap">
                <button
                  :if={
                    @editing_edge != e.id and (Catalog.edge_type(e.type) || %{props: []}).props != []
                  }
                  class="btn ghost small"
                  phx-click="edge_edit"
                  phx-value-id={e.id}
                >
                  Edit
                </button>
                <.confirm_button
                  id={"del-edge-#{e.id}"}
                  event="edge_delete"
                  value={%{id: e.id}}
                  class="btn danger small"
                  confirm="Remove?"
                >
                  Remove
                </.confirm_button>
              </td>
            </tr>
            <tr :if={@edges == []}>
              <td colspan="5" class="empty">No edges yet. Add one below.</td>
            </tr>
          </tbody>
        </table>

        <.form
          for={%{}}
          as={:edge}
          id="new-edge"
          class="edge-form"
          phx-change="edge_change"
          phx-submit="edge_create"
        >
          <h3>Add an edge</h3>
          <div class="row">
            <label>
              Kind
              <select name="edge[choice]">
                <option
                  :for={{text, value} <- @edge_choices}
                  value={value}
                  selected={value == @edge_params["choice"]}
                >
                  {text}
                </option>
              </select>
            </label>
            <label>
              {if @edge_dir == "out", do: "Target", else: "Source"}
              <select name="edge[target]">
                <option
                  :for={{name, id} <- @edge_targets}
                  value={id}
                  selected={id == @edge_params["target"]}
                >
                  {name}
                </option>
              </select>
            </label>
            <label :for={{key, type} <- @edge_spec.props}>
              {key}
              <input
                type={if type == :integer, do: "number", else: "text"}
                name={"edge[props][#{key}]"}
                value={get_in(@edge_params, ["props", to_string(key)])}
              />
            </label>
            <button type="submit" class="btn">Connect</button>
          </div>
          <p class="hint">
            Calls <code>AshGlider.Edge.relate(from, :{@edge_spec.type}, to, props)</code>, which is {@edge_spec.describe}.
          </p>
        </.form>
      </section>

      <div class="grid-2">
        <section class="card">
          <h2>Traverse</h2>
          <p class="sub">Follow one edge type for several hops without a join per hop.</p>
          <.form for={%{}} as={:traverse} id="traverse" phx-submit="traverse" class="row">
            <label>
              Edge
              <select name="traverse[type]">
                <option
                  :for={t <- traverse_types(@resource)}
                  value={t}
                  selected={t == @traverse_params["type"]}
                >
                  :{t}
                </option>
              </select>
            </label>
            <label>
              Direction
              <select name="traverse[direction]">
                <option
                  :for={d <- ~w(out in both)}
                  value={d}
                  selected={d == @traverse_params["direction"]}
                >
                  {d}
                </option>
              </select>
            </label>
            <label class="narrow">
              From
              <input
                type="number"
                name="traverse[min]"
                min="1"
                max="6"
                value={@traverse_params["min"]}
              />
            </label>
            <label class="narrow">
              To
              <input
                type="number"
                name="traverse[max]"
                min="1"
                max="6"
                value={@traverse_params["max"]}
              />
            </label>
            <button class="btn">Go</button>
          </.form>
          <pre class="code">AshGlider.Edge.related(record, :{@traverse_params["type"]},
      depth: {@traverse_params["min"]}..{@traverse_params["max"]}, direction: :{@traverse_params["direction"]})</pre>

          <%= case @traverse_result do %>
            <% nil -> %>
            <% {{:ok, records}, us} -> %>
              <p class="muted">{length(records)} reached in {fmt_micros(us)}</p>
              <ul class="results">
                <li :for={r <- records}>
                  <.node_ref
                    name={r.name}
                    label={Catalog.by_resource(r.__struct__).label}
                    path={Catalog.path(r)}
                  />
                </li>
              </ul>
            <% {{:error, reason}, _} -> %>
              <p class="error">{error_text(reason)}</p>
          <% end %>
        </section>

        <section class="card">
          <h2>Shortest path</h2>
          <p class="sub">Any edge type, either direction, across resources.</p>
          <.form
            for={%{}}
            as={:path}
            id="path"
            phx-change="path_change"
            phx-submit="path_find"
            class="row"
          >
            <label>
              To a
              <select name="path[resource]">
                <option
                  :for={r <- Catalog.resources()}
                  value={r.slug}
                  selected={r.slug == @path_params["resource"]}
                >
                  {r.label}
                </option>
              </select>
            </label>
            <label>
              Named
              <select name="path[target]">
                <option
                  :for={{name, id} <- @path_targets}
                  value={id}
                  selected={id == @path_params["target"]}
                >
                  {name}
                </option>
              </select>
            </label>
            <button class="btn">Find</button>
          </.form>

          <%= case @path_result do %>
            <% nil -> %>
            <% {:ok, []} -> %>
              <p class="muted">No path. These two are in different components.</p>
            <% {:ok, steps} -> %>
              <p class="muted">{length(steps) - 1} hops</p>
              <ol class="path">
                <li :for={s <- steps}>
                  <.node_ref name={s.name} label={s.label} path={s.path} />
                </li>
              </ol>
            <% {:error, reason} -> %>
              <p class="error">{error_text(reason)}</p>
          <% end %>
        </section>
      </div>

      <.modal
        :if={@live_action == :edit}
        id="edit-record"
        title={"Edit #{@record.name}"}
        on_cancel={JS.patch(Catalog.path(@record))}
      >
        <.form for={@form} id="record-form" phx-change="validate" phx-submit="save">
          <.attr_input
            :for={attr <- Catalog.editable_attributes(@resource)}
            field={@form[attr.name]}
            attribute={attr}
          />
          <footer class="modal-foot">
            <.link patch={Catalog.path(@record)} class="btn ghost">Cancel</.link>
            <button type="submit" class="btn">Save</button>
          </footer>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
