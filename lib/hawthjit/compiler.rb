module HawthJit
  class Compiler
    class Operand
      attr_reader :value

      def initialize(decl, value)
        @decl = decl
        @value = value
      end

      def name
        @decl[:name]
      end

      def type
        @decl[:type]
      end

      def insn_inspect
        "#{name}=#{inspect_value}"
      end

      def inspect_value
        case type
        when "VALUE"
          Fiddle.dlunwrap(value).inspect
        when "lindex_t"
          value
        else
          "(#{type})#{value}"
        end
      end
    end

    class Insn
      attr_reader :insn, :operands
      def initialize(insn, operands)
        @insn = insn
        @operands = operands
      end

      def inspect
        segments = [insn.name, *operands.map(&:insn_inspect)]
        "#<#{self.class} #{segments.join(" ")}>"
      end
    end

    INSNS = RubyVM::MJIT.const_get(:INSNS)

    attr_reader :iseq
    alias iseq_ptr iseq

    def body
      iseq.body
    end

    def initialize(iseq)
      @iseq = iseq
    end

    def insns
      return @insns if @insns

      insns = []
      pos = 0
      while pos < body.iseq_size
        insn = INSNS.fetch(C.rb_vm_insn_decode(body.iseq_encoded[pos]))
        operands = insn.opes.map.with_index do |type, i|
          Operand.new(
            type,
            body.iseq_encoded[pos + i + 1]
          )
        end
        insns << Insn.new(insn, operands)
        pos += insn.len
      end

      @insns = insns
    end

    def compile
      if iseq.body.location.label == "double"
        puts "JIT compiling #{iseq_ptr}"
        pp insns
        asm_double
      end
    end

    def asm_double
      x86 = AsmJIT::X86
      code = AsmJIT::CodeHolder.new
      asm = x86::Assembler.new(code)

      # jit_func(rb_execution_context_t *, rb_control_frame_t *)
      #          RDI                       RSI
      ec_reg = :rdi
      cfp_reg = :rsi

      cfp_sp_ptr = x86.qword_ptr(cfp_reg, 0x8)
      asm.mov(:rax, cfp_sp_ptr) # sp = cfp->sp
      local0_offset = -(3 + 1) * 8
      asm.mov(:rax, x86.qword_ptr(:rax, local0_offset))

      asm.sub(:rax, 1)    # remove tag bit
      asm.add(:rax, :rax) # double rax (not safe from overflow ¯\_(ツ)_/¯)
      asm.add(:rax, 1)    # re-add tag bit

      # pop frame
      ec_cfp_ptr = x86.qword_ptr(ec_reg, 0x10)
      asm.add(ec_cfp_ptr, 0x40)

      asm.ret

      code.to_ptr
    end
  end
end
