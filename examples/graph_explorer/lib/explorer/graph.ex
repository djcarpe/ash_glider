defmodule Explorer.Graph do
  @moduledoc "The glider graph that every resource in this app is stored in."
  use AshGlider.Graph, otp_app: :explorer
end
