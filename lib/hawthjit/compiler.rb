require "hawthjit/ir"

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

    #def labels
    #  return @labels if @labels

    #  @labels = insns.map do |insn|
    #    [insn.pos, @asm.new_label]
    #  end.to_h
    #end

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
      asm.mov(:rax, CFP[:self])
      push_stack(:rax)
    end

    def compile_leave(insn)
      asm.update_cfp asm.add(asm.cfp, CFPStruct.sizeof)

      asm.jit_suffix
      asm.ret pop_stack
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

    #def compile_branchunless(insn)
    #  pop_stack(:rax)
    #  asm.cmp(:rax, Qnil)

    #  target_label = labels.fetch(insn.pos + insn.len + insn[:dst])
    #  asm.jle(target_label)
    #end

    class Context
      def initialize
        @stack = []
      end

      def push(val)
        @stack << val
        nil
      end

      def pop
        @stack.pop
      end

      def popn(n)
        n.times.map do
          pop
        end.reverse
      end

      def release_scratch
      end
    end

    def push_stack(opnd)
      ctx.push(opnd)
    end

    def pop_stack
      ctx.pop
    end

    def compile_opt_minus(insn)
      pop_stack(:rcx)
      pop_stack(:rax)

      asm.sub(:rax, :rcx)
      asm.or(:rax, 1)

      push_stack(:rax)
    end

    def compile_opt_plus(insn)
      # FIXME: assumes fixnum + fixnum

      a, b = ctx.popn(2)

      result = asm.add(a, asm.sub(b, 1))

      ctx.push(result)
    end

    def compile_opt_send_without_block(insn)
      @asm.int(3)
    end

    def compile_opt_mult(insn)
      # FIXME: Assumes fixnum * fixnum
      a, b = ctx.popn(2)

      result =
        asm.or(
          asm.imul(
            asm.shr(a, 1),
            asm.sub(b, 1)),
        1)

      ctx.push(result)
    end

    def compile_insn(insn)
      visitor_method = :"compile_#{insn.name}"
      raise CantCompile unless respond_to?(visitor_method)

      asm.comment "YARV: #{insn}"

      #label = labels.fetch(insn.pos)
      #@asm.bind(label)

      send(visitor_method, insn)

      @ctx.release_scratch
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

        code = @asm.to_x86

        puts "=== ISEQ: #{label.inspect}@#{iseq_ptr}"
        puts code.logger
        puts "==="

        code.to_ptr
      end
    end
  end
end
