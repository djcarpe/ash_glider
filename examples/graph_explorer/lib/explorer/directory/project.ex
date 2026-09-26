defmodule Explorer.Directory.Project do
  use Ash.Resource, domain: Explorer.Directory, data_layer: AshGlider.DataLayer

  graph do
    graph(Explorer.Graph)
    label(:Project)
    index([:language])
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
    attribute :description, :string, public?: true
    attribute :language, :string, public?: true

    attribute :status, :atom,
      public?: true,
      default: :active,
      constraints: [one_of: [:active, :maintained, :archived]]

    attribute :stars, :integer, public?: true, default: 0, constraints: [min: 0]
    attribute :rank, :float, public?: true, writable?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
