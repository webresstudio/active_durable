# frozen_string_literal: true

class TestProduct < ActiveRecord::Base
  self.table_name = "test_products"
end

class TestOrder < ActiveRecord::Base
  self.table_name = "test_orders"
end

# Behaves like Stripe: the same idempotency key always returns the first result.
module FakeStripe
  class << self
    attr_reader :charges, :refunds, :calls

    def reset!
      @charges = {}
      @refunds = {}
      @calls = Hash.new(0)
      @failures = []
    end

    # The next n calls raise error (a timeout by default).
    def fail_next(times, error = Timeout::Error.new("stripe did not answer"))
      @failures.concat([error] * times)
    end

    def charge(amount:, ticket:)
      @calls[ticket] += 1
      raise @failures.shift if @failures.any?

      @charges[ticket] ||= { "id" => "pi_#{@charges.size + 1}", "amount" => amount }
    end

    def refund(charge_id:, ticket:)
      @calls[ticket] += 1
      raise @failures.shift if @failures.any?

      @refunds[ticket] ||= { "id" => "re_#{@refunds.size + 1}", "charge" => charge_id }
    end

    def net_charged
      refunded = refunds.values.map { |refund| refund["charge"] }
      charges.values.reject { |charge| refunded.include?(charge["id"]) }.sum { |charge| charge["amount"] }
    end
  end
end

# Not idempotent on purpose: every call is a delivery.
module FakeMailer
  class << self
    attr_reader :deliveries

    def reset!
      @deliveries = []
      @failures = 0
    end

    def fail_next(times)
      @failures += times
    end

    def deliver(to)
      if @failures.positive?
        @failures -= 1
        raise IOError, "smtp connection refused"
      end
      @deliveries << to
    end
  end
end
