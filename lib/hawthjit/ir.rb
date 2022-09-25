module HawthJit
  module IR
    class Instruction
      attr_reader :output, :opcode, :inputs
      def initialize(output, opcode, inputs)
        @output = output
        @opcode = opcode
        @inputs = inputs
      end

      def inspect
        "#<#{self.class} #{to_s}>"
      end

      def to_s
        "#{output} = #{[opcode, *inputs.map(&:inspect)].join(" ")}"
      end
    end

    class OutOpnd
      attr_reader :idx
      alias to_i idx

      def initialize(idx)
        @idx = idx
      end

      def to_s
        "$_#{@idx}"
      end
      alias inspect to_s
    end

    class Assembler
      attr_reader :insns

      def initialize
        @insns = []
        @last_output = 0
      end

      def build_output
        @last_output += 1
        OutOpnd.new(@last_output)
      end

      def method_missing(name, *inputs)
        output = build_output
        insn = Instruction.new(output, name, inputs)
        @insns << insn
        output
      end

      def to_x86
        pp self
        X86Assembler.new(self).compile
      end
    end
  end
end
