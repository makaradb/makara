require 'spec_helper'

describe Makara::ConnectionWrapper do
  let(:proxy){ FakeProxy.new({makara: {blocklist_duration: 5, connections: [{role: 'primary'}, {role: 'replica'}, {role: 'replica'}]}}) }
  let(:connection){ subject._makara_connection }

  subject{ proxy.primary_pool.connections.first }

  it 'should extend the connection with new functionality' do
    expect(connection).to respond_to(:_makara_name)
    expect(connection).to respond_to(:_makara)
    expect(connection).to respond_to(:_makara_hijack)
  end

  it 'should invoke hijacked methods on the proxy when invoked directly' do
    expect(proxy).to receive(:execute).with('test').once do |&block|
      expect(block.call).to eq('Hello')
    end

    connection.execute('test') { 'Hello' }
  end

  it 'should have a default weight of 1' do
    expect(subject._makara_weight).to eq(1)
  end

  context '#_makara_blocklisted?' do
    it 'should store the blocklist status' do
      expect(subject._makara_blocklisted?).to eq(false)
      subject._makara_blocklist!
      expect(subject._makara_blocklisted?).to eq(true)
      subject._makara_allowlist!
      expect(subject._makara_blocklisted?).to eq(false)
    end

    it 'should handle frozen pre-epoch dates' do
      Timecop.freeze(Date.new(1900)) do
        expect(subject._makara_blocklisted?).to eq(false)
      end
    end
  end
end
