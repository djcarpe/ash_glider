defmodule ExplorerWeb.ConnCase do
  @moduledoc """
  Every test gets the demo graph freshly seeded. The graph is one in-memory
  glider handle shared by the whole run, so these tests are not async.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ExplorerWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import ExplorerWeb.ConnCase
      alias Explorer.{Catalog, GraphOps}
      alias Explorer.Directory.{Company, Person, Project}
    end
  end

  setup do
    Explorer.Seeds.reset!()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  require Ash.Query

  def person!(name) do
    Explorer.Directory.Person |> Ash.Query.filter(name == ^name) |> Ash.read_one!()
  end

  def project!(name) do
    Explorer.Directory.Project |> Ash.Query.filter(name == ^name) |> Ash.read_one!()
  end

  def company!(name) do
    Explorer.Directory.Company |> Ash.Query.filter(name == ^name) |> Ash.read_one!()
  end
end
