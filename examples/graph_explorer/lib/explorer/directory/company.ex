defmodule Explorer.Directory.Company do
  use Ash.Resource, domain: Explorer.Directory, data_layer: AshGlider.DataLayer

  graph do
    graph(Explorer.Graph)
    label(:Company)
    index([:industry])
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
    attribute :industry, :string, public?: true
    attribute :city, :string, public?: true
    attribute :founded, :integer, public?: true
    attribute :listed, :boolean, public?: true, default: false
    attribute :rank, :float, public?: true, writable?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
