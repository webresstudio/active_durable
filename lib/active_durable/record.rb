# frozen_string_literal: true

module ActiveDurable
  # Base class for the gem's tables. It shares ActiveRecord::Base's connection on purpose:
  # flow.transaction is only atomic when the notebook lives in the same database as your data.
  #
  # @api private
  class Record < ActiveRecord::Base
    self.abstract_class = true

    # A JSON type object (not the :json symbol): resolving a symbol needs a database connection,
    # and these classes may load before the app has configured one.
    JSON_TYPE = ActiveRecord::Type::Json.new
  end
end
