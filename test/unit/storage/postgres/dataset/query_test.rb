require "test/helper"
require "pgi/dataset/query"

describe PGI::Dataset::Query do
  include PGI::Test::Methods

  let(:pg_conn) { postgres_connection }
  let(:migrator) { postgres_migrator(pg_conn) }

  def query
    PGI::Dataset::Query.new(pg_conn, :dataset, nil)
  end

  before do
    migrator.migrate!(0)
    migrator.migrate!
  end

  describe "#new" do
    it "returns the Query instance" do
      _(query.is_a?(PGI::Dataset::Query)).must_equal true
    end
  end

  describe "#where" do
    it "sets a WHERE clause from a Hash" do
      query.where(name: "joe").tap do |obj|
        _(obj.sql).must_match(/WHERE "dataset"\."name" = \$1/)
        _(obj.params).must_equal ["joe"]
      end
    end

    it "concatenates multiple expressions in a Hash with an AND" do
      query.where(name: "joe", age: 25).tap do |obj|
        _(obj.sql).must_match(/WHERE "dataset"\."name" = \$1 AND "dataset"\."age" = \$2/)
        _(obj.params).must_equal ["joe", 25]
      end
    end

    it "handles placesholders in WHERE clause from a String" do
      params = ["joe", 25]
      query.where("name = ? AND age = ?", params).tap do |obj|
        _(obj.sql).must_match(/WHERE name = \$1 AND age = \$2/)
        _(obj.params).must_equal params
      end

      query.where("name = $1 AND age = $2", params).tap do |obj|
        _(obj.sql).must_match(/WHERE name = \$1 AND age = \$2/)
        _(obj.params).must_equal params
      end
    end

    it "raises when a WHERE clause is already set" do
      e = assert_raises(RuntimeError) { query.where(name: "joe").where("age > ?", [25]) }
      _(e.message).must_equal "WHERE clause already set - combine conditions in a single call"
    end

    it "raises error on invalid datatype for WHERE clause" do
      e = assert_raises RuntimeError do
        query.where(["hest = 'fest'"])
      end
      _(e.message).must_equal "WHERE clause can either be a Hash or a String"
    end

    it "raises error on values instead of placeholders" do
      ["name = 'joe'", "age = 42", "age >= 42", "age > -1", "name != 'x'"].each do |clause|
        e = assert_raises RuntimeError do
          query.where(clause)
        end
        _(e.message).must_equal "Use placeholders in WHERE clause"
      end
    end

    it "allows identifiers, keywords, subqueries and ANY in WHERE strings (issue #19)" do
      [
        "a.id = b.a_id",
        "accepted = true",
        "deleted_at IS NULL AND team_id = ANY($1::uuid[])",
        "account_id IN (SELECT account_id FROM memberships WHERE user_id = $1 AND accepted = true)"
      ].each do |clause|
        query.where(clause, [1]).tap do |q|
          _(q.sql).must_match(/WHERE/)
        end
      end
    end
  end

  describe "#search" do
    it "builds an OR-group of ILIKE matches binding one param per term" do
      query.search(%i[name age], ["joe"]).tap do |q|
        _(q.sql).must_match(/WHERE \("dataset"\."name" ILIKE \$1 OR "dataset"\."age" ILIKE \$1\)/)
        _(q.params).must_equal ["%joe%"]
      end
    end

    it "AND's an OR-group per term, each binding its own param" do
      query.search([:name], %w[joe smith]).tap do |q|
        _(q.sql).must_match(/WHERE \("dataset"\."name" ILIKE \$1\) AND \("dataset"\."name" ILIKE \$2\)/)
        _(q.params).must_equal ["%joe%", "%smith%"]
      end
    end

    it "escapes LIKE metacharacters so they match literally" do
      query.search([:name], ["50%_off\\"]).tap do |q|
        _(q.params).must_equal ["%50\\%\\_off\\\\%"]
      end
    end

    it "accepts a { table => column } qualified column" do
      query.search([{ dataset: :name }], ["joe"]).tap do |q|
        _(q.sql).must_match(/"dataset"\."name" ILIKE \$1/)
      end
    end

    it "is a no-op for empty columns, empty terms or blank-only terms" do
      _(query.search([], ["joe"]).sql).wont_match(/ILIKE/)
      _(query.search([:name], []).sql).wont_match(/ILIKE/)
      query.search([:name], ["", "  "]).tap do |q|
        _(q.sql).wont_match(/ILIKE/)
        _(q.params).must_equal []
      end
    end

    it "AND's the search into an existing WHERE clause" do
      query.where(age: 25).search([:name], ["joe"]).tap do |q|
        _(q.sql).must_match(/WHERE \("dataset"\."name" ILIKE \$2\) AND \("dataset"\."age" = \$1\)/)
        _(q.params).must_equal [25, "%joe%"]
      end
    end

    it "combines with a keyset cursor predicate" do
      query.search([:name], ["joe"]).keyset(:id, 5, :asc).tap do |q|
        _(q.sql).must_match(/WHERE "dataset"\."id" > \$2 AND \(\("dataset"\."name" ILIKE \$1\)\)/)
        _(q.params).must_equal ["%joe%", 5]
      end
    end
  end

  describe "#limit" do
    it "sets a limit clause" do
      _(query.limit(3).sql).must_match(/LIMIT 3/)
    end
  end

  describe "#order" do
    it "sets an order by clause" do
      _(query.order(:age, :asc).sql).must_match(/ORDER BY "dataset"\."age" ASC/)
    end

    it "sets an order by clause with multiple expressions" do
      _(query.order(:age).order(:name, :desc).sql).must_match(/ORDER BY "dataset"\."age" ASC, "dataset"\."name" DESC/)
    end
  end

  describe "#keyset" do
    it "orders without a predicate for a nil cursor (first page)" do
      query.keyset(:age, nil, :asc).tap do |q|
        _(q.sql).wont_match(/WHERE/)
        _(q.sql).must_match(/ORDER BY "dataset"\."age" ASC, "dataset"\."id" ASC/)
        _(q.params).must_equal []
      end
    end

    it "generates a scalar predicate for :id" do
      query.keyset(:id, 0, :asc).tap do |q|
        _(q.sql).must_match(/WHERE "dataset"\."id" > \$1/)
        _(q.sql).must_match(/ORDER BY "dataset"\."id" ASC/)
        _(q.params).must_equal [0]
      end
    end

    it "generates a scalar predicate for :id descending" do
      query.keyset(:id, 5, :desc).tap do |q|
        _(q.sql).must_match(/WHERE "dataset"\."id" < \$1/)
        _(q.sql).must_match(/ORDER BY "dataset"\."id" DESC/)
        _(q.params).must_equal [5]
      end
    end

    it "generates a composite subquery predicate for non-id columns" do
      query.keyset(:age, 3, :asc).tap do |q|
        _(q.sql).must_match(/WHERE \("dataset"\."age", "dataset"\."id"\) > \(SELECT "dataset"\."age", "dataset"\."id" FROM dataset WHERE "dataset"\."id" = \$1\)/)
        _(q.sql).must_match(/ORDER BY "dataset"\."age" ASC, "dataset"\."id" ASC/)
        _(q.params).must_equal [3]
      end
    end

    it "generates a composite subquery predicate for non-id columns descending" do
      query.keyset(:age, 3, :desc).tap do |q|
        _(q.sql).must_match(/WHERE \("dataset"\."age", "dataset"\."id"\) < \(SELECT.*\$1\)/)
        _(q.sql).must_match(/ORDER BY "dataset"\."age" DESC, "dataset"\."id" DESC/)
        _(q.params).must_equal [3]
      end
    end

    it "combines the cursor predicate with an existing WHERE clause" do
      query.where(name: "joe").keyset(:age, 3, :asc).tap do |q|
        _(q.sql).must_match(/\("dataset"\."age", "dataset"\."id"\) > \(SELECT.*\$2\)/)
        _(q.sql).must_match(/"dataset"\."name" = \$1/)
        _(q.params).must_equal ["joe", 3]
      end
    end

    it "raises on invalid direction" do
      e = assert_raises(RuntimeError) { query.keyset(:id, 0, :sideways) }
      _(e.message).must_equal "Invalid ORDER BY direction: :sideways"
    end
  end

  describe "#first" do
    it "returns a Hash with row data" do
      _(query.where.first).must_equal("id" => 1, "name" => "joe", "age" => 25)
    end
  end

  describe "#to_a" do
    it "returns an Array of records as Hashes" do
      _(query.where.to_a).must_equal([{ "id" => 1, "name" => "joe", "age" => 25 }])
    end
  end

  describe "#each" do
    it "returns an Enumerator" do
      _(query.where.each.class).must_equal Enumerator
    end
  end

  describe "#explain" do
    it "returns a String with query planner explanation" do
      _(query.where(name: "jill", age: 25).explain).must_match(/^Limit/)
    end
  end

  describe "#count" do
    it "returns the number of rows" do
      _(query.count).must_equal 1
      _(query.where(name: "jill").count).must_equal 0
    end

    it "ignores a previously set ORDER BY" do
      _(query.order(:age).count).must_equal 1
    end
  end

  describe "#to_s" do
    it "shows SQL and params on #to_s" do
      obj_str = query.where(name: "joe").to_s

      _(obj_str).must_match(/@sql=SELECT \* FROM dataset WHERE "dataset"\."name" = \$1/)
      _(obj_str).must_match(/@params=\["joe"\]/)
    end
  end
end
