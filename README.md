# AshGlider

An [Ash](https://ash-hq.org) data layer backed by
[glider](../glider), an embeddable property-graph database.

Records are nodes. Attributes are properties. Relationships can be real graph
edges, traversable to arbitrary depth.

```elixir
defmodule MyApp.Graph do
  use AshGlider.Graph, otp_app: :my_app
end

defmodule MyApp.Person do
  use Ash.Resource, domain: MyApp.Domain, data_layer: AshGlider.DataLayer

  graph do
    graph MyApp.Graph
    label :Person
    index [:email]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :email, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

Add the graph to your supervision tree and configure it (omit `:path` for an
in-memory graph):

```elixir
children = [MyApp.Graph]

config :my_app, MyApp.Graph, path: "priv/graph/my_app.gldb", sync: :normal
```

Then use Ash normally:

```elixir
ada = MyApp.Person |> Ash.Changeset.for_create(:create, %{name: "Ada"}) |> Ash.create!()
MyApp.Person |> Ash.Query.filter(email == "ada@example.com") |> Ash.read!()
```

## Edges: the part a foreign key cannot do

An Ash `belongs_to`/`has_many` works here — records are nodes, foreign keys are
properties — and you should keep using it for ordinary parent/child modelling.

What it cannot express is an edge with its own properties, traversed to
arbitrary depth in either direction without a join per hop. That is what
`AshGlider.Edge` is for:

```elixir
AshGlider.Edge.relate(ada, :KNOWS, bob, %{since: 2019})

{:ok, friends}  = AshGlider.Edge.related(ada, :KNOWS)
{:ok, network}  = AshGlider.Edge.related(ada, :KNOWS, depth: 1..3)
{:ok, admirers} = AshGlider.Edge.related(bob, :KNOWS, direction: :in)
{:ok, path}     = AshGlider.Edge.path(ada, cai)
{:ok, colleagues} = AshGlider.Edge.related(ada, :WORKS_AT, destination: MyApp.Company)
```

Graph algorithms run over the same data, and can write scores back as ordinary
attributes:

```elixir
{:ok, rows} = AshGlider.Edge.algorithm(MyApp.Person, :pagerank, iterations: 20, top: 10)
AshGlider.Edge.algorithm(MyApp.Person, :pagerank, write: "rank")
```

`destroy` uses `DETACH DELETE`, so a record's edges go with it. A dangling edge
would corrupt every traversal through that node.

## What is pushed down, and what is not

Top-level `attribute == literal` conjuncts become part of the `MATCH` pattern,
so an indexed attribute is a seek rather than a scan. Everything else — `or`,
comparisons, expressions, relationship filters — is evaluated in Elixir by
`Ash.Filter.Runtime`, exactly as the ETS and Mnesia data layers do. The runtime
filter always runs afterwards, so a missed pushdown costs speed, never
correctness.

That is a deliberate trade. glider is memory-resident and reads never touch
disk, so a label scan walks memory rather than doing IO.

**The consequence worth planning around:** cost is proportional to the number of
nodes carrying the label, not to the number of rows returned. Use `index` for
attributes you filter on by equality.

## Storage format

Attributes are stored as glider properties, encoded so the graph stays readable
from `glider browser` or any other client:

| Ash type | stored as |
|---|---|
| string, integer, float, boolean | natively |
| atom | string |
| uuid | canonical `8-4-4-4-12` string, not raw bytes |
| date / time / datetime | ISO 8601 string |
| decimal | string |
| array of scalars | list |
| map, struct, embedded, union | JSON string |
| binary | base64 |

Decoding is driven by the **resource's own attribute type**, not by a marker in
the stored value. Changing an attribute's type is therefore a migration, as it
would be in a SQL data layer.

A `nil` attribute is absent from the node rather than stored as an explicit
null, which is how glider represents "unset".

## Limitations

  * **No transactions.** glider has `BEGIN`/`COMMIT`, but a rollback that also
    unwinds in-memory state is not something this layer can honestly promise,
    so `can?(:transact)` is `false` and Ash runs actions without one.
  * **No upsert**, and no atomic updates.
  * **The graph must fit in RAM.** It is memory-resident by design.
  * **One writer per file.** A second `open` on the same path is refused while
    the first handle is alive.

## Telemetry

Every statement this data layer runs goes through `Glider.query/3`, so it
emits glider_ex's `[:glider, :query, ...]` telemetry span, carrying the
engine's own report: operation, rows, pages read and cache hits. Call
`Glider.OpenTelemetry.setup/0` next to your other instrumentation and each
Ash read or write shows its glider statements as `glider MATCH` / `glider
CREATE` client spans, children of whatever span the action runs in. They
include `db.query.text`, which is the Cypher the filter pushdown produced. See
`Glider.Telemetry` for the metrics.

## Example app

`examples/graph_explorer` is a Phoenix LiveView app built on this data layer.
It lets you browse, search, create, edit and delete records and edges, run
traversals, shortest paths and algorithms, and see which filters are pushed
down into glider. See its README for how to run it.

## Testing

```sh
mix test
```

The suite covers CRUD, every supported attribute type, filter pushdown and
fallback, sort/limit/offset, aggregates, edges, traversal, shortest path,
algorithms, and a Cypher-injection guard.
