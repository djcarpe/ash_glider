defmodule Explorer.Catalog do
  @moduledoc """
  What the explorer knows about the graph's shape: which resources exist, how
  they appear in URLs, and which edge types may connect them.

  Edge types are a whitelist on purpose. `AshGlider.Edge` interpolates the
  relationship type into Cypher, so the UI must never pass a user-typed type
  straight through.
  """

  alias Explorer.Directory.{Company, Person, Project}

  @resources [
    %{resource: Person, slug: "people", label: "Person", plural: "People", color: "#6aa8ff"},
    %{
      resource: Company,
      slug: "companies",
      label: "Company",
      plural: "Companies",
      color: "#f5b14c"
    },
    %{resource: Project, slug: "projects", label: "Project", plural: "Projects", color: "#4fd1a1"}
  ]

  @edge_types [
    %{
      type: "KNOWS",
      from: Person,
      to: Person,
      props: [since: :integer],
      describe: "a person knows another person"
    },
    %{
      type: "WORKS_AT",
      from: Person,
      to: Company,
      props: [title: :string, since: :integer],
      describe: "employment"
    },
    %{
      type: "CONTRIBUTES_TO",
      from: Person,
      to: Project,
      props: [commits: :integer],
      describe: "a person commits to a project"
    },
    %{
      type: "SPONSORS",
      from: Company,
      to: Project,
      props: [amount: :integer],
      describe: "a company funds a project"
    },
    %{
      type: "DEPENDS_ON",
      from: Project,
      to: Project,
      props: [],
      describe: "a project uses another project"
    }
  ]

  def resources, do: @resources
  def resource_modules, do: Enum.map(@resources, & &1.resource)
  def edge_types, do: @edge_types

  def by_slug(slug), do: Enum.find(@resources, &(&1.slug == slug))
  def by_label(label), do: Enum.find(@resources, &(&1.label == to_string(label)))
  def by_resource(resource), do: Enum.find(@resources, &(&1.resource == resource))

  def edge_type(type), do: Enum.find(@edge_types, &(&1.type == type))

  @doc "Edge types a record of `resource` can take part in, tagged with its end."
  def edge_types_for(resource) do
    for e <- @edge_types, e.from == resource or e.to == resource do
      e
    end
  end

  @doc "Path to a record's page."
  def path(%struct{id: id}), do: "/r/#{by_resource(struct).slug}/#{id}"

  @doc "Path to a raw glider node's page, if it belongs to a known resource."
  def node_path(%Glider.Node{labels: labels, props: props}) do
    with label when is_binary(label) <- List.first(labels),
         %{slug: slug} <- by_label(label),
         id when is_binary(id) <- props["id"] do
      "/r/#{slug}/#{id}"
    else
      _ -> nil
    end
  end

  def color(label) do
    case by_label(label) do
      %{color: c} -> c
      _ -> "#a0a7b4"
    end
  end

  @doc "Public attributes a form may edit, in declaration order."
  def editable_attributes(resource) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.filter(&(&1.writable? and not &1.primary_key?))
  end

  @doc "Every public attribute, for display."
  def display_attributes(resource), do: Ash.Resource.Info.public_attributes(resource)
end
