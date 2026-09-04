require "test/helper"
require "pgi/db"

describe PGI::Connection do
  include PGI::Test::Methods

  describe "arguments" do
    it "refuses to build without conn or conn_uri, instead of falling back to libpq's defaults" do
      err = _ { PGI::Connection.new(logger: LOG_CATCHER) }.must_raise ArgumentError
      _(err.message).must_equal "conn or conn_uri required"
    end
  end

  describe "server notices" do
    it "routes them to the configured logger, not stderr" do
      io = StringIO.new
      conn = PGI::Connection.new(
        conn_uri: PG_CONN_URI,
        logger: Logger.new(io, level: Logger::DEBUG)
      )
      err = capture_subprocess_io { conn.exec("DO $$ BEGIN RAISE NOTICE 'hello-notice'; END $$") }.last
      _(io.string).must_include "hello-notice"
      _(err).wont_include "hello-notice"
    ensure
      conn&.close
    end

    it "preserves severity: a RAISE WARNING survives an INFO logger, a NOTICE stays quiet" do
      io = StringIO.new
      conn = PGI::Connection.new(
        conn_uri: PG_CONN_URI,
        logger: Logger.new(io, level: Logger::INFO)
      )
      conn.exec("DO $$ BEGIN RAISE NOTICE 'quiet-notice'; RAISE WARNING 'loud-warning'; END $$")
      _(io.string).must_include "loud-warning"
      _(io.string).wont_include "quiet-notice"
    ensure
      conn&.close
    end

    it "covers the conn: door, not just conn_uri:" do
      io = StringIO.new
      raw = PG::Connection.new(PG_CONN_URI)
      conn = PGI::Connection.new(conn: raw, logger: Logger.new(io, level: Logger::DEBUG))
      err = capture_subprocess_io { conn.exec("DO $$ BEGIN RAISE NOTICE 'door-two-notice'; END $$") }.last
      _(io.string).must_include "door-two-notice"
      _(err).wont_include "door-two-notice"
    ensure
      raw&.close
    end
  end
end
