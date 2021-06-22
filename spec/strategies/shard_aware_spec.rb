require 'spec_helper'

describe Makara::Strategies::ShardAware do
  def with_shard(shard_id)
    begin
      Thread.current['makara_shard_id'] = shard_id
      yield
    ensure
      Thread.current['makara_shard_id'] = nil
    end
  end

  describe "failover strategy with shard awareness," do
    let(:proxy){ FakeProxy.new({makara: pool_config.merge(makara_config).merge(connections: [])}) }
    let(:pool){ Makara::Pool.new('primary', proxy) }
    let(:pool_config){ { blocklist_duration: 5} }
    let(:makara_config) { {
        primary_strategy: 'failover',
        primary_shard_aware: true,
        primary_default_shard: 'shard2'
      } }
    let(:strategy) { pool.strategy }

    it 'should use the strategy' do
      expect(pool.strategy).to be_instance_of(Makara::Strategies::ShardAware)
    end

    it 'should take the top weight for a given shard' do
      wrapper_a = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'a') }
      wrapper_b = pool.add(pool_config.merge(shard_id: 'shard1', weight: 2)){ FakeConnection.new(something: 'b') }
      wrapper_c = pool.add(pool_config.merge(weight: 2, shard_id: 'shard2')){ FakeConnection.new(something: 'c') }

      # default shard
      expect(strategy.current.something).to eql('c')
      expect(strategy.next.something).to eql('c')
      expect(strategy.next.something).to eql('c')

      # shard1
      with_shard('shard1') do
        expect(strategy.current.something).to eql('b')
        expect(strategy.next.something).to eql('b')
        expect(strategy.next.something).to eql('b')
      end

      # shard2
      with_shard('shard2') do
        expect(strategy.current.something).to eql('c')
        expect(strategy.next.something).to eql('c')
        expect(strategy.next.something).to eql('c')
      end
    end

    it 'should take given order within shard if no weights' do
      wrapper_a = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'a') }
      wrapper_b = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'b') }
      wrapper_c = pool.add(pool_config.merge(shard_id: 'shard2')){ FakeConnection.new(something: 'c') }

      # default shard
      expect(strategy.current.something).to eql('c')
      expect(strategy.next.something).to eql('c')
      expect(strategy.next.something).to eql('c')

      # shard1
      with_shard('shard1') do
        expect(strategy.current.something).to eql('a')
        expect(strategy.next.something).to eql('a')
      end

      # shard2
      with_shard('shard2') do
        expect(strategy.current.something).to eql('c')
        expect(strategy.next.something).to eql('c')
      end
    end

    it 'should handle failover to next one within shard' do
      wrapper_a = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'a') }
      wrapper_b = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'b') }
      wrapper_c = pool.add(pool_config.merge(shard_id: 'shard2')){ FakeConnection.new(something: 'c') }

      # default shard
      expect(strategy.current.something).to eql('c')
      expect(strategy.next.something).to eql('c')
      expect(strategy.next.something).to eql('c')

      # skips a for shard1
      with_shard('shard1') do
        pool.provide do |connection|
          if connection == wrapper_a
            raise Makara::Errors::BlocklistConnection.new(wrapper_a, StandardError.new('failure'))
          end
        end
        expect(strategy.current.something).to eql('b')
        expect(strategy.next.something).to eql('b')
      end

      # shard2
      with_shard('shard2') do
        expect(strategy.current.something).to eql('c')
        expect(strategy.next.something).to eql('c')
      end
    end
    it 'raises error for invalid shard' do
      with_shard('shard3') do
        expect{strategy.current.something }.to raise_error(Makara::Errors::InvalidShard)
      end
    end
  end

  describe "round_robin strategy with shard awareness," do
    let(:proxy){ FakeProxy.new({makara: pool_config.merge(makara_config).merge(connections: [])}) }
    let(:pool){ Makara::Pool.new('primary', proxy) }
    let(:pool_config){ { blocklist_duration: 5} }
    let(:makara_config) { {
        primary_strategy: 'round_robin',
        primary_shard_aware: true,
        primary_default_shard: 'shard2'
      } }
    let(:strategy) { pool.strategy }

    it 'should use the strategy' do
      expect(pool.strategy).to be_instance_of(Makara::Strategies::ShardAware)
    end

    it 'should loop through with weights within shard' do
      wrapper_a = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'a') }
      wrapper_b = pool.add(pool_config.merge(shard_id: 'shard1', weight: 2)){ FakeConnection.new(something: 'b') }
      wrapper_c = pool.add(pool_config.merge(weight: 2, shard_id: 'shard2')){ FakeConnection.new(something: 'c') }

      # default shard
      expect(strategy.current.something).to eql('c')
      expect(strategy.next.something).to eql('c')
      expect(strategy.next.something).to eql('c')

      # shard1
      with_shard('shard1') do
        expect(strategy.current.something).to eql('a')
        expect(strategy.next.something).to eql('b')
        expect(strategy.next.something).to eql('b')
        expect(strategy.next.something).to eql('a')
      end

      # shard2
      with_shard('shard2') do
        expect(strategy.current.something).to eql('c')
        expect(strategy.next.something).to eql('c')
        expect(strategy.next.something).to eql('c')
      end
    end

    it 'should handle failover to next one within shard' do
      wrapper_a = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'a') }
      wrapper_b = pool.add(pool_config.merge(shard_id: 'shard1')){ FakeConnection.new(something: 'b') }
      wrapper_c = pool.add(pool_config.merge(shard_id: 'shard2')){ FakeConnection.new(something: 'c') }

      # default shard
      expect(strategy.current.something).to eql('c')
      expect(strategy.next.something).to eql('c')
      expect(strategy.next.something).to eql('c')

      # skips a for shard1
      with_shard('shard1') do
        pool.provide do |connection|
          if connection == wrapper_a
            raise Makara::Errors::BlocklistConnection.new(wrapper_a, StandardError.new('failure'))
          end
        end
        expect(strategy.current.something).to eql('b')
        expect(strategy.next.something).to eql('b')
        expect(strategy.next.something).to eql('b')
      end

      # shard2
      with_shard('shard2') do
        expect(strategy.current.something).to eql('c')
        expect(strategy.next.something).to eql('c')
        expect(strategy.next.something).to eql('c')
      end
    end
    it 'raises error for invalid shard' do
      with_shard('shard3') do
        expect{strategy.current.something }.to raise_error(Makara::Errors::InvalidShard)
      end
    end
  end

  describe "uses the configured failover strategy when shard_aware set to false," do
    let(:proxy){ FakeProxy.new({makara: pool_config.merge(makara_config).merge(connections: [])}) }
    let(:pool){ Makara::Pool.new('primary', proxy) }
    let(:pool_config){ { blocklist_duration: 5} }
    let(:makara_config) { {
        primary_strategy: 'failover',
        primary_shard_aware: false,
        primary_default_shard: 'shard2'
      } }
    let(:strategy) { pool.strategy }

    it 'should use the failover strategy' do
      expect(pool.strategy).to be_instance_of(Makara::Strategies::PriorityFailover)
    end
  end

  describe "uses the configured roundrobin strategy when shard_aware set to false," do
    let(:proxy){ FakeProxy.new({makara: pool_config.merge(makara_config).merge(connections: [])}) }
    let(:pool){ Makara::Pool.new('primary', proxy) }
    let(:pool_config){ { blocklist_duration: 5} }
    let(:makara_config) { {
        primary_strategy: 'round_robin',
        primary_shard_aware: false,
        primary_default_shard: 'shard2'
      } }
    let(:strategy) { pool.strategy }

    it 'should use the failover strategy' do
      expect(pool.strategy).to be_instance_of(Makara::Strategies::RoundRobin)
    end
  end
end
