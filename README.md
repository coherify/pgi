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
