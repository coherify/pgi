# CHANGELOG

## Unreleased

- **`Connection.new` requires a connection** — building one with neither
  `conn:` nor `conn_uri:` now raises `ArgumentError` instead of connecting to
  whatever libpq's environment defaults point at. Pass `conn_uri: ""` to ask
  for those defaults on purpose.

- **A colliding projection name raises** (behaviour change) — a `projections:`
  entry named after a base column landed as a second result field and silently
  overwrote the base value; the read now raises, as an unaliased joined column
  from `#select` already did.

- **Dependency updates**
  - connection_pool: the dependency widens from `~> 2.4` to `>= 2.4, < 4`.

## 1.1.0 (2026-08-28)

The query release: joins, search, projected columns — and server notices that
respect your logger.

- **Joins** — `#join(table, on:)` / `#page(joins:)` add INNER JOINs for
  filtering and sorting on combined rows; result rows stay the base table's,
  so model mapping is unchanged.

  ```ruby
  Repository.join(:memberships, on: { id: :member_id })
            .where(memberships: { accepted: true }).all
  ```

  `#where` and `#order` take qualified columns (`{ users: :name }`), keyset
  pagination works over a joined sort column (FK -> PK cardinality), and an
  `on:` key may itself be qualified to chain a second hop off an earlier join
  (declare joins in dependency order).

- **Search** — `#search(columns, terms)` / `#page(search:)`: case-insensitive
  substring search. Every term must hit in some column — the behaviour of a
  search box that narrows as words are added.

  ```ruby
  Repository.search([:name, :email], %w[john smith]).all
  ```

  LIKE metacharacters are escaped, columns may be join-qualified, and it only
  adds a predicate, so it composes with keyset pagination.

- **Projecting joined columns** — `#select({ table => column })` appends a
  joined table's column to the result alongside `"base".*` (`#join` alone
  stays filter/sort-only). Alias form `{ table => { column => alias } }`;
  rows come back as raw hashes. A projected column colliding with a base
  column raises when the rows come back — alias to disambiguate.

- **Projections** — a declared catalog of computed columns, opted into per
  read; never evaluated unless asked, so cost stays a visible per-read
  decision.

  ```ruby
  extend PGI::Dataset[DB, :teams,
                      projections: { mates_count: "SELECT COUNT(*) FROM teammates WHERE team_id = teams.id" }]

  TeamRepository.page(nil, 25, project: [:mates_count])
  ```

  Unknown names raise at `#project`; `#count` ignores projections; writes shed
  projected attribute keys so model round-trips just work.

- **Collation** — `#order(:name, :asc, collate: "da-x-icu")` and
  `#page(..., collate:)` sort text in a named (e.g. ICU) collation, so Danish
  `æ ø å` file after `z` regardless of the database default.

- **Server notices route to the configured logger** instead of libpq's stderr,
  on both constructor doors (`conn_uri:` and `conn:`). Severity is preserved:
  `RAISE WARNING` logs at `warn`, everything else at `debug` — a logger at
  INFO stays quiet through chatter but still surfaces warnings.

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
