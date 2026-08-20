# PGI

PGI is a simple and convenient interface for PostgreSQL with a few enhancements.

## PGI::DB

The `PGI::DB` handles connections to a PostgreSQL databases. It features...

* Connection Pool
* Connection auto-healing capabilities

Usage:

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

## PGI::Dataset

The `PGI::Dataset` is a super light weight ActiveRecord::Relation replacement. It delivers a clean and simple querying interface:

* `#select(column1, ...)` allows you to limit the result set to only contain specified columns
* `#where(...)` - can only be called once per query, so combine all conditions in a single call. Two forms:
  * `#where("name = ? AND age > ?", ['joe', 21])` - a string clause with placeholders (`?` or `$1`)
  * `#where(name: 'joe')` - as a Hash (multiple keys are concatenated with an ' AND ')
* `#order(:column, <:asc|:desc>)` - sort result set by column and direction, can be invoked multiple times
* `#limit(<num>)` - limits the result set to the specified number of records
* `#first` - get the first record in a set
* `#all`- get an array of records
* `#count`- get the number of rows in a table
* `#page(cursor, size, sort_by, sort_dir)` - keyset pagination; pass `nil` for the first page, then the **id of the last row** as the cursor for each subsequent page

```ruby
class Repository
  extend PGI::Dataset[DB, :members, scope: "deleted_at IS NULL"]
end
```

### Projections — declared computed columns

`projections:` declares computed columns that ride **every read** of the
dataset, additively (`*` plus the declared expressions), and every write's
`RETURNING` — so the row shape is invariant: a found, listed, inserted or
updated row all carry the same keys. The trust model is `scope:`'s,
projection-side: the expression is raw SQL **authored at dataset-extension
time**, never request data; the name passes the column sanitizer.

```ruby
class TeamRepository
  extend PGI::Dataset[DB, :teams,
                      scope: "deleted_at IS NULL",
                      projections: { mates_count: "SELECT COUNT(*) FROM teammates WHERE team_id = teams.id" }]
end

TeamRepository.find(id)["mates_count"] # => 7, on every read AND write path
```

Notes:

- **Additive, always** — explicit `select(:id)` still appends the
  projections; they are facts of the dataset, not a per-query favor.
  `#count` skips them (an aggregate has no row to enrich).
- **Cost**: evaluated per *output* row — after WHERE/LIMIT — so a paginated
  read pays `page_size × subquery`. With an indexed correlate (e.g.
  `teammates(team_id)`) that is an index-only probe per row. Sorting or
  filtering **on** a projection promotes evaluation to the whole scope; that
  EXPLAIN is the declarer's to own. If a projection ever measures hot, the
  escalation is a trigger-maintained column, not a cleverer query.
- A projection name colliding with a base column will overwrite it in the
  row hash — pick names that cannot collide (`mates_count`, not `count`).

```sql
-- Each column used as sort_by in page() needs a composite index on (column, id).
-- Two separate single-column indexes are not sufficient — Postgres needs
-- the combined (column, id) ordering to seek directly to the cursor position.
CREATE INDEX ON members (name ASC, id ASC);
CREATE INDEX ON members (created_at ASC, id ASC);
```

```ruby
# First page — sorted by name
page1 = Repository.page(nil, 20, :name, :asc)

# Next page — pass the id of the last row as the cursor
page2 = Repository.page(page1.last["id"], 20, :name, :asc)
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

### How keyset pagination works

`#page` fetches rows at constant cost regardless of page depth. The cursor is always the scalar `id` of the last row from the previous page.

- **Sorting by id** — `WHERE id > $cursor ORDER BY id`. Simple seek on the primary key index.
- **Sorting by another column** — generates a composite subquery cursor so pages are globally sorted:
  ```sql
  WHERE (sort_col, id) > (SELECT sort_col, id FROM table WHERE id = $cursor)
  ORDER BY sort_col, id
  ```
  Postgres resolves the subquery via the primary-key index (a single fast lookup), then uses the composite `(sort_col, id)` index to seek directly to that position and scan forward. The two separate single-column indexes are not equivalent — a composite B-tree index is required so that Postgres can seek to an exact `(sort_col, id)` position rather than scanning and filtering.

`LIMIT/OFFSET` scans and discards all prior rows on every page request — cost grows linearly with depth. Keyset pagination does not.

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
already-joined table, never guessed. `#order` takes the same `{ table => column }`
form to sort by a joined column.

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

`#join` is filter/sort-only — the projection stays `"base".*`. To also **return**
a joined table's column, append it with `#select`:

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

### Search

`#search(columns, terms)` adds a case-insensitive substring search and AND's it
into the WHERE clause. Each term becomes an OR-group of `ILIKE` matches across
every column; the groups are AND'ed together — a term hits when **any** column
contains it, and a row matches only when **every** term hits somewhere (a search
box that narrows as words are added). Tokenising the query string is the
caller's job; pass the terms as an array.

```ruby
# Rows where each of "john" and "smith" appears in the name OR email.
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

- **`sort_by` columns must be `NOT NULL`.** SQL row comparison with NULL yields NULL, so rows with a NULL sort value are silently excluded from every cursor page — and if the anchor row itself has a NULL sort value, the next page comes back empty mid-stream.
- **Hard-deleting an anchor row ends that pagination sequence.** The anchor lookup is by primary key; if the row is gone, the next page is empty and indistinguishable from the end of the result set. Soft deletion via a `scope:` (e.g. `deleted_at IS NULL`) is safe — the anchor lookup deliberately bypasses the scope, so a row that left the scope between pages still anchors correctly.
- **Every table is expected to have a unique, totally ordered `id`** (SERIAL, UUIDv7, ...) — it is the tie-breaker that makes pages deterministic, and the whole `Dataset` interface assumes it.

## Documentation

Dependencies:

* https://github.com/ged/ruby-pg
* https://github.com/mperham/connection_pool

Create developer/test DB:

```
sudo su - postgres
psql -c "CREATE ROLE pgi WITH login password 'password';"
createdb --owner pgi pgi_test
psql pgi_test -c 'CREATE EXTENSION IF NOT EXISTS "pgcrypto";'
```
