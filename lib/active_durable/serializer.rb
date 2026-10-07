# frozen_string_literal: true

module ActiveDurable
  # Step results, inputs and signal payloads live in the notebook as JSON. This module turns a value
  # into exactly what a later replay will read back (string keys, no symbols, UTF-8 strings), so the first run
  # and a replay behave the same. Anything that is not plain JSON, or that some database cannot store (a NUL
  # character, bytes that are not UTF-8), is rejected with a message that says where.
  #
  # @api private
  module Serializer
    module_function

    def normalize(value, path = "value")
      case value
      when nil, true, false, Integer then value
      when String then utf8(value, path)
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

        key = utf8(key, "a key of #{path}")
        out[key] = normalize(item, "#{path}[#{key.inspect}]")
      end
    end

    # Binary strings (Net::HTTP response bodies) are fine when their bytes are UTF-8; other encodings are converted.
    def utf8(value, path)
      string = value
      if [Encoding::BINARY, Encoding::US_ASCII].include?(string.encoding)
        string = string.dup.force_encoding(Encoding::UTF_8)
      elsif string.encoding != Encoding::UTF_8
        string = string.encode(Encoding::UTF_8)
      end
      unless string.valid_encoding?
        raise NotSerializable, "#{path} has bytes that are not UTF-8. Decode it with the right encoding, or " \
                               "Base64-encode binary data."
      end
      if string.include?("\u0000")
        raise NotSerializable, "#{path} contains a NUL character (\\u0000), which PostgreSQL cannot store. " \
                               "Strip it, or Base64-encode binary data."
      end
      string
    rescue EncodingError => e
      raise NotSerializable, "#{path} cannot be converted to UTF-8 (#{e.message})"
    end

    def finite_float(value, path)
      raise NotSerializable, "#{path} is #{value}, which JSON cannot store" unless value.finite?

      value
    end
  end
end
