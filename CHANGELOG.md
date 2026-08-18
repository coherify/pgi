# CHANGELOG

## Unreleased

- `PGI::Query#select` — append qualified columns to a joined read's projection
  so it can return a joined table's columns alongside `"base".*` (`#join` stays
  filter/sort-only). Bare / `{ table => column }` / `{ table => { column => alias } }`
  grammar. Raw row hashes only (no model mapping); a projected column colliding
  with a base column name raises when the rows come back — alias to disambiguate.
- `PGI::Dataset#search` / `#page(search:)` — case-insensitive substring search:
  an OR-group of `ILIKE` matches per term, AND'ed together and into the WHERE.
  LIKE metacharacters are escaped; columns may be qualified with a joined table,
  so a search spans the same joins; keyset-compatible (adds only a predicate).
- `PGI::Dataset#join` / `#page(joins:)` — INNER JOINs for filtering and sorting
  on combined rows (result rows stay the base table's, so model mapping is
  unchanged). Qualified `where` (`{ users: { name: "x" } }`), qualified sort
  (`{ users: :name }`) and keyset pagination over a joined sort column (FK -> PK
  cardinality). Collation support on `#order`/`#keyset` for locale-aware text
  ordering. An `on:` key may itself be qualified
  (`{ { memberships: :user_id } => :id }`) to chain a second hop off an earlier
  join; declare joins in dependency order.

## 1.0.0

First public release.

- `PGI::DB` — pooled PostgreSQL access with auto-healing: lost connections and
  pool checkout timeouts share a configurable retry budget (`max_retries`,
  `retry_wait`; `Float::INFINITY` rides out arbitrarily long outages)
- `PGI::Connection` — thin `PG::Connection` wrapper with lazily auto-prepared
  statements and typed results (uuid, json/jsonb with symbolized keys)
- `PGI::Dataset` — super lightweight repository toolkit: CRUD, scoped queries
  and keyset pagination with a scalar id cursor
- `PGI::SchemaMigrator` — plain up/down SQL migrations tracked in a
  `schema_migrations` table
