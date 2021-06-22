require 'spec_helper'
require 'active_record/connection_adapters/mysql2_adapter'

describe 'MakaraMysql2Adapter' do
  let(:config){
    file = File.expand_path('spec/support/mysql2_database.yml')
    hash = YAML.load(ERB.new(File.read(file)).result)
    hash['test']
  }

  let(:connection) { ActiveRecord::Base.connection }

  before :each do
    ActiveRecord::Base.clear_all_connections!
    change_context
  end

  context "unconnected" do
    it 'should allow a connection to be established' do
      establish_connection(config)
      expect(ActiveRecord::Base.connection).to be_instance_of(ActiveRecord::ConnectionAdapters::MakaraMysql2Adapter)
    end

    it 'should execute a send_to_all against primary even if no replicas are connected' do
      establish_connection(config)
      connection = ActiveRecord::Base.connection

      connection.replica_pool.connections.each do |c|
        allow(c).to receive(:_makara_blocklisted?){ true }
        allow(c).to receive(:_makara_connected?){ false }
        expect(c).to receive(:execute).with('SET @t1 = 1').never
      end

      connection.primary_pool.connections.each do |c|
        expect(c).to receive(:execute).with('SET @t1 = 1')
      end

      expect{
        connection.execute('SET @t1 = 1')
      }.not_to raise_error
    end

    it 'should execute a send_to_all and raise a NoConnectionsAvailable error' do
      establish_connection(config)
      connection = ActiveRecord::Base.connection

      (connection.replica_pool.connections | connection.primary_pool.connections).each do |c|
        allow(c).to receive(:_makara_blocklisted?){ true }
        allow(c).to receive(:_makara_connected?){ false }
        expect(c).to receive(:execute).with('SET @t1 = 1').never
      end

      expect{
        connection.execute('SET @t1 = 1')
      }.to raise_error(Makara::Errors::NoConnectionsAvailable)
    end

    context "unconnect afterwards" do
      after :each do
        ActiveRecord::Base.clear_all_connections!
      end

      it 'should not blow up if a connection fails' do
        wrong_config = config.deep_dup
        wrong_config['makara']['connections'].select{|h| h['role'] == 'replica' }.each{|h| h['username'] = 'other'}

        original_method = ActiveRecord::Base.method(:mysql2_connection)

        allow(ActiveRecord::Base).to receive(:mysql2_connection) do |config|
          if config[:username] == 'other'
            raise "could not connect"
          else
            original_method.call(config)
          end
        end

        establish_connection(wrong_config)
        ActiveRecord::Base.connection

        load(File.dirname(__FILE__) + '/../../support/schema.rb')
        change_context

        allow(ActiveRecord::Base).to receive(:mysql2_connection) do
          original_method.call(config)
        end

        ActiveRecord::Base.connection.replica_pool.connections.each(&:_makara_allowlist!)
        ActiveRecord::Base.connection.replica_pool.provide do |con|
          res = con.execute('SELECT count(*) FROM users')
          if defined?(JRUBY_VERSION)
            expect(res[0]).to eq('count(*)' => 0)
          else
            expect(res.to_a[0][0]).to eq(0)
          end
        end

        ActiveRecord::Base.remove_connection
      end
    end
  end

  context 'with the connection established and schema loaded' do
    before do
      establish_connection(config)
      load(File.dirname(__FILE__) + '/../../support/schema.rb')
      change_context
    end

    it 'should have one primary and two replicas' do
      expect(connection.primary_pool.connection_count).to eq(1)
      expect(connection.replica_pool.connection_count).to eq(2)
    end

    it 'should allow real queries to work' do
      connection.execute("INSERT INTO users (name) VALUES ('John')")

      connection.primary_pool.connections.each do |primary|
        expect(primary).to receive(:execute).never
      end

      change_context

      res = connection.execute('SELECT name FROM users ORDER BY id DESC LIMIT 1')

      if defined?(JRUBY_VERSION)
        expect(res[0]['name']).to eq('John')
      else
        expect(res.to_a[0][0]).to eq('John')
      end
    end

    it 'should send SET operations to each connection' do
      connection.primary_pool.connections.each do |con|
        expect(con).to receive(:execute).with('SET @t1 = 1').once
      end

      connection.replica_pool.connections.each do |con|
        expect(con).to receive(:execute).with('SET @t1 = 1').once
      end
      connection.execute("SET @t1 = 1")
    end

    it 'should send reads to the replica' do
      # ensure the next connection will be the first one
      allow_any_instance_of(Makara::Strategies::RoundRobin).to receive(:single_one?){ true }

      con = connection.replica_pool.connections.first
      expect(con).to receive(:execute).with('SELECT * FROM users').once

      connection.execute('SELECT * FROM users')
    end

    it 'should send exists? to replica' do
      allow_any_instance_of(Makara::Strategies::RoundRobin).to receive(:single_one?){ true }
      Test::User.exists? # flush other (schema) things that need to happen

      con = connection.replica_pool.connections.first
      expect(con).to receive(:exec_query) do |query|
        expect(query).to match(/SELECT\s+1\s*(AS one)?\s+FROM .?users.?\s+LIMIT\s+.?1/)
      end.once.and_call_original

      Test::User.exists?
    end

    it 'should send writes to primary' do
      con = connection.primary_pool.connections.first
      expect(con).to receive(:execute).with('UPDATE users SET name = "bob" WHERE id = 1')
      connection.execute('UPDATE users SET name = "bob" WHERE id = 1')
    end

    it 'should allow reconnecting' do
      connection.object_id
      connection.reconnect!
    end

    it 'should allow reconnecting when one of the nodes is blocklisted' do
      con = connection.replica_pool.connections.first
      allow(con).to receive(:_makara_blocklisted?){ true }
      connection.reconnect!
    end

    if !defined?(JRUBY_VERSION)
      # yml settings only for mysql2
      it 'should blocklist on timeout' do
        expect {
          connection.execute('SELECT SLEEP(2)') # read timeout set to 1
        }.to raise_error(Makara::Errors::AllConnectionsBlocklisted)
      end
    end
  end

  describe 'transaction support' do
    shared_examples 'a transaction supporter' do
      before do
        establish_connection(config)
        load(File.dirname(__FILE__) + '/../../support/schema.rb')
        change_context

        connection.replica_pool.connections.each do |replica|
          # Using method missing to help with back trace, literally
          # no query should be executed on replica once a transaction is opened
          expect(replica).to receive(:method_missing).never
          expect(replica).to receive(:execute).never
        end
      end

      context 'when querying through a polymorphic relation' do
        it 'should respect the transaction' do
          ActiveRecord::Base.transaction do
            connection.execute("INSERT INTO users (name) VALUES ('John')")
            connection.execute('SELECT * FROM users')
          end
        end
      end

      context 'when querying an aggregate' do
        it 'should respect the transaction' do
          ActiveRecord::Base.transaction { connection.execute('SELECT COUNT(*) FROM users') }
        end
      end

      context 'when querying for a specific record' do
        it 'should respect the transaction' do
          ActiveRecord::Base.transaction { connection.execute('SELECT * FROM users WHERE id = 1') }
        end
      end

      context 'when executing a query' do
        it 'should respect the transaction' do
          ActiveRecord::Base.transaction { connection.execute('SELECT 1') }
        end
      end
    end

    context 'when sticky is true' do
      before { config['makara']['sticky'] = true }

      it_behaves_like 'a transaction supporter'
    end

    context 'when sticky is false' do
      before { config['makara']['sticky'] = false }

      it_behaves_like 'a transaction supporter'
    end
  end
end
