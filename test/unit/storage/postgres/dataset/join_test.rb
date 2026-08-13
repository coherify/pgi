require "test/helper"
require "pgi/dataset"

describe "PGI::Dataset joins" do
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
    PG_CONN.exec("DROP TABLE IF EXISTS pets")
    PG_CONN.exec("DROP TABLE IF EXISTS tags")
    PG_CONN.exec("CREATE TABLE tags (id SERIAL, name VARCHAR(256))")
    PG_CONN.exec("CREATE TABLE pets (id SERIAL, dataset_id INTEGER, tag_id INTEGER, name VARCHAR(256))")
    # joe (id 1) comes from the fixture migration; one pet per owner so keyset
    # over the joined sort column is well-defined (FK -> PK cardinality). Each
    # pet carries a tag, so pets -> tags is the second hop off the first join.
    PG_CONN.exec("INSERT INTO dataset (name, age) VALUES ('ann', 30), ('carl', 35)")
    PG_CONN.exec("INSERT INTO tags (name) VALUES ('feline'), ('canine')")
    PG_CONN.exec("INSERT INTO pets (dataset_id, tag_id, name) VALUES (1, 2, 'rex'), (2, 1, 'abe'), (3, 2, 'cat')")
  end

  describe "#join" do
    it "builds an INNER JOIN with a qualified select star" do
      repo.join(:pets, on: { id: :dataset_id }).tap do |query|
        _(query.sql).must_match(/SELECT "dataset"\.\* FROM dataset INNER JOIN "pets" ON "dataset"\."id" = "pets"\."dataset_id"/)
      end
    end

    it "keeps a custom select list intact" do
      repo.select(:name).join(:pets, on: { id: :dataset_id }).tap do |query|
        _(query.sql).must_match(/SELECT "dataset"\."name" FROM dataset INNER JOIN "pets"/)
      end
    end

    it "rejects invalid table names" do
      _(-> { repo.join(:"pets; DROP TABLE dataset", on: { id: :dataset_id }) }).must_raise RuntimeError
    end

    it "rejects a missing or empty on-mapping" do
      _(-> { repo.join(:pets, on: {}) }).must_raise RuntimeError
      _(-> { repo.join(:pets, on: nil) }).must_raise RuntimeError
    end
  end

  describe "#join with a second hop" do
    it "qualifies an on-key with a previously joined table" do
      repo
        .join(:pets, on: { id: :dataset_id })
        .join(:tags, on: { { pets: :tag_id } => :id })
        .tap do |query|
          _(query.sql).must_match(
            /INNER JOIN "pets" ON "dataset"\."id" = "pets"\."dataset_id" INNER JOIN "tags" ON "pets"\."tag_id" = "tags"\."id"/
          )
        end
    end

    it "filters base rows across the two-hop chain" do
      rows = repo
             .join(:pets, on: { id: :dataset_id })
             .join(:tags, on: { { pets: :tag_id } => :id })
             .where(tags: { name: "feline" })
             .to_a

      # only ann's pet (abe) is tagged feline
      _(rows.map { |r| r["name"] }).must_equal %w[ann]
      _(rows.first.keys.sort).must_equal %w[age id name]
    end

    it "rejects an on-key qualified with a table not yet joined" do
      _(-> { repo.join(:tags, on: { { pets: :tag_id } => :id }) }).must_raise RuntimeError
    end
  end

  describe "#where with qualified columns" do
    it "filters base rows by joined-table columns without leaking their columns" do
      rows = repo.join(:pets, on: { id: :dataset_id }).where(pets: { name: "rex" }).to_a

      _(rows.size).must_equal 1
      _(rows.first["name"]).must_equal "joe"
      _(rows.first.keys.sort).must_equal %w[age id name]
    end

    it "qualifies nested keys for the base table too" do
      repo.join(:pets, on: { id: :dataset_id }).where(dataset: { name: "joe" }).tap do |query|
        _(query.sql).must_match(/"dataset"\."name" = \$1/)
      end
    end

    it "rejects nested keys that are not the base or a joined table" do
      _(-> { repo.join(:pets, on: { id: :dataset_id }).where(cats: { name: "x" }) }).must_raise RuntimeError
      _(-> { repo.where(pets: { name: "x" }) }).must_raise RuntimeError
    end
  end

  describe "#order with qualified columns" do
    it "orders by a joined column" do
      repo.join(:pets, on: { id: :dataset_id }).order({ pets: :name }, :desc).tap do |query|
        _(query.sql).must_match(/ORDER BY "pets"\."name" DESC/)
      end
    end

    it "rejects multi-pair qualified columns" do
      _(-> { repo.join(:pets, on: { id: :dataset_id }).order({ pets: :name, dataset: :age }) }).must_raise RuntimeError
    end
  end

  describe "Dataset#page with joins" do
    let(:joins) { { pets: { id: :dataset_id } } }

    it "pages in joined-column order with a working cursor" do
      # pets sorted asc: abe(ann), cat(carl), rex(joe)
      page1 = repo.page(nil, 2, { pets: :name }, :asc, joins: joins)
      _(page1.map { |r| r["name"] }).must_equal %w[ann carl]

      page2 = repo.page(page1.last["id"], 2, { pets: :name }, :asc, joins: joins)
      _(page2.map { |r| r["name"] }).must_equal %w[joe]
    end

    it "pages descending" do
      page1 = repo.page(nil, 2, { pets: :name }, :desc, joins: joins)
      _(page1.map { |r| r["name"] }).must_equal %w[joe carl]
    end

    it "combines joins with qualified where filters" do
      rows = repo.page(nil, 10, :id, :asc, { pets: { name: "rex" } }, joins: joins)
      _(rows.map { |r| r["name"] }).must_equal %w[joe]
    end
  end

  describe "#search" do
    it "starts a query that matches rows by substring" do
      rows = repo.search([:name], ["ar"]).to_a
      _(rows.map { |r| r["name"] }).must_equal %w[carl]
    end

    it "AND's tokens - all must hit somewhere" do
      _(repo.search([:name], %w[car l]).to_a.map { |r| r["name"] }).must_equal %w[carl]
      _(repo.search([:name], %w[car z]).to_a).must_equal []
    end
  end

  describe "Dataset#page with search" do
    it "filters the page by a base-column substring, keyset-compatible" do
      rows = repo.page(nil, 10, :id, :asc, search: { columns: [:name], terms: ["a"] })
      _(rows.map { |r| r["name"] }).must_equal %w[ann carl] # joe has no 'a', id asc
    end

    it "searches across a joined column" do
      rows = repo.page(nil, 10, :id, :asc, joins: { pets: { id: :dataset_id } }, search: { columns: [{ pets: :name }], terms: ["re"] })
      _(rows.map { |r| r["name"] }).must_equal %w[joe] # only rex matches
      _(rows.first.keys.sort).must_equal %w[age id name]
    end
  end

  describe "#count with joins" do
    it "counts the joined result set" do
      count = repo.join(:pets, on: { id: :dataset_id }).where(pets: { name: "rex" }).count
      _(count).must_equal 1
    end
  end
end
