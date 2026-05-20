require "test/helper"
require "pgi/dataset/query"

describe PGI::Dataset::Query do
  include PGI::Test::Methods

  let(:pg_conn) { postgres_connection }
  let(:migrator) { postgres_migrator(pg_conn) }

  def query
    PGI::Dataset::Query.new(pg_conn, :dataset, nil, cursor: nil)
  end

  before do
    migrator.migrate!(0)
    migrator.migrate!
  end

  describe "#new" do
    it "returns the Query instance" do
      _(query.is_a?(PGI::Dataset::Query)).must_equal true
    end

    it "converts legacy array cursor format to hash" do
      q = PGI::Dataset::Query.new(pg_conn, :dataset, nil, cursor: [:id, 0, :asc])
      _(q.sql).must_match(/"dataset"\."id" > \$1/)
      _(q.params).must_equal [0]
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

    it "raises error on invalid datatype for WHERE clause" do
      e = assert_raises RuntimeError do
        query.where(["hest = 'fest'"])
      end
      _(e.message).must_equal "WHERE clause can either be a Hash or a String"
    end

    it "raises error on values instead of placeholders" do
      e = assert_raises RuntimeError do
        query.where("name = 'joe'")
      end
      _(e.message).must_equal "Use placeholders in WHERE clause"
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

  describe "#cursor" do
    it "generates a single-column cursor for :id" do
      query.cursor(:id, 0).tap do |q|
        _(q.sql).must_match(/"dataset"\."id" > \$1/)
        _(q.sql).must_match(/ORDER BY "dataset"\."id" ASC/)
        _(q.params).must_equal [0]
      end
    end

    it "generates a composite cursor for non-id sort columns" do
      query.cursor(:age, 21, 3).tap do |q|
        _(q.sql).must_match(/\("dataset"\."age", "dataset"\."id"\) > \(\$1, \$2\)/)
        _(q.sql).must_match(/ORDER BY "dataset"\."age" ASC, "dataset"\."id" ASC/)
        _(q.params).must_equal [21, 3]
      end
    end

    it "generates a composite cursor in descending direction" do
      query.cursor(:age, 21, 3, :desc).tap do |q|
        _(q.sql).must_match(/\("dataset"\."age", "dataset"\."id"\) < \(\$1, \$2\)/)
        _(q.sql).must_match(/ORDER BY "dataset"\."age" DESC, "dataset"\."id" DESC/)
        _(q.params).must_equal [21, 3]
      end
    end

    it "combines composite cursor with a WHERE clause" do
      query.where(name: "joe").cursor(:age, 21, 3).tap do |q|
        _(q.sql).must_match(/"dataset"\."name" = \$1/)
        _(q.sql).must_match(/\("dataset"\."age", "dataset"\."id"\) > \(\$2, \$3\)/)
        _(q.params).must_equal ["joe", 21, 3]
      end
    end

    it "raises error on missing cursor value" do
      e = assert_raises RuntimeError do
        query.cursor(:id)
      end
      _(e.message).must_equal "cursor value cannot be nil"
    end
  end

  describe "#cursor_subquery" do
    it "generates a composite subquery cursor ascending" do
      query.cursor_subquery(:age, 3).tap do |q|
        _(q.sql).must_match(/\("dataset"\."age", "dataset"\."id"\) > \(SELECT "dataset"\."age", "dataset"\."id" FROM dataset WHERE "dataset"\."id" = \$1\)/)
        _(q.sql).must_match(/ORDER BY "dataset"\."age" ASC, "dataset"\."id" ASC/)
        _(q.params).must_equal [3]
      end
    end

    it "generates a composite subquery cursor descending" do
      query.cursor_subquery(:age, 3, :desc).tap do |q|
        _(q.sql).must_match(/\("dataset"\."age", "dataset"\."id"\) < \(SELECT.*\$1\)/)
        _(q.sql).must_match(/ORDER BY "dataset"\."age" DESC, "dataset"\."id" DESC/)
        _(q.params).must_equal [3]
      end
    end

    it "combines composite subquery cursor with a WHERE clause" do
      query.where(name: "joe").cursor_subquery(:age, 3).tap do |q|
        _(q.sql).must_match(/\("dataset"\."age", "dataset"\."id"\) > \(SELECT.*\$2\)/)
        _(q.sql).must_match(/"dataset"\."name" = \$1/)
        _(q.params).must_equal ["joe", 3]
      end
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
  end

  describe "#to_s" do
    it "shows SQL and params on #to_s" do
      obj_str = query.where(name: "joe").cursor(nil).to_s

      _(obj_str).must_match(/@sql=SELECT \* FROM dataset WHERE "dataset"\."name" = \$1/)
      _(obj_str).must_match(/@params=\["joe"\]/)
    end
  end
end
