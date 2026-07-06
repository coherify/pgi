# CHANGELOG

## 1.0.0 (2026-07-06)

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
