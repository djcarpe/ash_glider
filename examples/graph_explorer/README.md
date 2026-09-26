# Graph Explorer — an ash_glider example

A Phoenix LiveView app for browsing, querying and editing a property graph
stored with [`ash_glider`](../../README.md). Every record is an Ash resource
persisted as a glider node; every connection is a real glider edge.


## Run it

```sh
# glider_ex compiles a Rust NIF, so cargo must be on the PATH
export PATH="$HOME/.cargo/bin:$PATH"

cd examples/graph_explorer
mix setup
mix phx.server          # http://localhost:4000  (PORT=4001 mix phx.server to change)
```

The graph is one file, `priv/graph/explorer.gldb`. On first boot the app seeds
a demo graph: 24 people, 7 companies and 12 open-source projects, connected by
66 edges. **Overview → Reset demo data** (or `mix explorer.reset`) restores it.

## What to show

| Page | What it demonstrates |
|---|---|
| **Overview** | Node, edge, label and index counts from `Glider.schema/1`. A force-directed drawing of the whole graph (drag, scroll to zoom, click to open). The most central records per resource, read back through an Ash sort on `rank` after PageRank wrote it. |
| **People / Companies / Projects** | Plain Ash CRUD on the glider data layer: search, sortable columns, pagination, a create form built from the resource's attributes (validation errors included), and delete. |
| **A record** | Attributes, edit and delete. Deleting uses `DETACH DELETE`, so its edges go too. The neighbourhood canvas shows 1 or 2 hops. The edge table lists both directions, and each edge's properties can be edited or the edge removed. **Add an edge** calls `AshGlider.Edge.relate/4` with typed properties. **Traverse** calls `AshGlider.Edge.related/3` over a depth range and direction. **Shortest path** finds a path to any record of any resource. |
| **Query → Ash query** | A filter builder over any resource. It shows the equivalent Elixir, and splits the plan into what is pushed into glider's `MATCH` (`attr == literal`, marked when an index serves it) and what `Ash.Filter.Runtime` evaluates. |
| **Query → Cypher** | Raw glider Cypher with example queries, a result table with linked nodes, and a drawing of any nodes and edges returned. |
| **Query → Algorithms** | PageRank, degree, betweenness, closeness, components, communities, k-core and triangles, optionally restricted by edge type and direction. "Write to rank" stores the scores as an Ash attribute. |

A suggested five-minute demo:

1. Open **Overview** and click a hub such as *Linus Torvalds*.
2. On his page switch to **2 hops**, then **Traverse** `:KNOWS`, `both`, `1..3`.
3. **Shortest path** to the project *Erlang/OTP*. The path crosses people and projects.
4. **Add an edge** from him to a project, then edit its `commits`.
5. **Query → Ash query → "60+ and knows compilers"** shows one condition pushed down and the others in Elixir.
6. **Query → Cypher → "Commits per project"** runs an aggregate in glider.
7. **Query → Algorithms → pagerank with "write to rank"**, then sort **People** by rank.

## Layout

```
lib/explorer/
  directory/*.ex     Person, Company, Project — Ash resources on AshGlider.DataLayer
  catalog.ex         resource ↔ label ↔ URL mapping, and the whitelist of edge types
  graph_ops.ex       edges, neighbourhoods, traversal, paths, algorithms, raw Cypher
  query_builder.ex   form state → Ash.Query, plus the "what glider sees" plan
  seeds.ex           the demo graph
lib/explorer_web/
  live/              DashboardLive, ResourceLive, RecordLive, QueryLive
priv/static/assets/  graph.js (dependency-free force layout hook), app.js, app.css
```

There is no JS bundler and no CDN: Phoenix and LiveView's own browser builds
are served straight from their packages, so the app runs offline.

## Notes

* Edge types are a whitelist in `Explorer.Catalog`. `AshGlider.Edge`
  interpolates the relationship type into Cypher, so user input never reaches
  it directly.
* The shortest-path panel uses `Explorer.GraphOps.path/3` rather than
  `AshGlider.Edge.path/3`, because the latter loads every step as a single
  resource and drops steps with other labels.
* Writes made on the Cypher tab bypass Ash validations. The resource pages are
  the right place for data changes.

## Tests

```sh
mix test
```

The suite covers graph operations, the query builder and pushdown plan, and
every LiveView: CRUD, validation, edge create/edit/delete in both directions,
traversal, paths, the Cypher console and algorithms.
