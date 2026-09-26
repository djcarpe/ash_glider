defmodule Explorer.Directory.Person do
  use Ash.Resource, domain: Explorer.Directory, data_layer: AshGlider.DataLayer

  graph do
    graph(Explorer.Graph)
    label(:Person)
    # Equality filters on these become index seeks instead of label scans.
    index([:email, :city])
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
    attribute :email, :string, public?: true

    attribute :role, :atom,
      public?: true,
      constraints: [one_of: [:engineer, :designer, :manager, :researcher, :founder]]

    attribute :city, :string, public?: true
    attribute :age, :integer, public?: true, constraints: [min: 0, max: 150]
    attribute :skills, {:array, :string}, public?: true, default: []
    attribute :active, :boolean, public?: true, default: true
    # Written back by `CALL pagerank(write: "rank")`, then readable through Ash.
    attribute :rank, :float, public?: true, writable?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
