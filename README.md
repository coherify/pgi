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
  options.pg_database = "pgi_test"
  options.pg_host = "localhost"
  options.pg_user = "pgi"
  options.pg_password = "password"
  options.logger = LOG_CATCHER
end

DB.exec_stmt("my_stmt", "SELECT 1+1")
```

## PGI::Dataset

The `PGI::Dataset` is a super light weight ActiveRecord::Relation replacement. It delivers a clean and simple querying interface:

* `#select(column1, ...)` allows you to limit the result set to only contain specified columns
* `#where(...)` - can be invoked in two ways:
  * `#where("name = $1", ['joe'])` - the classic ruby PG named paremeters
  * `#where(name: 'joe')` - as a Hash (multiple conditions will be concatenated with an ' AND ')
* `#order(:column, <:asc|:desc>)` - sort result set by column and direction, can be invoked multiple times
* `#limit(<num>)` - limits the result set to the specified number of records
* `#cursor(sort_col, sort_val, id_val=nil, direction=:asc)` - low-level keyset cursor; prefer `#page` for pagination
* `#first` - get the first record in a set
* `#all`- get an array of records
* `#count`- get the number of rows in a table
* `#page(cursor, size, sort_by, sort_dir)` - keyset pagination; pass `nil` for the first page, then the **id of the last row** as the cursor for each subsequent page

```ruby
class Repository
  extend PGI::Dataset[DB, :members, cursor: nil, scope: "deleted_at IS NULL"]
end

# First page — sorted by name
page1 = Repository.page(nil, 20, :name, :asc)

# Next page — pass the id of the last row as the cursor (scalar, not the row itself)
page2 = Repository.page(page1.last["id"], 20, :name, :asc)

# Generated SQL (page 2, sort_by != :id):
# SELECT * FROM members
# WHERE deleted_at IS NULL
#   AND (name, id) > (SELECT name, id FROM members WHERE id = $1)
# ORDER BY name ASC, id ASC
# LIMIT 20

# Generated SQL (page 2, sort_by == :id):
# SELECT * FROM members
# WHERE deleted_at IS NULL
#   AND id > $1
# ORDER BY id ASC
# LIMIT 20
```

### Pagination and indexes

`#page` uses keyset pagination — constant-time page fetches at any depth. The cursor is always a scalar `id` value:

- **Sorting by id**: generates `WHERE id > $cursor ORDER BY id` — simple and direct.
- **Sorting by another column**: generates a composite subquery cursor:
  `WHERE (sort_col, id) > (SELECT sort_col, id FROM table WHERE id = $cursor)`
  Postgres resolves the subquery via a primary-key index seek and then uses the composite index to skip directly to the right position.

`LIMIT/OFFSET` scans and discards all prior rows on every page request — cost grows linearly with depth. Keyset pagination does not.

**This only holds if a matching composite index exists.** Without one, Postgres falls back to a sequential scan and the performance advantage is lost.

Create an index for each column you intend to sort by:

```sql
CREATE INDEX ON members (name ASC, id ASC);
CREATE INDEX ON members (age  ASC, id ASC);
```

Sorting by a column with no backing index will produce correct results but will scan the full table on every page request.

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
