# The schema every dataset test runs against. Each of those tests opens with
# `migrate!(0); migrate!`, so the shape lives here rather than in a DROP/CREATE
# pair per file: two files used to create `pets` themselves, with different
# columns, and whichever ran last was the shape a third file would have
# inherited (#39). Rows stay with the test that needs them - only the shape is
# shared. `dataset` seeds joe (id 1) because nearly every test reads him.
PGI::SchemaMigrator.version(1) do |migrator|
  migrator.up do
    <<~SQL
      CREATE TABLE dataset (
        id SERIAL,
        name VARCHAR(256),
        age INTEGER
      );
      INSERT INTO dataset (name, age) VALUES ('joe', 25);
      CREATE TABLE tags (
        id SERIAL,
        name VARCHAR(256)
      );
      CREATE TABLE pets (
        id SERIAL,
        dataset_id INTEGER,
        tag_id INTEGER,
        name VARCHAR(256)
      )
    SQL
  end

  migrator.down do
    <<~SQL
      DROP TABLE IF EXISTS pets;
      DROP TABLE IF EXISTS tags;
      DROP TABLE IF EXISTS dataset;
    SQL
  end
end
