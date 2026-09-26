defmodule ExplorerWeb.ResourceLive do
  @moduledoc """
  Browse one resource: free-text search, sortable columns, pagination, and a
  create form. Everything here is a plain Ash query over the glider data layer.
  """
  use ExplorerWeb, :live_view

  require Ash.Query
  import Ash.Expr

  @per_page 15

  @impl true
  def mount(%{"resource" => slug}, _session, socket) do
    case Catalog.by_slug(slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "No such resource") |> push_navigate(to: "/")}

      meta ->
        {:ok, assign(socket, meta: meta, resource: meta.resource, page_title: meta.plural)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(
        q: params["q"] || "",
        sort: params["sort"] || "name",
        dir: if(params["dir"] == "desc", do: "desc", else: "asc"),
        page: max(String.to_integer(params["page"] || "1"), 1)
      )
      |> load()
      |> apply_action(socket.assigns.live_action)

    {:noreply, socket}
  end

  defp apply_action(socket, :new) do
    form =
      socket.assigns.resource
      |> AshPhoenix.Form.for_create(:create, as: "record")
      |> to_form()

    assign(socket, form: form, page_title: "New #{socket.assigns.meta.label}")
  end

  defp apply_action(socket, :index), do: assign(socket, form: nil)

  defp load(socket) do
    %{resource: resource, q: q, sort: sort, dir: dir, page: page} = socket.assigns

    query =
      resource
      |> Ash.Query.new()
      |> search(resource, q)

    sort_field = sort_field(resource, sort)

    {micros, {total, records}} =
      :timer.tc(fn ->
        total = Ash.count!(query)

        records =
          query
          |> Ash.Query.sort([{sort_field, Explorer.QueryBuilder.sort_order(dir)}])
          |> Ash.Query.offset((page - 1) * @per_page)
          |> Ash.Query.limit(@per_page)
          |> Ash.read!()

        {total, records}
      end)

    columns =
      resource
      |> Catalog.display_attributes()
      |> Enum.reject(&(&1.primary_key? or &1.name in [:name, :description]))

    assign(socket,
      records: records,
      total: total,
      pages: max(div(total + @per_page - 1, @per_page), 1),
      columns: columns,
      micros: micros
    )
  end

  # Case-insensitive match on any string attribute. Not pushed down to glider
  # (only `attr == literal` is), so Ash evaluates it in Elixir after a label scan.
  defp search(query, _resource, ""), do: query

  defp search(query, resource, q) do
    needle = String.downcase(q)

    condition =
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.filter(&(&1.type == Ash.Type.String))
      |> Enum.map(fn attr -> expr(contains(string_downcase(^ref(attr.name)), ^needle)) end)
      |> Enum.reduce(fn e, acc -> expr(^acc or ^e) end)

    Ash.Query.do_filter(query, condition)
  end

  defp sort_field(resource, sort) do
    case Enum.find(Ash.Resource.Info.public_attributes(resource), &(to_string(&1.name) == sort)) do
      nil -> :name
      attr -> attr.name
    end
  end

  # ------------------------------------------------------------------ events

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns, q: q, page: 1))}
  end

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
         |> put_flash(:info, "Created #{record.name}")
         |> push_navigate(to: Catalog.path(record))}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    record = Ash.get!(socket.assigns.resource, id)
    Ash.destroy!(record)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{record.name} and its edges")
     |> ExplorerWeb.Nav.refresh_counts()
     |> load()}
  end

  defp list_path(a, overrides) do
    params =
      %{q: a.q, sort: a.sort, dir: a.dir, page: a.page}
      |> Map.merge(Map.new(overrides))
      |> Enum.reject(fn {k, v} ->
        v in ["", nil] or {k, v} in [page: 1, sort: "name", dir: "asc"]
      end)

    "/r/#{a.meta.slug}?" <> URI.encode_query(params)
  end

  defp sort_link(a, field) do
    field = to_string(field)
    dir = if a.sort == field and a.dir == "asc", do: "desc", else: "asc"
    list_path(a, sort: field, dir: dir, page: 1)
  end

  # ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} counts={@counts} current_path={@current_path}>
      <header class="page-head">
        <div>
          <h1><span class="dot big" style={"background: #{@meta.color}"}></span>{@meta.plural}</h1>
          <p class="sub">
            Nodes labelled <code>:{@meta.label}</code>, read through <code>{inspect(@resource)}</code>.
          </p>
        </div>
        <div class="actions">
          <.link patch={"/r/#{@meta.slug}/new"} class="btn">New {@meta.label}</.link>
        </div>
      </header>

      <section class="card">
        <div class="toolbar">
          <form id="search" phx-change="search" phx-submit="search" class="search">
            <input
              type="search"
              name="q"
              value={@q}
              placeholder={"Search #{String.downcase(@meta.plural)}…"}
              phx-debounce="250"
              autocomplete="off"
            />
          </form>
          <span class="muted">
            {@total} {if @total == 1, do: "record", else: "records"} · {fmt_micros(@micros)}
          </span>
        </div>

        <table class="table">
          <thead>
            <tr>
              <th>
                <.sort_header field={:name} sort={@sort} dir={@dir} href={sort_link(assigns, :name)} />
              </th>
              <th :for={c <- @columns}>
                <.sort_header
                  field={c.name}
                  sort={@sort}
                  dir={@dir}
                  href={sort_link(assigns, c.name)}
                />
              </th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @records} id={"row-#{r.id}"}>
              <td><.link navigate={Catalog.path(r)} class="strong">{r.name}</.link></td>
              <td :for={c <- @columns}><.value value={Map.get(r, c.name)} /></td>
              <td class="right nowrap">
                <.link navigate={"#{Catalog.path(r)}/edit"} class="btn ghost small">Edit</.link>
                <.confirm_button
                  id={"del-#{r.id}"}
                  event="delete"
                  value={%{id: r.id}}
                  class="btn danger small"
                  confirm="Delete?"
                >
                  Delete
                </.confirm_button>
              </td>
            </tr>
            <tr :if={@records == []}>
              <td colspan={length(@columns) + 2} class="empty">Nothing matches.</td>
            </tr>
          </tbody>
        </table>

        <nav :if={@pages > 1} class="pager">
          <.link :if={@page > 1} patch={list_path(assigns, page: @page - 1)} class="btn ghost small">
            Previous
          </.link>
          <span class="muted">Page {@page} of {@pages}</span>
          <.link
            :if={@page < @pages}
            patch={list_path(assigns, page: @page + 1)}
            class="btn ghost small"
          >
            Next
          </.link>
        </nav>
      </section>

      <.modal
        :if={@live_action == :new}
        id="new-record"
        title={"New #{@meta.label}"}
        on_cancel={JS.patch("/r/#{@meta.slug}")}
      >
        <.form for={@form} id="record-form" phx-change="validate" phx-submit="save">
          <.attr_input
            :for={attr <- Catalog.editable_attributes(@resource)}
            field={@form[attr.name]}
            attribute={attr}
          />
          <footer class="modal-foot">
            <.link patch={"/r/#{@meta.slug}"} class="btn ghost">Cancel</.link>
            <button type="submit" class="btn">Create</button>
          </footer>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  attr :field, :atom, required: true
  attr :sort, :string, required: true
  attr :dir, :string, required: true
  attr :href, :string, required: true

  defp sort_header(assigns) do
    assigns = assign(assigns, :active, assigns.sort == to_string(assigns.field))

    ~H"""
    <.link patch={@href} class={["sort", @active && "active"]}>
      {humanize(@field)}
      <span :if={@active}>{if @dir == "asc", do: "▲", else: "▼"}</span>
    </.link>
    """
  end
end
