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
        @pc + len * 8
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

    attr_reader :asm, :ctx
    def initialize(iseq)
      @iseq = iseq
      @ctx = Context.new
      @ir = IR.new
      @asm = @ir.assembler
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

    def compile_entry
      @entry_label = asm.label("entry")
      asm.bind(@entry_label)
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
      ret = pop_stack

      asm.pop_frame

      asm.jit_return ret
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

    def compile_jump(insn)
      target_insn = labels.fetch(insn.pos + insn.len + insn[:dst])
      asm.br target_insn
    end

    class Context
    end

    def push_stack(opnd)
      asm.vm_push(opnd)
    end

    def pop_stack
      asm.vm_pop
    end

    def compile_opt_minus(insn)
      b = pop_stack
      a = pop_stack

      asm.guard_fixnum(a)
      asm.guard_fixnum(b)

      result = asm.sub_guard_overflow(a, b)
      result = asm.add(result, 1) # re-add tag

      push_stack(result)
    end

    def compile_opt_plus(insn)
      b = pop_stack
      a = pop_stack

      asm.guard_fixnum(a)
      asm.guard_fixnum(b)

      result = asm.add_guard_overflow(a, asm.sub(b, 1))

      push_stack(result)
    end

    # From vm_core.h
    VM_FRAME_MAGIC_METHOD = 0x11110001
    VM_ENV_FLAG_LOCAL     = 0x0002

    def compile_opt_send_without_block(insn)
      ci, cc = insn[:cd]

      # FIXME: check that ci is "simple"

      # FIXME: guard for cc.klass

      cme = cc.cc.cme_

      if cme.def.type != C.VM_METHOD_TYPE_ISEQ
        raise CantCompile
      end

      iseq = cme.def.body.iseq.iseqptr

      callee_pc = iseq.body.iseq_encoded.to_i

      self_ = asm.load(asm.cfp, CFPStruct.offset(:self), 8)

      push_frame(
        flags: VM_FRAME_MAGIC_METHOD | VM_ENV_FLAG_LOCAL,
        iseq: iseq.to_i,
        self_: self_,
        specval: 0,
        cref_or_me: cme.to_i,
        pc: callee_pc,
      )

      jit_func = iseq.body.jit_func

      if @iseq.to_i == iseq.to_i
        # self recursive
        jit_func = @entry_label
      end

      if jit_func == 0
        # Side exit _into_ the next control frame

        ci.argc.times do
          asm.vm_pop
        end
        asm.vm_pop

        asm.update_pc insn.next_pc
        asm.update_sp 99999 # FIXME
        asm.side_exit

        asm.vm_push(Qnil)
        return :stop
      else
        # Call the previously compiled JIT func
        ret = asm.call_jit_func(jit_func)

        # pop arguments in the caller framt
        ci.argc.times do
          asm.vm_pop
        end
        asm.vm_pop # self

        asm.vm_push(ret)
      end
    end

    def push_frame iseq:, flags:, self_:, specval:, cref_or_me:, pc:
      asm.push_frame(iseq, flags, self_, specval, cref_or_me, pc)
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

    def apply_passes(ir)
      Pass.apply_all(ir)
    end

    def compile
      label = iseq.body.location.label
      pp iseq.body.location
      if ALLOWLIST.include? label
        puts "JIT compiling #{label.inspect}@#{iseq_ptr}"
        pp insns
        pp insns.map(&:name).sort.uniq

        compile_entry
        insns.each do |insn|
          ret = compile_insn(insn)
          break if :stop == ret
        rescue CantCompile
          puts "failed to compile #{insn.inspect}"
          return nil
        end

        ir = apply_passes(@ir)

        code = ir.to_x86

        puts "=== ISEQ: #{label.inspect}@#{iseq_ptr}"
        puts code.logger
        puts "==="

        code.to_ptr
      end
    end

    # Compile and set jit_func
    def compile!
      ptr = compile
      iseq.body.jit_func = ptr
      ptr
    end
  end
end
