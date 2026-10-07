# frozen_string_literal: true

module ActiveDurable
  # How many times a step is tried and how long to wait between tries.
  #
  #   flow.step :charge, retry: 5 { ... }
  #   flow.step :charge, retry: { attempts: 5, backoff: [1, 10, 60] } { ... }
  #   flow.step :charge, retry: false { ... }   # a single attempt
  #
  # @api private
  class RetryPolicy
    attr_reader :attempts

    def self.build(option, default_attempts:)
      case option
      when nil then new(attempts: default_attempts)
      when false then new(attempts: 1)
      when Integer then new(attempts: option)
      when Hash then new(attempts: option.fetch(:attempts, default_attempts), backoff: option[:backoff])
      when RetryPolicy then option
      else raise ArgumentError, "retry: expects false, an Integer or a Hash, got #{option.inspect}"
      end
    end

    def initialize(attempts:, backoff: nil)
      @attempts = Integer(attempts)
      raise ArgumentError, "retry attempts must be at least 1" if @attempts < 1

      @backoff = backoff
    end

    # Seconds to wait after the given failed attempt (1-based).
    def delay(attempt)
      backoff = @backoff || ActiveDurable.config.backoff
      seconds =
        case backoff
        when Proc then backoff.call(attempt)
        when Array then backoff[attempt - 1] || backoff.last
        else backoff
        end
      seconds.to_f
    end
  end
end
