defmodule Explorer.Directory do
  @moduledoc """
  The demo domain: people, the companies they work at, and the open-source
  projects they contribute to. Records are glider nodes; the connections
  between them are real graph edges managed through `AshGlider.Edge`.
  """
  use Ash.Domain, otp_app: :explorer

  resources do
    resource Explorer.Directory.Person do
      define :create_person, action: :create
      define :list_people, action: :read
    end

    resource Explorer.Directory.Company do
      define :create_company, action: :create
    end

    resource Explorer.Directory.Project do
      define :create_project, action: :create
    end
  end
end
