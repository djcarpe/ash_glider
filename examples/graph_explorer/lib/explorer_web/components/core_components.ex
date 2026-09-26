defmodule ExplorerWeb.CoreComponents do
  @moduledoc "Small, dependency-free UI components."
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  # ------------------------------------------------------------------ flash

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="flash-group">
      <div
        :for={{kind, msg} <- @flash}
        :if={kind in ["info", "error"]}
        id={"flash-#{kind}"}
        class={["flash", "flash-#{kind}"]}
        phx-click={JS.push("lv:clear-flash", value: %{key: kind}) |> JS.hide(to: "#flash-#{kind}")}
        role="alert"
      >
        {msg}
        <span class="flash-close">×</span>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------ modal

  attr :id, :string, required: true
  attr :on_cancel, JS, default: %JS{}
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div id={@id} class="modal-backdrop" phx-window-keydown={@on_cancel} phx-key="escape">
      <div class="modal" phx-click-away={@on_cancel}>
        <header class="modal-head">
          <h2>{@title}</h2>
          <button type="button" class="icon-btn" phx-click={@on_cancel} aria-label="close">×</button>
        </header>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------- confirm

  @doc """
  A button that asks twice. The first click swaps it for "confirm / cancel"
  inline, rather than a browser dialog.
  """
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value, :map, default: %{}
  attr :class, :string, default: "btn danger"
  attr :confirm, :string, default: "Really?"
  slot :inner_block, required: true

  def confirm_button(assigns) do
    ~H"""
    <span id={@id} class="confirm">
      <button
        type="button"
        class={[@class, "ask"]}
        phx-click={
          JS.hide(to: "##{@id} .ask") |> JS.show(to: "##{@id} .sure", display: "inline-flex")
        }
      >
        {render_slot(@inner_block)}
      </button>
      <span class="sure" style="display: none">
        <span class="muted">{@confirm}</span>
        <button type="button" class="btn danger small" phx-click={JS.push(@event, value: @value)}>
          Yes
        </button>
        <button
          type="button"
          class="btn ghost small"
          phx-click={
            JS.show(to: "##{@id} .ask", display: "inline-flex") |> JS.hide(to: "##{@id} .sure")
          }
        >
          No
        </button>
      </span>
    </span>
    """
  end

  # ------------------------------------------------------------ attribute IO

  @doc """
  One form input for one Ash attribute, chosen from the attribute's type:
  checkbox, number, select (for `one_of` atoms), comma-separated list, or text.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :attribute, :any, required: true

  def attr_input(assigns) do
    assigns =
      assigns
      |> assign(:kind, input_kind(assigns.attribute))
      |> assign(:errors, errors(assigns.field))
      |> assign(:label, humanize(assigns.attribute.name))

    ~H"""
    <div class={["field", @errors != [] && "has-error"]}>
      <%= case @kind do %>
        <% :checkbox -> %>
          <label class="check">
            <input type="hidden" name={@field.name} value="false" />
            <input
              type="checkbox"
              id={@field.id}
              name={@field.name}
              value="true"
              checked={@field.value in [true, "true"]}
            />
            {@label}
          </label>
        <% :select -> %>
          <label for={@field.id}>{@label}</label>
          <select id={@field.id} name={@field.name}>
            <option value="">—</option>
            <option
              :for={opt <- @attribute.constraints[:one_of]}
              value={opt}
              selected={to_string(@field.value) == to_string(opt)}
            >
              {opt}
            </option>
          </select>
        <% :list -> %>
          <label for={@field.id}>{@label} <small>comma separated</small></label>
          <input type="text" id={@field.id} name={@field.name} value={list_value(@field.value)} />
        <% :textarea -> %>
          <label for={@field.id}>{@label}</label>
          <textarea id={@field.id} name={@field.name} rows="3">{@field.value}</textarea>
        <% kind -> %>
          <label for={@field.id}>{@label}</label>
          <input
            type={if kind in [:integer, :float], do: "number", else: "text"}
            step={if kind == :float, do: "any"}
            id={@field.id}
            name={@field.name}
            value={Phoenix.HTML.Form.normalize_value("text", @field.value)}
          />
      <% end %>
      <p :for={msg <- @errors} class="error">{msg}</p>
    </div>
    """
  end

  def input_kind(%{type: Ash.Type.Boolean}), do: :checkbox
  def input_kind(%{type: Ash.Type.Integer}), do: :integer
  def input_kind(%{type: Ash.Type.Float}), do: :float
  def input_kind(%{type: {:array, _}}), do: :list
  def input_kind(%{name: :description}), do: :textarea

  def input_kind(%{type: Ash.Type.Atom, constraints: c}) do
    if is_list(c[:one_of]), do: :select, else: :text
  end

  def input_kind(_), do: :text

  defp list_value(v) when is_list(v), do: Enum.join(v, ", ")
  defp list_value(v), do: v

  defp errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field),
      do: Enum.map(field.errors, &translate_error/1),
      else: []
  end

  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  def translate_error(msg) when is_binary(msg), do: msg

  @doc """
  Turn a comma-separated string back into a list for `{:array, _}`
  attributes, so the form can round-trip what `attr_input/1` renders.
  """
  def normalize_params(resource, params) do
    Enum.reduce(Ash.Resource.Info.public_attributes(resource), params, fn
      %{type: {:array, _}, name: name}, acc ->
        key = to_string(name)

        case acc do
          %{^key => v} when is_binary(v) ->
            Map.put(
              acc,
              key,
              v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
            )

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  # --------------------------------------------------------------- display

  attr :value, :any, required: true

  def value(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@value) or @value == [] -> %>
        <span class="muted">—</span>
      <% is_list(@value) -> %>
        <span :for={v <- @value} class="tag">{v}</span>
      <% is_boolean(@value) -> %>
        <span class={["bool", @value && "yes"]}>{if @value, do: "yes", else: "no"}</span>
      <% is_float(@value) -> %>
        <span class="num">{Float.round(@value, 4)}</span>
      <% is_integer(@value) -> %>
        <span class="num">{@value}</span>
      <% true -> %>
        {to_string(@value)}
    <% end %>
    """
  end

  attr :label, :string, required: true

  def label_chip(assigns) do
    ~H"""
    <span class="chip" style={"--c: #{Explorer.Catalog.color(@label)}"}>{@label}</span>
    """
  end

  @doc "A node on a result table: a linked chip, or plain text if unknown."
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :path, :string, default: nil

  def node_ref(assigns) do
    ~H"""
    <span class="node-ref">
      <.label_chip :if={@label} label={@label} />
      <.link :if={@path} navigate={@path}>{@name}</.link>
      <span :if={!@path}>{@name}</span>
    </span>
    """
  end

  # ----------------------------------------------------------------- canvas

  @doc """
  A force-directed graph. The hook reads `data-graph`; the inner container is
  `phx-update="ignore"` so LiveView never clobbers the SVG it draws.
  """
  attr :id, :string, required: true
  attr :graph, :map, required: true
  attr :height, :integer, default: 460

  def graph_canvas(assigns) do
    ~H"""
    <div
      id={@id}
      class="graph-canvas"
      phx-hook="Graph"
      data-graph={Jason.encode!(@graph)}
      style={"height: #{@height}px"}
    >
      <div id={"#{@id}-svg"} phx-update="ignore" class="graph-svg"></div>
      <div class="graph-legend">
        <span :for={r <- Explorer.Catalog.resources()}>
          <span class="dot" style={"background: #{r.color}"}></span>{r.label}
        </span>
        <span class="muted">drag · scroll to zoom · click to open</span>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------- helpers

  def humanize(atom) when is_atom(atom), do: atom |> to_string() |> humanize()
  def humanize(s), do: s |> String.replace("_", " ") |> String.capitalize()

  def fmt_micros(us) when us < 1000, do: "#{us} µs"
  def fmt_micros(us), do: "#{Float.round(us / 1000, 2)} ms"
end
