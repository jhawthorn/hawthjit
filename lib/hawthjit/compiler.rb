require "hawthjit/ir"

module HawthJit
  class Compiler
    class Operand
      attr_reader :raw_value

      def initialize(decl, raw_value)
        @decl = decl
        @raw_value = raw_value
      end

      def name
        @decl[:name]
      end

      def type
        @decl[:type]
      end

      def value
        case type
        when "CALL_DATA"
          cd = C.CALL_DATA.new(raw_value)
          ci = CallInfo.new cd.ci
          cc = CallCache.new cd.cc
          [ci, cc]
        else
          raw_value
        end
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
        attr_reader :cc

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
          value.inspect
        else
          "(#{type})#{value}"
        end
      end
    end

    class Insn
      attr_reader :insn, :operands, :pos, :pc, :relative_sp
      def initialize(insn, operands, pos, pc, relative_sp)
        @insn = insn
        @operands = operands
        @pos = pos
        @pc = pc
        @relative_sp = relative_sp
      end

      def next_pc
        @pc + operands.size * 8
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
    attr_reader :asm, :ctx
    def initialize(iseq)
      @iseq = iseq
      @ctx = Context.new
      @asm = IR::Assembler.new
    end

    def insns
      return @insns if @insns

      insns = []
      pos = 0
      relative_sp = 0
      while pos < body.iseq_size
        insn = INSNS.fetch(C.rb_vm_insn_decode(body.iseq_encoded[pos]))
        sp_inc = C.mjit_call_attribute_sp_inc(insn.bin, body.iseq_encoded + pos + 1)
        operands = insn.opes.map.with_index do |type, i|
          Operand.new(
            type,
            body.iseq_encoded[pos + i + 1]
          )
        end
        pc = body.iseq_encoded.to_i + pos * 8
        insns << Insn.new(insn, operands, pos, pc, relative_sp)
        relative_sp += sp_inc
        pos += insn.len
      end

      @insns = insns
    end

    def labels
      return @labels if @labels

      @labels = insns.map do |insn|
        [insn.pos, @asm.label("pos_#{insn.pos}")]
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
    CType = RubyVM::MJIT.const_get(:CType)

    class AsmStruct
      Member = Struct.new(:offset, :bytesize)
      def self.from_mjit(struct)
        members = struct.new(0).instance_variable_get(:@members)
        members = members.transform_values do |type, offset|
          size =
            case type
            when CType::Stub
              type.size
            when Class
              if CPointer::Pointer > type
                8
              elsif CPointer::Struct > type
                type.sizeof
              elsif CPointer::Immediate > type
                type.size
              else
                raise "FIXME: unsupported type: #{type}"
              end
            end
          Member.new(offset / 8, size)
        end
        Class.new(AsmStruct) do
          define_singleton_method(:members) { members }
          define_method(:members) { members }
          define_singleton_method(:sizeof) { struct.sizeof }
        end
      end

      def initialize(reg)
        @reg = reg
      end

      def self.member(name)
        members.fetch(name)
      end

      def self.offset(name)
        member(name).offset
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
      asm.jit_prelude
    end

    def compile_exit
    end

    def compile_getlocal_WC_0(insn)
      # ep = cfp->ep
      cfp = asm.cfp
      ep = asm.load(cfp, CFPStruct.offset(:ep), 8)

      local0_offset = -insn[:idx] * 8

      val = asm.load(ep, local0_offset)

      push_stack(val)
    end

    def compile_putself(insn)
      cfp = asm.cfp
      self_ = asm.load(cfp, CFPStruct.offset(:self), 8)
      push_stack self_
    end

    def compile_leave(insn)
      asm.update_cfp asm.add(asm.cfp, CFPStruct.sizeof)

      asm.jit_return pop_stack
    end

    def compile_putobject(insn)
      value = insn.operands[0].value
      push_stack(value)
    end

    def compile_putobject_INT2FIX_1_(insn)
      push_stack(Fiddle.dlwrap(1))
    end

    def compile_opt_lt(insn)
      b = pop_stack
      a = pop_stack

      asm.guard_fixnum b
      asm.guard_fixnum a

      cond = asm.cmp_s(a, :<, b)
      val = asm.rbool(cond)

      push_stack val
    end

    def compile_branchunless(insn)
      val = pop_stack
      cond = asm.rtest(val)

      target_insn = labels.fetch(insn.pos + insn.len + insn[:dst])
      next_insn   = labels.fetch(insn.pos + insn.len)

      asm.br_cond cond, next_insn, target_insn
    end

    class Context
    end

    def push_stack(opnd)
      asm.vm_push(opnd)
    end

    def pop_stack
      asm.vm_pop
    end

    #def compile_opt_minus(insn)
    #  pop_stack(:rcx)
    #  pop_stack(:rax)

    #  asm.sub(:rax, :rcx)
    #  asm.or(:rax, 1)

    #  push_stack(:rax)
    #end

    def compile_opt_plus(insn)
      a = pop_stack
      b = pop_stack

      asm.guard_fixnum(a)
      asm.guard_fixnum(b)

      result = asm.add_guard_overflow(a, asm.sub(b, 1))

      push_stack(result)
    end

    def compile_opt_send_without_block(insn)
      ci, cc = insn[:cd]

      asm.side_exit

      asm.vm_pop
      asm.vm_pop

      # FIXME: check that ci is "simple"

      # FIXME: guard for cc.klass

      cme = cc.cc.cme_
      # FIXME: check that cme.def.type is ISEQ

      iseq = cme.def.body.iseq.iseqptr

      asm.vm_push(Qnil)
    end

    def compile_opt_mult(insn)
      a = pop_stack
      b = pop_stack

      asm.guard_fixnum(a)
      asm.guard_fixnum(b)

      result =
        asm.or(
          asm.imul_guard_overflow(
            asm.shr(a, 1),
            asm.sub(b, 1)),
        1)

      push_stack result
    end

    def compile_insn(insn)
      visitor_method = :"compile_#{insn.name}"
      raise CantCompile unless respond_to?(visitor_method)

      asm.comment "YARV: #{insn}"

      label = labels.fetch(insn.pos)
      @asm.bind(label)

      asm.update_pc insn.pc
      asm.update_sp insn.relative_sp

      send(visitor_method, insn)
    end

    ALLOWLIST = %w[
      double fib test foo
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

        code = @asm.to_x86

        puts "=== ISEQ: #{label.inspect}@#{iseq_ptr}"
        puts code.logger
        puts "==="

        code.to_ptr
      end
    end
  end
end
