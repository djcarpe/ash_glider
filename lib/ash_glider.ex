defmodule AshGlider do
  @moduledoc """
  An [Ash](https://ash-hq.org) data layer for glider, an embeddable
  property-graph database.

    * `AshGlider.Graph` owns a database and its lifecycle in your supervision
      tree.
    * `AshGlider.DataLayer` stores each record as a node, pushes filters,
      limits and offsets into the query, and runs actions in transactions.
    * `AshGlider.Edge` connects records with real relationships and traverses
      them: variable-length hops, shortest paths, graph algorithms.

  Queries reach glider through `Glider.Query`, so every value travels as a
  parameter and never as spliced text.
  """
end
