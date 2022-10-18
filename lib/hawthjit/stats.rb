require "fiddle"

module HawthJit
  class Stats
    KEYS = [:side_exits]

    def initialize
      @buffer = Fiddle::Pointer.malloc(KEYS.size * SIZEOF_VALUE)
    end

    def ptr_for(key)
      idx = KEYS.index(key)
      @buffer + idx * SIZEOF_VALUE
    end

    def addr_for(key)
      ptr_for(key).to_i
    end

    def [](key)
      # FIXME: use qword instead of byte
      ptr_for(key)[0]
    end

    def []=(key, value)
      # FIXME: use qword instead of byte
      ptr_for(key)[0] = value
    end

    def to_h
      KEYS.map do |key|
        [key, self[key]]
      end.to_h
    end
  end

  STATS = Stats.new
end
