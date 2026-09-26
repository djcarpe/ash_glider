defmodule AshGlider.Test.Graph do
  @moduledoc false
  use AshGlider.Graph, otp_app: :ash_glider
end

defmodule AshGlider.Test.Person do
  @moduledoc false
  use Ash.Resource,
    domain: AshGlider.Test.Domain,
    data_layer: AshGlider.DataLayer

  graph do
    graph(AshGlider.Test.Graph)
    label(:Person)
    index([:email])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:email, :string, public?: true)
    attribute(:age, :integer, public?: true)
    attribute(:active, :boolean, public?: true, default: true)
    attribute(:score, :float, public?: true)
    attribute(:role, :atom, public?: true, constraints: [one_of: [:admin, :member, :guest]])
    attribute(:tags, {:array, :string}, public?: true)
    attribute(:settings, :map, public?: true)
    attribute(:joined_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGlider.Test.Company do
  @moduledoc false
  use Ash.Resource,
    domain: AshGlider.Test.Domain,
    data_layer: AshGlider.DataLayer

  graph do
    graph(AshGlider.Test.Graph)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGlider.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGlider.Test.Person)
    resource(AshGlider.Test.Company)
  end
end
