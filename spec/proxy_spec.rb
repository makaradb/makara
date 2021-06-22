require 'spec_helper'

describe Makara::Proxy do
  let(:klass){ FakeProxy }

  it 'sets up a primary and replica pool no matter the number of connections' do
    proxy = klass.new(config(0, 0))
    expect(proxy.primary_pool).to be_a(Makara::Pool)
    expect(proxy.replica_pool).to be_a(Makara::Pool)

    proxy = klass.new(config(2, 0))
    expect(proxy.primary_pool).to be_a(Makara::Pool)
    expect(proxy.replica_pool).to be_a(Makara::Pool)

    proxy = klass.new(config(0, 2))
    expect(proxy.primary_pool).to be_a(Makara::Pool)
    expect(proxy.replica_pool).to be_a(Makara::Pool)

    proxy = klass.new(config(2, 2))
    expect(proxy.primary_pool).to be_a(Makara::Pool)
    expect(proxy.replica_pool).to be_a(Makara::Pool)
  end

  it 'instantiates N connections within each pool' do
    proxy = klass.new(config(1, 2))

    expect(proxy.primary_pool.connection_count).to eq(1)
    expect(proxy.replica_pool.connection_count).to eq(2)
  end

  it 'should delegate any unknown method to a connection in the primary pool' do
    proxy = klass.new(config(1, 2))

    con = proxy.primary_pool.connections.first
    allow(con).to receive(:irespondtothis){ 'hello!' }

    expect(proxy).to respond_to(:irespondtothis)
    expect(proxy.irespondtothis).to eq('hello!')
  end

  describe '#stick_to_primary' do
    let(:proxy) { klass.new(config(1, 2)) }

    it 'should use primary if manually forced' do
      expect(proxy.primary_for?('select * from users')).to eq(false)

      proxy.stick_to_primary!

      expect(proxy.primary_for?('select * from users')).to eq(true)
    end

    it 'should persist stickiness by default' do
      now = Time.now
      proxy.stick_to_primary!

      next_context = Makara::Context.next
      expect(next_context[proxy.id]).to be >= (now + 5).to_f

      proxy = klass.new(config(1, 2))
      expect(proxy.primary_for?('select * from users')).to eq(true)
    end

    it 'optionally skips stickiness persistence, so it applies only to the current request' do
      now = Time.now
      proxy.stick_to_primary!(false)

      expect(proxy.primary_for?('select * from users')).to eq(true)
      next_context = Makara::Context.next
      expect(next_context).to be_nil # Nothing to persist, so context is empty

      proxy = klass.new(config(1, 2))
      expect(proxy.primary_for?('select * from users')).to eq(false)
    end

    it 'supports a float primary_ttl for stickiness duration' do
      now = Time.now
      config = config(1, 2).dup
      config[:makara][:primary_ttl] = 0.5
      proxy = klass.new(config)

      proxy.stick_to_primary!

      next_context = Makara::Context.next
      expect(next_context[proxy.id]).to be >= (now + 0.5).to_f
      expect(next_context[proxy.id]).to be < (now + 1).to_f
    end
  end

  describe '#appropriate_pool' do
    let(:proxy) { klass.new(config(1,1)) }

    it 'should be sticky by default' do
      expect(proxy.sticky).to eq(true)
    end

    it 'should provide the replica pool for a read' do
      expect(proxy.primary_for?('select * from users')).to eq(false)
    end

    it 'should provide the primary pool for a write' do
      expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
    end

    # primary is used, it should continue being used for the duration of the context
    it 'should stick to primary once used for a sticky operation' do
      expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
      expect(proxy.primary_for?('select * from users')).to eq(true)
    end

    it 'should not stick to primary if stickiness is disabled' do
      proxy.sticky = false
      expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
      expect(proxy.primary_for?('select * from users')).to eq(false)
    end

    it 'should not stick to primary if we are in a without_sticking block' do
      expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)

      proxy.without_sticking do
        expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
        expect(proxy.primary_for?('select * from users')).to eq(false)
      end

      expect(proxy.primary_for?('select * from users')).to eq(true)
      expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
      expect(proxy.primary_for?('select * from users')).to eq(true)
    end

    it 'should not stick to primary after without_sticking block if there is a write in it' do
      expect(proxy.primary_for?('select * from users')).to eq(false)

      proxy.without_sticking do
        expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
        expect(proxy.primary_for?('select * from users')).to eq(false)
      end

      expect(proxy.primary_for?('select * from users')).to eq(false)
    end

    it "should not release primary if it was stuck in the same request (no context changes yet)" do
      expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
      expect(proxy.primary_for?('select * from users')).to eq(true)

      Timecop.travel Time.now + 10 do
        # primary_ttl has passed but we are still in the same request, so current context
        # is still relevant
        expect(proxy.primary_for?('select * from users')).to eq(true)
      end
    end

    it 'should release primary if all stuck connections are released' do
      expect(proxy.primary_for?('insert into users values (a,b,c)')).to eq(true)
      expect(proxy.primary_for?('select * from users')).to eq(true)

      Makara::Context.release_all

      expect(proxy.primary_for?('select * from users')).to eq(false)
    end

    it 'should use primary if all replicas are blocklisted' do
      allow(proxy.replica_pool).to receive(:completely_blocklisted?){ true }
      expect(proxy.primary_for?('select * from users')).to eq(true)
    end

    it 'should use primary if all replicas become blocklisted as part of the invocation' do
      allow(proxy.replica_pool).to receive(:next).and_return(nil)

      test = double
      expect(test).to receive(:blocklisting).once
      expect(test).to receive(:using_primary).once

      proxy.send(:appropriate_pool, :execute, ['select * from users']) do |pool|
        if pool == proxy.replica_pool
          test.blocklisting
          pool.instance_variable_get('@blocklist_errors') << StandardError.new('some connection issue')
          pool.connections.each(&:_makara_blocklist!)
          pool.provide
        else
          test.using_primary
        end
      end
    end

    it 'should raise the error and allowlist all connections if everything is blocklisted (start over)' do
      proxy.ping

      # weird setup to allow for the correct
      proxy.replica_pool.connections.each(&:_makara_blocklist!)
      proxy.replica_pool.instance_variable_get('@blocklist_errors') << StandardError.new('some replica connection issue')
      proxy.primary_pool.connections.each(&:_makara_blocklist!)
      proxy.primary_pool.instance_variable_get('@blocklist_errors') << StandardError.new('some primary connection issue')

      allow(proxy).to receive(:_appropriate_pool).and_return(proxy.replica_pool, proxy.primary_pool)

      begin
        proxy.send(:appropriate_pool, :execute, ['select * from users']) do |pool|
          pool.provide{|c| c }
        end
      rescue Makara::Errors::AllConnectionsBlocklisted => e
        expect(e.message).to eq('[Makara/primary] All connections are blocklisted -> some primary connection issue -> [Makara/replica] All connections are blocklisted -> some replica connection issue')
      end

      proxy.replica_pool.connections.each{|con| expect(con._makara_blocklisted?).to eq(false) }
      proxy.primary_pool.connections.each{|con| expect(con._makara_blocklisted?).to eq(false) }
    end
  end
end
