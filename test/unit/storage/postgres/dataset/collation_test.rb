require "test/helper"
require "pgi/dataset"

describe "PGI::Dataset collation" do
  include PGI::Test::Methods

  let(:pg_conn) { postgres_connection }
  let(:migrator) { postgres_migrator(pg_conn) }
  let(:repo) do
    Class.new do
      extend PGI::Dataset[PG_CONN, :dataset]
    end
  end

  before do
    migrator.migrate!(0)
    migrator.migrate!
    # joe (id 1) comes from the fixture migration. Danish alphabet ends
    # ...z, æ, ø, å - the exact order a bytewise or en_US sort gets wrong.
    PG_CONN.exec("INSERT INTO dataset (name, age) VALUES ('æble', 1), ('åre', 2), ('zebra', 3), ('øre', 4)")
  end

  describe "#order with collate" do
    it "applies the collation to the ORDER BY" do
      repo.where.order(:name, :asc, collate: "da-x-icu").tap do |query|
        _(query.sql).must_match(/ORDER BY "dataset"\."name" COLLATE "da-x-icu" ASC/)
      end
    end

    it "rejects invalid collation names" do
      _(-> { repo.where.order(:name, :asc, collate: %(da"; DROP TABLE dataset;--)) }).must_raise RuntimeError
    end
  end

  describe "Dataset#page with collate" do
    it "pages in Danish order across a cursor" do
      page1 = repo.page(nil, 3, :name, :asc, collate: "da-x-icu")
      _(page1.map { |r| r["name"] }).must_equal %w[joe zebra æble]

      page2 = repo.page(page1.last["id"], 3, :name, :asc, collate: "da-x-icu")
      _(page2.map { |r| r["name"] }).must_equal %w[øre åre]
    end

    it "pages descending with the same collation" do
      page1 = repo.page(nil, 2, :name, :desc, collate: "da-x-icu")
      _(page1.map { |r| r["name"] }).must_equal %w[åre øre]

      page2 = repo.page(page1.last["id"], 2, :name, :desc, collate: "da-x-icu")
      _(page2.map { |r| r["name"] }).must_equal %w[æble zebra]
    end

    it "leaves :id sorts untouched by collate" do
      rows = repo.page(nil, 2, :id, :asc, collate: "da-x-icu")
      _(rows.map { |r| r["id"] }).must_equal [1, 2]
    end
  end
end
