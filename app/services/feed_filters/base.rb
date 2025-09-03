module FeedFilters
  class Base
    attr_reader :applied, :details

    def initialize(options = {})
      @applied = false
      @details = {}
      @options = options
    end

    def applicable?(entry, channel)
      raise NotImplementedError
    end

    def apply(entry, channel)
      raise NotImplementedError
    end

    protected

    def mark_as_applied!(details = {})
      @applied = true
      @details = details
    end
  end
end
