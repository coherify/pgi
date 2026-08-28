require "test/helper"
require "pgi/dataset"

# Dataset projections: - a declared catalog of computed columns a read may
# opt into (#project / page(project:)). Declared once at the dataset
# boundary (the :scope trust model, projection-side); never evaluated
# unless asked, so cost is a visible per-read decision. Writes shed the
# projected attribute names a model round-trip carries.
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

  it "stays out of unprojected reads - cost is opt-in" do
    row = repo.insert!(name: "jane", age: 1)
    _(repo.where.sql).wont_match(/AS "answer"/)
    _(repo.find(row["id"]).key?("answer")).must_equal false
  end

  it "joins the select list when opted in, additively" do
    _(repo.project(:answer).sql).must_match(/SELECT \*, \(SELECT 40 \+ 2\) AS "answer" FROM dataset/)
    _(repo.project(:answer).sql).wont_match(/name_upper/)
  end

  it "returns computed values on projected reads, correlated to the row" do
    row = repo.insert!(name: "jane", age: 1)
    found = repo.project(:answer, :name_upper).where(id: row["id"]).first
    _(found["answer"]).must_equal 42
    _(found["name_upper"]).must_equal "JANE"
  end

  it "pages with project: for model-mapped projected lists" do
    repo.insert!(name: "bo", age: 2)
    rows = repo.page(nil, 10, :id, :asc, project: [:name_upper])
    bo = rows.find { |r| r["name"] == "bo" } # the fixture seeds its own rows
    _(bo["name_upper"]).must_equal "BO"
    _(bo.key?("answer")).must_equal false
  end

  it "rejects opting into undeclared names" do
    _ { repo.project(:nope) }.must_raise RuntimeError
  end

  it "stays out of COUNT (an aggregate has no row to enrich)" do
    repo.insert!(name: "x", age: 3)
    _(repo.project(:answer).count).must_equal repo.all.size
  end

  it "sheds projection keys from writes - the model round-trip just works" do
    row = repo.insert!(name: "ida", age: 4, answer: 99) # projection key ignored
    _(row.key?("answer")).must_equal false

    updated = repo.update!(row["id"], name: "carla", answer: 7)
    _(updated["name"]).must_equal "carla"
    _(updated.key?("answer")).must_equal false
  end

  it "rejects invalid declarations at extension time" do
    _ { PGI::Dataset[PG_CONN, :dataset, projections: { "bad name" => "SELECT 1" }] }.must_raise RuntimeError
    _ { PGI::Dataset[PG_CONN, :dataset, projections: { ok: "  " }] }.must_raise RuntimeError
  end
end
