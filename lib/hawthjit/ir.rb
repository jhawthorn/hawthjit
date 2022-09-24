module HawthJit
  module IR
    class Assembler
      def initialize
        @insns = []
      end

      def method_missing(*args)
        @insns << args
      end

      def to_x86
        X86Assembler.new.compile(@insns)
      end
    end
  end
end
