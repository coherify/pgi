require "test/helper"
require "pgi/db"

describe PGI::DB do
  include PGI::Test::Methods

  subject { postgres_connection }

  describe "PG::BasicTypeRegistry" do
    it "symbolizes keys on JSON decode" do
      subject.with do |conn|
        _(conn.exec(%q(SELECT '{"key":"val"}'::jsonb)).to_a.first["jsonb"][:key]).must_equal "val"
      end
    end
  end

  describe "#with" do
    it "yields a PGI::Connection" do
      subject.with do |conn|
        _(conn.is_a?(PGI::Connection)).must_equal true
      end
    end

    it "auto-heals bad connections" do
      log = LOG_CATCHER.run do
        c = postgres_connection # don't bite the hand that feeds you
        subject.with do |conn|
          c.exec(<<~SQL)
            SELECT pg_terminate_backend(#{conn.backend_pid})
            FROM pg_stat_activity
            WHERE pid='#{conn.backend_pid}'
          SQL
        end

        res = subject.with do |conn|
          conn.exec("SELECT 1+1 AS sum").to_a
        end

        _(res.first["sum"]).must_equal 2
      end

      _(log).must_match(/PG::ConnectionBad|PG::UnableToSend/)
    end

    it "stops retrying bad connections" do
      log = LOG_CATCHER.run do
        c = postgres_connection # don't bite the hand that feeds you
        subject.with do |conn|
          c.exec(<<~SQL)
            SELECT pg_terminate_backend(#{conn.backend_pid})
            FROM pg_stat_activity
            WHERE pid='#{conn.backend_pid}'
          SQL
        end

        subject.instance_variable_set(:@_retries, 10)

        assert_raises PG::ConnectionBad do
          subject.with do |conn|
            conn.exec("SELECT 1+1 AS sum").to_a
          end
        end
      end

      _(log).must_match(/DB connection was lost - unable to reconnect/)
    end

    it "handles and retries on connection pool timeout" do
      log = LOG_CATCHER.run do
        Thread.new { subject.with { |_| sleep 1 } }
        Thread.new do
          sleep 0.5
          res = subject.with do |conn|
            conn.exec("SELECT 1+1 AS sum")
          end
          _(res.first["sum"]).must_equal 2
        end.join
      end
      _(log).must_match "Timeout in checking out DB connection from pool"
    end
  end

  describe "#exec_stmt" do
    it "auto-creates prepared statements with #exec_stmt" do
      log = LOG_CATCHER.run do
        _(subject.exec_stmt("stmt_name", "SELECT 1+1 AS sum").first).must_equal("sum" => 2)
      end
      _(log).must_match "stmt_name"
    end

    it "falls back to #exec_params on #exec_stmt in transaction" do
      log = LOG_CATCHER.run do
        subject.transaction do
          _(subject.exec_stmt("stmt_name", "SELECT 1+1 AS sum").first).must_equal("sum" => 2)
        end
      end
      _(log).must_match "Unable to use statements within a transaction - falling back to #exec_params"
    end
  end

  it "raises error on bad syntax" do
    log = LOG_CATCHER.run do
      assert_raises PG::SyntaxError do
        subject.exec_stmt("stmt_name", "select from 1")
      end
    end
    _(log).must_match "syntax error at or near"
  end

  it "relays missing methods to PG connection" do
    _(subject.host).must_equal "postgres"
  end
end
