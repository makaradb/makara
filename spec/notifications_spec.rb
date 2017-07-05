require 'spec_helper'

describe Makara::Notifications do
  describe '#notify!' do
    context 'without any registered callbacks' do
      it 'does not raise' do
        expect {
          Makara::Notifications.notify!('Some:instrumentation:point', 'with', 4, 'arbitrary', 'arguments')
        }.not_to raise_error
      end
    end

    context 'with registered callbacks' do
      it 'calls all notification callbacks' do
        @first_notification = @second_notification = @third_notification = false

        Makara::Notifications.register_callback('Notification:test') do
          @first_notification = true
        end

        Makara::Notifications.register_callback('Notification:test') do |arg1|
          @second_notification = arg1
        end

        Makara::Notifications.register_callback('Notification:test') do |arg1, arg2|
          @third_notification = [arg1, arg2]
        end

        Makara::Notifications.notify!('Notification:test', 'one', 'two')

        expect(@first_notification).to be true
        expect(@second_notification).to eq('one')
        expect(@third_notification).to eq(['one', 'two'])
      end
    end
  end
end
