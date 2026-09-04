# PGI

PGI is a simple and convenient interface for PostgreSQL with a few enhancements.
It gives you pooled, self-healing connections (`PGI::DB`), a super lightweight
repository toolkit (`PGI::Dataset`), and plain SQL migrations
(`PGI::SchemaMigrator`) — and nothing else. No ActiveRecord, no DSL to learn on
top of SQL you already know.

## PGI::DB

`PGI::DB` handles connections to a PostgreSQL database. It features:

* a connection pool
* connection auto-healing: lost connections and pool checkout timeouts share a
  retry budget, so a database restart is a pause, not a crash

```ruby
DB = PGI::DB.configure do |options|
  options.pool_size = 1
  options.pool_timeout = 5
  options.pg_conn_uri = "postgresql://pgi:password@localhost:5432/pgi_test"
  options.logger = Logger.new($stdout)
  options.max_retries = 30 # optional (default: 30, ~1 min of patience) - shared retry budget for lost connections
                           # and pool checkout timeouts; Float::INFINITY rides out any outage
  options.retry_wait = 2   # optional (default: 2) - seconds between reconnection attempts
end

DB.exec_stmt("my_stmt", "SELECT 1+1")
```

### Server notices go to your logger

Anything the server says on the side — a `RAISE NOTICE`, a `DROP CASCADE`'s
chatter — goes to the configured logger instead of libpq's stderr default,
and keeps its severity: a `RAISE WARNING` logs at `warn`, everything else at
`debug`. A logger running at INFO stays quiet through routine chatter but
still shows you warnings.

```ruby
DB.exec_stmt("noisy", "DO $$ BEGIN RAISE WARNING 'heads up'; END $$")
# => logger.warn("heads up")
```

## PGI::Dataset

`PGI::Dataset` is a super lightweight `ActiveRecord::Relation` replacement.
Extend a repository class with it and you get a clean querying interface:

```ruby
class Repository
  extend PGI::Dataset[DB, :members, scope: "deleted_at IS NULL"]
end

Repository.find(id)                     # one row by id
Repository.where(name: "joe").all       # rows matching a condition
Repository.page(nil, 20, :name, :asc)   # first page of 20, sorted by name
```

The pieces:

* `Dataset#select(column1, ...)` — start a query limited to the specified
  columns of the base table
* `Query#select(column1, ...)` — append a **joined** table's column onto the
  base table's columns, see [Projecting joined columns](#projecting-joined-columns)
* `#where(...)` — can only be called once per query, so combine all conditions
  in a single call. Two forms:
  * `#where("name = ? AND age > ?", ['joe', 21])` — a string clause with placeholders (`?` or `$1`)
  * `#where(name: 'joe')` — as a Hash (multiple keys are AND'ed together)
* `#order(:column, <:asc|:desc>)` — sort by column and direction, can be invoked multiple times
* `#limit(<num>)` — cap the number of rows
* `#first` / `#all` — one row / all rows
* `#count` — number of rows
* `#page(cursor, size, sort_by, sort_dir)` — keyset pagination (see below)
* `#join(table, on:)` — INNER JOIN for filtering and sorting ([Joins](#joins))
* `#search(columns, terms)` — substring search across columns ([Search](#search))
* `#project(*names)` — opt into declared computed columns ([Projections](#projections--computed-columns-you-opt-into))

### Keyset pagination

`#page` fetches rows at constant cost no matter how deep you page. The cursor
is always the **id of the last row** from the previous page; pass `nil` for the
first page.

```ruby
# First page — sorted by name
page1 = Repository.page(nil, 20, :name, :asc)

# Next page — pass the id of the last row as the cursor
page2 = Repository.page(page1.last["id"], 20, :name, :asc)
```

Each column used as `sort_by` needs a **composite** index on `(column, id)` —
two separate single-column indexes are not sufficient, because Postgres needs
the combined ordering to seek directly to the cursor position:

```sql
CREATE INDEX ON members (name ASC, id ASC);
CREATE INDEX ON members (created_at ASC, id ASC);
```

Generated SQL for page 2 (`sort_by != :id`):
```sql
SELECT * FROM members
WHERE deleted_at IS NULL
  AND (name, id) > (SELECT name, id FROM members WHERE id = $1)
ORDER BY name ASC, id ASC
LIMIT 20
```

Generated SQL for page 2 (`sort_by == :id`):
```sql
SELECT * FROM members
WHERE deleted_at IS NULL
  AND id > $1
ORDER BY id ASC
LIMIT 20
```

How it works:

- **Sorting by id** — `WHERE id > $cursor ORDER BY id`. Simple seek on the
  primary key index.
- **Sorting by another column** — the composite subquery cursor above keeps
  pages globally sorted: Postgres resolves the subquery via the primary-key
  index (one fast lookup), then uses the composite `(sort_col, id)` index to
  seek to that exact position and scan forward.
- `LIMIT/OFFSET` scans and discards all prior rows on every page — cost grows
  with depth. Keyset pagination does not.

### Collation — locale-aware text ordering

Text sorts in whatever collation you name, per read. Danish files
`æ ø å` after `z`; the database's default (often `en_US`) files them wrong.

```ruby
Repository.order(:name, :asc, collate: "da-x-icu").all
Repository.page(cursor, 20, :name, :asc, collate: "da-x-icu")
```

The named collation must exist in the database (Postgres ships ICU collations
like `da-x-icu`; `und-x-icu` is a sane universal order). For `#page`, the
composite index should be built with the same collation or Postgres falls back
to sorting.

### Joins

`#join(table, on:)` adds an `INNER JOIN` so `#where` and `#order` (and keyset
pagination) can reference the joined table's columns. Joins are for **filtering
and sorting only, not projection** — the select list stays the base table's
columns, so result rows still map to the base model unchanged.

```ruby
# Members that have an accepted membership in some account.
# `on:` maps base-table column => joined-table column.
Repository
  .join(:memberships, on: { id: :member_id })
  .where(memberships: { accepted: true })
  .all
```

```sql
SELECT "members".* FROM members
INNER JOIN "memberships" ON "members"."id" = "memberships"."member_id"
WHERE "memberships"."accepted" = true
```

A Hash value under a table-name key (`memberships: { accepted: true }`)
qualifies its columns with that table — the key must be the base table or an
already-joined table, never guessed. `#order` takes the same
`{ table => column }` form to sort by a joined column.

`#join` returns a `Query` yielding **raw row hashes** (like `#where`); model
mapping is reserved for `Dataset` methods. For a paginated, model-mapped joined
read, pass the `joins:` keyword to `#page`:

```ruby
# Page members sorted by their user's name.
Repository.page(cursor, 20, { users: :name }, :asc,
                joins: { memberships: { id: :member_id },
                         users:       { { memberships: :user_id } => :id } })
```

`joins:` maps *joined table => on-mapping*. An on-key may itself be qualified
(`{ { memberships: :user_id } => :id }`) to chain a **second hop** off an
earlier join — join `memberships` to the base, then join `users` to
`memberships`. The referenced table must already be joined, so **declare joins
in dependency order** (an ordered Hash preserves it).

Notes:

- Keyset pagination over a joined sort column requires **at most one joined row
  per base row** (e.g. `FK -> PK`); with 1:N joins the page boundaries are
  ill-defined and the cursor lookup fails.
- A `scope:` with unqualified columns becomes ambiguous once a join shares a
  column name — qualify the scope's columns (e.g. `members.deleted_at IS NULL`).

### Projecting joined columns

`#join` is filter/sort-only — the projection stays `"base".*`. To also
**return** a joined table's column, append it with `#select`:

```ruby
# Teams the base row belongs to, plus the roster row's `owner` flag.
Repository.join(:teammates, on: { id: :team_id })
          .join(:memberships, on: { { teammates: :membership_id } => :id })
          .select({ teammates: :owner })
          .where(memberships: { user_id: user_id })
          .to_a
# SELECT "teams".*, "teammates"."owner" FROM teams INNER JOIN ...
```

`#select` takes the same grammar as `#join`/`#where`: a bare column (qualified
with the base table) or a `{ table => column }` pair. An alias form
`{ table => { column => alias } }` renders `AS "alias"`.

Because a projected joined column is by definition absent from the base model's
schema, a `Query` carrying `#select` yields **raw row hashes only** — it never
threads through `#page`/`#all` model mapping. `"base".*` is opaque (pgi has no
schema introspection), so a joined column that shares a base column's name
cannot be caught up front; it surfaces as a duplicate result field and `#to_a`/
`#first`/`#each` **raise**. Pre-empt it with the alias form.

### Projections — computed columns you opt into

`projections:` declares named computed columns when the dataset is extended —
raw SQL you author, like `scope:`, never request data. Declaring costs
nothing: a projection is only evaluated when a read **asks for it**, so the
cost of a computed column stays a visible, per-read decision.

```ruby
class TeamRepository
  extend PGI::Dataset[DB, :teams,
                      scope: "deleted_at IS NULL",
                      projections: { mates_count: "SELECT COUNT(*) FROM teammates WHERE team_id = teams.id" }]
end

TeamRepository.page(nil, 25, project: [:mates_count])     # the list pays for what it shows
TeamRepository.project(:mates_count).where(id: id).first  # chain form (raw rows)
TeamRepository.find(id)                                   # pays nothing
```

Notes:

- **Opt-in, never ambient** — an unprojected read carries no projection keys
  and pays no projection cost. Opting into an undeclared name raises.
  `#count` ignores projections (an aggregate has no row to enrich).
- **Writes shed projection keys** — a model round-trip (find → to_h → update)
  may carry projected attributes; INSERT/UPDATE drop them silently. Write
  RETURNING never projects: presence of a projected key means "this read chose
  to know".
- **Cost when opted in**: evaluated per *output* row — after WHERE/LIMIT — so
  a paginated read pays `page_size × subquery`. With an indexed correlate
  (e.g. `teammates(team_id)`) that is an index-only probe per row. Sorting or
  filtering **on** a projection promotes evaluation to the whole scope; that
  EXPLAIN is the caller's to own. If a projection ever measures hot, the
  escalation is a trigger-maintained column, not a cleverer query.
- **A colliding name raises** — a projection named after a base column would
  overwrite it in the row hash, so the read raises when the rows come back
  (same guard as an unaliased joined column). Pick names that cannot collide
  (`mates_count`, not `count`).

### Search

`#search(columns, terms)` adds a case-insensitive substring search and AND's it
into the WHERE clause. Each term becomes an OR-group of `ILIKE` matches across
every column — a term hits when **any** column contains it, and a row matches
only when **every** term hits somewhere. That is the behaviour of a search box
that narrows as words are added: "john smith" finds the row named
"Smith, John". Tokenising the query string is the caller's job; pass the terms
as an array.

```ruby
# Chain form:
Repository.search([:name, :email], %w[john smith]).all

# Paginated, across a join:
Repository.page(cursor, 20, :name, :asc,
                search: { columns: [{ users: :name }, { users: :email }],
                          terms:   %w[john smith] },
                joins:  { users: { user_id: :id } })
```

LIKE metacharacters (`% _ \`) in a term are escaped so they match literally;
blank terms are dropped. Columns take the same `{ table => column }` grammar as
`#where`, so a search spans the same joins. It only adds a predicate, so it is
**keyset-compatible** — the cursor stays on the sort column.

### Constraints

- **`sort_by` columns must be `NOT NULL`.** SQL row comparison with NULL yields
  NULL, so rows with a NULL sort value are silently excluded from every cursor
  page — and if the anchor row itself has a NULL sort value, the next page
  comes back empty mid-stream.
- **Hard-deleting an anchor row ends that pagination sequence.** The anchor
  lookup is by primary key; if the row is gone, the next page is empty and
  indistinguishable from the end of the result set. Soft deletion via a
  `scope:` (e.g. `deleted_at IS NULL`) is safe — the anchor lookup deliberately
  bypasses the scope, so a row that left the scope between pages still anchors
  correctly.
- **Every table is expected to have a unique, totally ordered `id`** (SERIAL,
  UUIDv7, ...) — it is the tie-breaker that makes pages deterministic, and the
  whole `Dataset` interface assumes it.

## PGI::SchemaMigrator

Plain up/down SQL migrations tracked in a `schema_migrations` table — no DSL,
the migration *is* the SQL.

## Development

Dependencies:

* https://github.com/ged/ruby-pg
* https://github.com/mperham/connection_pool

Run the test suite (rubocop + specs, against a containerized Postgres):

```
podman compose run --rm ruby
```

Or create a developer/test DB by hand:

```
sudo su - postgres
psql -c "CREATE ROLE pgi WITH login password 'password';"
createdb --owner pgi pgi_test
psql pgi_test -c 'CREATE EXTENSION IF NOT EXISTS "pgcrypto";'
```
