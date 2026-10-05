# frozen_string_literal: true

module ActiveDurable
  # A named recipe: the block that describes the steps of a saga.
  class Recipe
    attr_reader :name, :version, :block

    def initialize(name, version, block)
      @name = name
      @version = version
      @block = block
    end

    def call(flow, input)
      block.call(flow, **input.to_h.transform_keys(&:to_sym))
    end

    def inspect
      "#<ActiveDurable::Recipe #{name} v#{version}>"
    end
  end

  # Keeps every defined recipe by name and version.
  #
  # Recipes are looked up by name when a worker picks up an execution, possibly in a fresh process.
  # In a Rails app, put each recipe in app/sagas/<name>_saga.rb and assign it to a constant
  # (CheckoutSaga = Durable.define(:checkout) { ... }). The registry autoloads that constant on a miss.
  class Registry
    def initialize
      @recipes = {}
      @mutex = Mutex.new
    end

    def define(name, version: 1, &block)
      raise ArgumentError, "Durable.define :#{name} needs a block" unless block

      name = name.to_s
      raise ArgumentError, "recipe names cannot be blank" if name.empty?

      recipe = Recipe.new(name, Integer(version), block)
      @mutex.synchronize { (@recipes[name] ||= {})[recipe.version] = recipe }
      recipe
    end

    def latest(name)
      versions = versions_for(name)
      versions.empty? ? raise_unknown(name) : versions.max_by(&:version)
    end

    def fetch(name, version)
      versions_for(name).find { |recipe| recipe.version == version.to_i } ||
        raise(UnknownRecipe, "recipe :#{name} has no version #{version}. Keep old versions defined " \
                             "until no execution uses them (rake active_durable:versions).")
    end

    def versions_for(name)
      name = name.to_s
      # Always touch the constant, even if the name is known: after a code reload in development the constant
      # is gone, and referencing it loads the edited file, which defines the recipe again.
      autoload_constant(name)
      (@recipes[name] || {}).values.sort_by(&:version)
    end

    def names
      @recipes.keys.sort
    end

    def clear!
      @mutex.synchronize { @recipes.clear }
    end

    private

    def raise_unknown(name)
      raise UnknownRecipe, "no recipe named :#{name}. Define it with Durable.define(:#{name}) " \
                           "in app/sagas/#{name}_saga.rb and assign it to #{constant_name(name)}."
    end

    def autoload_constant(name)
      constant_name(name).safe_constantize
    rescue StandardError, LoadError
      nil
    end

    def constant_name(name)
      "#{name.to_s.camelize}Saga"
    end
  end
end
