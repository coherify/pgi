require "test/helper"
require "pgi/db"

describe PGI::Connection do
  include PGI::Test::Methods

  describe "server notices" do
    it "routes them to the configured logger, not stderr" do
      io = StringIO.new
      conn = PGI::Connection.new(
        conn_uri: ENV.fetch("PG_CONN_URI", "postgresql://pgi:password@localhost:5434/pgi_test"),
        logger: Logger.new(io, level: Logger::DEBUG)
      )
      err = capture_subprocess_io { conn.exec("DO $$ BEGIN RAISE NOTICE 'hello-notice'; END $$") }.last
      _(io.string).must_include "hello-notice"
      _(err).wont_include "hello-notice"
    end
  end
end
