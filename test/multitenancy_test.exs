defmodule AshGlider.MultitenancyTest do
  use ExUnit.Case, async: false

  # One in-memory database per tenant, looked up by name.
  defmodule TenantGraph do
    use AshGlider.Graph, otp_app: :ash_glider

    def start_tenants(tenants) do
      for t <- tenants do
        {:ok, h} = Glider.open()
        :persistent_term.put({__MODULE__, :tenant, t}, h)
      end

      :ok
    end

    @impl AshGlider.Graph
    def handle(tenant) do
      :persistent_term.get({__MODULE__, :tenant, tenant}, nil) ||
        raise "no database for tenant #{inspect(tenant)}"
    end
  end

  defmodule Thing do
    use Ash.Resource, domain: AshGlider.MultitenancyTest.Domain, data_layer: AshGlider.DataLayer

    graph do
      graph(AshGlider.MultitenancyTest.TenantGraph)
      label(:Thing)
      index([:name])
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: [:name], update: [:name]])
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshGlider.MultitenancyTest.Thing)
    end
  end

  # Fresh databases per test, so tests cannot see each other's rows.
  setup do
    n = System.unique_integer([:positive])
    acme = "acme-#{n}"
    globex = "globex-#{n}"
    TenantGraph.start_tenants([acme, globex])
    {:ok, acme: acme, globex: globex}
  end

  test "each tenant reads and writes its own database", %{acme: acme, globex: globex} do
    {:ok, a} =
      Thing
      |> Ash.Changeset.for_create(:create, %{name: "acme thing"}, tenant: acme)
      |> Ash.create()

    {:ok, _} =
      Thing
      |> Ash.Changeset.for_create(:create, %{name: "globex thing"}, tenant: globex)
      |> Ash.create()

    assert [%{name: "acme thing"}] = Ash.read!(Thing, tenant: acme)
    assert [%{name: "globex thing"}] = Ash.read!(Thing, tenant: globex)

    {:ok, _} =
      a |> Ash.Changeset.for_update(:update, %{name: "renamed"}, tenant: acme) |> Ash.update()

    assert [%{name: "renamed"}] = Ash.read!(Thing, tenant: acme)
    assert [%{name: "globex thing"}] = Ash.read!(Thing, tenant: globex)

    :ok = Ash.destroy!(Ash.read_one!(Thing, tenant: acme), tenant: acme)
    assert [] = Ash.read!(Thing, tenant: acme)
    assert [_] = Ash.read!(Thing, tenant: globex)
  end

  test "a filtered read stays inside the tenant's database", %{acme: acme, globex: globex} do
    {:ok, _} =
      Thing
      |> Ash.Changeset.for_create(:create, %{name: "shared name"}, tenant: acme)
      |> Ash.create()

    {:ok, _} =
      Thing
      |> Ash.Changeset.for_create(:create, %{name: "shared name"}, tenant: globex)
      |> Ash.create()

    require Ash.Query
    assert [_] = Thing |> Ash.Query.filter(name == "shared name") |> Ash.read!(tenant: acme)
  end
end
