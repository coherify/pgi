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
* `#page(cursor, size, sort_by, sort_dir)` - keyset pagination; pass `nil` for the first page, then the last returned row as the cursor for each subsequent page

```ruby
class Repository
  extend PGI::Dataset[DB, :members, cursor: nil, scope: "deleted_at IS NULL"]
end

# First page — sorted by name
page1 = Repository.page(nil, 20, :name, :asc)

# Next page — pass the last row from the previous page as the cursor
page2 = Repository.page(page1.last, 20, :name, :asc)

# Generated SQL (page 2):
# SELECT * FROM members
# WHERE deleted_at IS NULL
#   AND (name, id) > ($1, $2)
# ORDER BY name ASC, id ASC
# LIMIT 20
```

### Pagination and indexes

`#page` uses a composite keyset cursor — `WHERE (sort_by, id) > ($last_sort_val, $last_id)` — which allows Postgres to seek directly to the right position in a B-tree index rather than scanning and discarding rows as `LIMIT/OFFSET` does. This gives constant-time page fetches regardless of depth.

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
