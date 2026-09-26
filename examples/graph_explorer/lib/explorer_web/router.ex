defmodule ExplorerWeb.Router do
  use ExplorerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExplorerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", ExplorerWeb do
    pipe_through :browser

    live_session :default, on_mount: ExplorerWeb.Nav do
      live "/", DashboardLive
      live "/query", QueryLive
      live "/r/:resource", ResourceLive, :index
      live "/r/:resource/new", ResourceLive, :new
      live "/r/:resource/:id", RecordLive, :show
      live "/r/:resource/:id/edit", RecordLive, :edit
    end
  end
end
