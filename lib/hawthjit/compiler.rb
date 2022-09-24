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

      ID2SYM = Fiddle::Function.new(Fiddle::Handle::DEFAULT["rb_id2sym"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)

      class CallInfo
        attr_reader :argc, :flag, :mid, :sym
        def initialize(ci)
          @argc = C.vm_ci_argc(ci)
          @flag = C.vm_ci_flag(ci)

          ptr = ci.to_i
          if ptr[0]
            # embedded
            @mid = ptr >> 32
          else
            binding.irb
          end
          @sym = Fiddle.dlunwrap(ID2SYM.call(@mid))
        end

        def inspect
          "call_info(mid: #{sym}, argc: #{argc}, flag: #{flag})"
        end
      end

      class CallCache
        def initialize(cc)
          @cc = cc
        end

        def inspect
          if @cc.klass && @cc.cme_
            "call_cache(full)"
          else
            "call_cache(empty)"
          end
        end
      end

      def inspect_value
        case type
        when "VALUE"
          Fiddle.dlunwrap(value).inspect
        when "lindex_t", "offset"
          value
        when "CALL_DATA"
          cd = C.CALL_DATA.new(value)
          ci = CallInfo.new cd.ci
          cc = CallCache.new cd.cc
          [ci, cc].inspect
        else
          "(#{type})#{value}"
        end
      end
    end

    class Insn
      attr_reader :insn, :operands, :pos
      def initialize(insn, operands, pos)
        @insn = insn
        @operands = operands
        @pos = pos
      end

      def name
        insn.name
      end

      def len
        insn.len
      end

      def [](name)
        name = name.to_s
        operand = operands.detect { |x| x.name == name }
        operand.value
      end

      def inspect
        "#<#{self.class} #{to_s}>"
      end

      def to_s
        segments = [name, *operands.map(&:insn_inspect)]
        segments.join(" ")
      end
    end

    INSNS = RubyVM::MJIT.const_get(:INSNS)

    attr_reader :iseq
    alias iseq_ptr iseq

    def body
      iseq.body
    end

    X86 = AsmJIT::X86
    attr_reader :asm
    def initialize(iseq)
      @iseq = iseq
      @code = AsmJIT::CodeHolder.new
      @disasm = +""
      @code.logger = @disasm
      @asm = X86::Assembler.new(@code)
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
        insns << Insn.new(insn, operands, pos)
        pos += insn.len
      end

      @insns = insns
    end

    def labels
      return @labels if @labels

      @labels = insns.map do |insn|
        [insn.pos, @asm.new_label]
      end.to_h
    end

    CantCompile = Class.new(StandardError)

    # Callee-saved registers
    # We make the same choices as YJIT
    SP = X86::REGISTERS[:rbx]
    CFP = X86::REGISTERS[:r13]
    EC = X86::REGISTERS[:r12]

    CFP_SIZE = C.rb_control_frame_t.sizeof

    CPointer = RubyVM::MJIT.const_get(:CPointer)

    class AsmStruct
      Member = Struct.new(:offset, :bytesize)
      def self.from_mjit(struct)
        members = struct.new(0).instance_variable_get(:@members)
        members = members.transform_values do |type, offset|
          if Class === type && CPointer::Pointer > type
            type = type.new(0).type
          end
          size =
            if Class === type && CPointer::Struct > type
              # pointer size
              8
            else
              type.size
            end
          Member.new(offset / 8, size)
        end
        Class.new(AsmStruct) do
          define_method(:members) { members }
        end
      end

      def initialize(reg)
        @reg = reg
      end

      def [](field)
        member = members.fetch(field)
        X86.ptr(@reg, member.offset, member.bytesize)
      end
    end

    def self.decorate_reg(reg, struct)
      reg.singleton_class.define_method(:[]) do |field|
        struct.new(self)[field]
      end
    end

    CFPStruct = AsmStruct.from_mjit C.rb_control_frame_t
    decorate_reg(CFP, CFPStruct)

    ECStruct = AsmStruct.from_mjit C.rb_execution_context_t
    decorate_reg(EC, ECStruct)

    def compile_entry
      # Save callee-saved regs
      asm.push(SP)
      asm.push(CFP)
      asm.push(EC)

      asm.mov(CFP, :rsi)
      asm.mov(EC, :rdi)
      asm.mov(SP, CFP[:sp])
    end

    def compile_exit
      asm.pop(EC)
      asm.pop(CFP)
      asm.pop(SP)
      asm.ret
    end

    def compile_getlocal_WC_0(insn)
      cfp_ep_ptr = CFP[:ep]
      asm.mov(:rax, cfp_ep_ptr) # ep = cfp->ep
      local0_offset = -insn[:idx] * 8
      asm.mov(:rax, X86.qword_ptr(:rax, local0_offset))
      push_stack(:rax)
    end

    def compile_putself(insn)
      asm.mov(:rax, CFP[:self])
      push_stack(:rax)
    end

    def compile_leave(insn)
      ec_cfp_ptr = EC[:cfp]
      asm.add(ec_cfp_ptr, CFP_SIZE)

      pop_stack(:rax)
      compile_exit
    end

    def compile_putobject(insn)
      value = insn.operands[0].value
      push_stack(value)
    end

    def compile_putobject_INT2FIX_1_(insn)
      push_stack(Fiddle.dlwrap(1))
    end

    Qtrue = Fiddle.dlwrap(true)
    Qfalse = Fiddle.dlwrap(false)
    Qnil = Fiddle.dlwrap(nil)

    def compile_opt_lt(insn)
      pop_stack(:rcx)
      pop_stack(:rax)
      asm.cmp(:rax, :rcx)
      asm.mov(:rax, Qfalse)
      asm.mov(:rcx, Qtrue)
      asm.cmovl(:rax, :rcx)
      push_stack(:rax)
    end

    def compile_branchunless(insn)
      pop_stack(:rax)
      asm.cmp(:rax, Qnil)

      target_label = labels.fetch(insn.pos + insn.len + insn[:dst])
      asm.jle(target_label)
    end

    def push_stack(opnd)
      # For now use the machine stack
      asm.push(opnd)
    end

    def pop_stack(opnd)
      # For now use the machine stack
      asm.pop(opnd)
    end

    def compile_opt_minus(insn)
      pop_stack(:rcx)
      pop_stack(:rax)

      asm.sub(:rax, :rcx)
      asm.or(:rax, 1)

      push_stack(:rax)
    end

    def compile_opt_plus(insn)
      pop_stack(:rcx)
      pop_stack(:rax)

      asm.sub(:rcx, 1)
      asm.add(:rax, :rcx)

      push_stack(:rax)
    end

    def compile_opt_send_without_block(insn)
      @asm.int(3)
    end

    def compile_opt_mult(insn)
      # FIXME: Assumes fixnum * fixnum
      pop_stack(:rax)
      pop_stack(:rcx)

      asm.shr(:rax, 1)
      asm.sub(:rcx, 1)
      asm.imul(:rax, :rcx)
      asm.or(:rax, 1)

      push_stack(:rax)
    end

    def compile_insn(insn)
      visitor_method = :"compile_#{insn.name}"
      raise CantCompile unless respond_to?(visitor_method)

      @disasm << "# #{insn.to_s}\n"

      label = labels.fetch(insn.pos)
      @asm.bind(label)

      send(visitor_method, insn)
    end

    ALLOWLIST = %w[
      double fib test
    ]

    def compile
      label = iseq.body.location.label
      pp iseq.body.location
      if ALLOWLIST.include? label
        puts "JIT compiling #{label.inspect}@#{iseq_ptr}"
        pp insns
        pp insns.map(&:name).sort.uniq

        compile_entry
        insns.each do |insn|
          compile_insn(insn)
        rescue CantCompile
          puts "failed to compile #{insn.inspect}"
          return nil
        end

        puts "=== ISEQ: #{label.inspect}@#{iseq_ptr}"
        puts @disasm
        puts "==="

        @code.to_ptr
      end
    end
  end
end
