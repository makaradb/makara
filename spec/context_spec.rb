require 'spec_helper'

describe Makara::Context do
  before { allow(Makara::Notifications).to receive(:notify!) }

  describe 'get_current' do
    it 'does not share context across threads' do
      uniq_current_contexts = []
      threads = []

      1.upto(3).map do |i|
        threads << Thread.new do
          current = Makara::Context.get_current
          expect(current).to_not be_nil
          expect(uniq_current_contexts).to_not include(current)
          uniq_current_contexts << current

          sleep(0.2)
        end
        sleep(0.1)
      end

      threads.map(&:join)
      expect(uniq_current_contexts.uniq.count).to eq(3)
    end

    it 'sends a notification' do
      current_context = Makara::Context.get_current
      expect(Makara::Notifications).to have_received(:notify!).with('Context:get_current', current_context)
    end
  end

  describe 'set_current' do

    it 'does not share context across threads' do
      uniq_current_contexts = []
      threads = []

      1.upto(3).map do |i|
        threads << Thread.new do

          current = Makara::Context.set_current("val#{i}")
          expect(current).to_not be_nil
          expect(current).to eq("val#{i}")

          sleep(0.2)

          current = Makara::Context.get_current
          expect(current).to_not be_nil
          expect(current).to eq("val#{i}")

          uniq_current_contexts << current
        end
        sleep(0.1)
      end

      threads.map(&:join)
      expect(uniq_current_contexts.uniq.count).to eq(3)
    end

    it 'sends a notification' do
      Makara::Context.set_current('current_context')
      expect(Makara::Notifications).to have_received(:notify!).with('Context:set_current', 'current_context')
    end
  end

  describe 'get_previous' do
    it 'does not share context across threads' do
      uniq_current_contexts = []
      threads = []

      1.upto(3).map do |i|
        threads << Thread.new do
          current = Makara::Context.get_previous
          expect(current).to_not be_nil
          expect(uniq_current_contexts).to_not include(current)
          uniq_current_contexts << current

          sleep(0.2)
        end
        sleep(0.1)
      end

      threads.map(&:join)
      expect(uniq_current_contexts.uniq.count).to eq(3)
    end

    it 'sends a notification' do
      previous_context = Makara::Context.get_previous
      expect(previous_context).not_to be nil
      expect(Makara::Notifications).to have_received(:notify!).with('Context:get_previous', previous_context)
    end
  end

  describe 'set_previous' do
    it 'does not share context across threads' do
      uniq_current_contexts = []
      threads = []

      1.upto(3).map do |i|
        threads << Thread.new do

          current = Makara::Context.set_previous("val#{i}")
          expect(current).to_not be_nil
          expect(current).to eq("val#{i}")

          sleep(0.2)

          current = Makara::Context.get_previous
          expect(current).to_not be_nil
          expect(current).to eq("val#{i}")

          uniq_current_contexts << current
        end
        sleep(0.1)
      end

      threads.map(&:join)
      expect(uniq_current_contexts.uniq.count).to eq(3)
    end

    it 'sends a notification' do
      Makara::Context.set_previous('previous_context')
      expect(Makara::Notifications).to have_received(:notify!).with('Context:set_previous', 'previous_context')
    end
  end

end

