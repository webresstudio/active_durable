# frozen_string_literal: true

module ActiveDurable
  # Step results, inputs and signal payloads live in the notebook as JSON. This module turns a value
  # into exactly what a later replay will read back (string keys, no symbols), so the first run and a
  # replay behave the same. Anything that is not plain JSON is rejected with a message that says where.
  #
  # @api private
  module Serializer
    module_function

    def normalize(value, path = "value")
      case value
      when nil, true, false, String, Integer then value
      when Float then finite_float(value, path)
      when Symbol then value.to_s
      when Array then value.each_with_index.map { |item, index| normalize(item, "#{path}[#{index}]") }
      when Hash then normalize_hash(value, path)
      else
        raise NotSerializable,
              "#{path} is a #{value.class}. Steps, inputs and signals must use plain JSON values " \
              "(nil, true/false, numbers, strings, arrays and hashes). Keep only what you need, " \
              "for example { \"id\" => charge.id }."
      end
    end

    def normalize_hash(hash, path)
      hash.each_with_object({}) do |(key, item), out|
        key = key.to_s if key.is_a?(Symbol)
        raise NotSerializable, "#{path} has a #{key.class} key; use strings or symbols" unless key.is_a?(String)

        out[key] = normalize(item, "#{path}[#{key.inspect}]")
      end
    end

    def finite_float(value, path)
      raise NotSerializable, "#{path} is #{value}, which JSON cannot store" unless value.finite?

      value
    end
  end
end
