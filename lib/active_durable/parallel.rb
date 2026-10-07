# frozen_string_literal: true

module ActiveDurable
  # Collects the branches of a flow.parallel block. Nothing runs while the block is read:
  # the branches run afterwards, each in its own thread.
  #
  #   results = flow.parallel(:reserve) do |branches|
  #     warehouses.each do |warehouse|
  #       branches.step(warehouse.code, undo: ->(r) { warehouse.release(r["id"]) }) do |ticket|
  #         warehouse.reserve(ticket)
  #       end
  #     end
  #   end
  #   results # => { "MEX" => {...}, "GDL" => {...} }
  class ParallelGroup
    # @api private
    Branch = Struct.new(:name, :full_name, :kind, :undo, :options, :block)
    # @api private
    OPTIONS = %i[retry undo_on_failure].freeze

    # @api private
    attr_reader :branches

    # @api private
    def initialize(parallel_name)
      @parallel_name = parallel_name
      @branches = []
    end

    # A branch that talks to the outside world, like {Flow#step}.
    #
    # @param name [Symbol, String] unique in this parallel block
    # @param undo [#call, nil]
    # @param options [Hash] `retry:` and `undo_on_failure:`
    # @yieldparam ticket [String]
    # @return [void]
    def step(name, undo: nil, **options, &block)
      add(name, "step", undo, options, block)
    end

    # A branch that only touches your own database, like {Flow#transaction}.
    #
    # @param (see #step)
    # @return [void]
    def transaction(name, undo: nil, **options, &block)
      add(name, "transaction", undo, options, block)
    end

    private

    def add(name, kind, undo, options, block)
      name = name.to_s
      raise InvalidRecipe, "branch :#{name} of flow.parallel :#{@parallel_name} needs a block" unless block
      raise InvalidRecipe, "branch names in flow.parallel :#{@parallel_name} cannot be blank" if name.empty?
      if name.include?("/") || name.end_with?(":undo")
        raise InvalidRecipe, "branch name #{name.inspect} cannot contain '/' or end in ':undo'"
      end

      unknown = options.keys - OPTIONS
      raise InvalidRecipe, "unknown option(s) for a parallel branch: #{unknown.join(", ")}" if unknown.any?
      if @branches.any? { |branch| branch.name == name }
        raise DuplicateStepName, "flow.parallel :#{@parallel_name} declares the branch :#{name} twice"
      end

      @branches << Branch.new(name, "#{@parallel_name}/#{name}", kind, undo, options, block)
      nil
    end
  end
end
