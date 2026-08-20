require "test/helper"
require "pgi/dataset"

# Dataset projections: - declared computed columns that ride every read AND
# every write's RETURNING, so the row shape is invariant. Names pass the
# column sanitizer; expressions are trusted raw SQL authored at extension
# time (the :scope trust model, projection-side).
describe "PGI::Dataset projections" do
  include PGI::Test::Methods

  let(:pg_conn) { postgres_connection }
  let(:migrator) { postgres_migrator(pg_conn) }
  let(:repo) do
    Class.new do
      extend PGI::Dataset[PG_CONN, :dataset,
                          projections: { answer: "SELECT 40 + 2", name_upper: "SELECT UPPER(dataset.name)" }]
    end
  end

  before do
    migrator.migrate!(0)
    migrator.migrate!
  end

  it "rides every SELECT, additively" do
    _(repo.where(age: 1).sql).must_match(/SELECT \*, \(SELECT 40 \+ 2\) AS "answer", .+ FROM dataset/)
    # Explicit column selection stays additive - projections are dataset facts
    _(repo.select(:id).sql).must_match(/"dataset"\."id", \(SELECT 40 \+ 2\) AS "answer"/)
  end

  it "returns computed values on reads, correlated to the row" do
    row = repo.insert!(name: "jane", age: 1)
    found = repo.find(row["id"])
    _(found["answer"]).must_equal 42
    _(found["name_upper"]).must_equal "JANE"
  end

  it "keeps the row shape invariant across writes (RETURNING carries them)" do
    row = repo.insert!(name: "bo", age: 2)
    _(row["answer"]).must_equal 42
    _(row["name_upper"]).must_equal "BO"

    updated = repo.update!(row["id"], name: "carla")
    _(updated["name_upper"]).must_equal "CARLA"
  end

  it "stays out of COUNT (an aggregate has no row to enrich)" do
    repo.insert!(name: "x", age: 3)
    _(repo.count).must_equal repo.all.size
  end

  it "rejects invalid declarations at extension time" do
    _ { PGI::Dataset[PG_CONN, :dataset, projections: { "bad name" => "SELECT 1" }] }.must_raise RuntimeError
    _ { PGI::Dataset[PG_CONN, :dataset, projections: { ok: "  " }] }.must_raise RuntimeError
  end
end
