module HawthJit
  class IR
    Label = Struct.new(:name, :number) do
      def inspect
        "label:#{name}"
      end
    end

    class Instruction
      attr_reader :outputs, :inputs, :props
      def initialize(outputs, inputs)
        @outputs = outputs
        @inputs = inputs
        @props = {}
      end

      def opcode
        name
      end

      def input
        if inputs.size != 1
          raise "input called on instruction with #{inputs.size} inputs"
        end
        inputs[0]
      end

      def output
        if outputs.size != 1
          raise "output called on instruction with #{outputs.size} outputs"
        end
        outputs[0]
      end

      def inspect
        "#<#{self.class} #{to_s}>"
      end

      def to_s
        s = +""
        if outputs.any?
          s << "#{outputs.map(&:to_s).join(", ")} = "
        end
        s << "#{[opcode, *inputs.map(&:inspect)].join(" ")}"
        s
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

    DEFINITIONS = {}

    def self.define(name, io = nil)
      case io
      when nil
        inputs = outputs = 0
      when Integer
        inputs = io
        outputs = 0
      when Hash
        raise ArgumentError unless io.size == 1
        inputs, outputs = io.to_a[0]
      end

      klass = Class.new(Instruction) do
        define_singleton_method(:name) { name }
        define_method(:name) { name }
        define_singleton_method(:inputs) { inputs }
        define_singleton_method(:outputs) { outputs }
      end

      const_set(name.to_s.upcase, klass)
      DEFINITIONS[name.to_s] = klass
    end

    define :nop
    define :comment, 1 => 0
    define :jit_prelude
    define :jit_return, 1 => 0
    define :side_exit
    define :breakpoint
    define :bind, 1
    define :br, 1
    define :br_cond, 3
    define :assign, 1 => 1

    define :rbool, 1 => 1
    define :rtest, 1 => 1

    define :cmp_s, 3 => 1
    define :cmp_u, 3 => 1

    define :guard_fixnum, 1

    define :push_frame, 6
    define :pop_frame
    define :cfp, 0 => 1
    define :update_pc, 1 => 0
    define :update_sp
    define :call_jit_func, 1 => 1

    define :load, :any => 1
    define :store, :any => 0

    define :add, 2 => 1
    define :add_guard_overflow, 2 => 1
    define :sub, 2 => 1
    define :sub_guard_overflow, 2 => 1
    define :imul, 2 => 1
    define :imul_guard_overflow, 2 => 1
    define :or, 2 => 1
    define :and, 2 => 1
    define :xor, 2 => 1
    define :shr, 2 => 1

    define :vm_push, 1 => 0
    define :vm_pop, 0 => 1

    attr_accessor :insns, :labels, :last_output
    alias instructions insns

    def initialize
      @insns = []
      @labels = []
      @last_output = 0
    end

    def initialize_copy(other)
      @insns = other.insns.dup
      @labels = other.labels.dup
      @last_output = other.last_output
    end

    def label(name = nil)
      number = @labels.size
      name ||= "L#{number}"
      label = Label.new(name, number)
      @labels << label
      label
    end

    def build_output
      @last_output += 1
      OutOpnd.new(@last_output)
    end

    def build(name, *inputs)
      klass = DEFINITIONS.fetch(name.to_s)

      num_inputs = klass.inputs
      num_outputs = klass.outputs

      if num_inputs == :any
        num_inputs = inputs.size
      end

      raise ArgumentError, "expected #{num_inputs} inputs for #{name}, got #{inputs.size}" unless num_inputs == inputs.size

      outputs = num_outputs.times.map { build_output }
      klass.new(outputs, inputs)
    end

    def emit(name, *inputs)
      insn = build(name, *inputs)
      @insns << insn

      outputs = insn.outputs
      case outputs.size
      when 0
        nil
      when 1
        outputs[0]
      else
        outputs
      end
    end

    def to_x86
      pp self
      X86Assembler.new(self).compile
    end

    def assembler
      Assembler.new(self)
    end

    class Assembler
      def initialize(ir)
        @ir = ir
      end

      def label(*args)
        @ir.label(*args)
      end

      def method_missing(*args)
        @ir.emit(*args)
      end
    end
  end
end
