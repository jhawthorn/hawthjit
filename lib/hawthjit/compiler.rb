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

        def empty?
          !(@cc.klass && @cc.cme_)
        end

        def inspect
          if !empty?
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
      attr_reader :insn, :operands, :pos, :pc
      def initialize(insn, operands, pos, pc)
        @insn = insn
        @operands = operands
        @pos = pos
        @pc = pc
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
      @asm = nil
    end

    def insns
      return @insns if @insns

      insns = []
      pos = 0
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
        insns << Insn.new(insn, operands, pos, pc)
        pos += insn.len
      end

      @insns = insns
    end

    # def labels
    #   return @labels if @labels

    #   @labels = insns.map do |insn|
    #     [insn.pos, @asm.label("pos_#{insn.pos}")]
    #   end.to_h
    # end

    def blocks
      return @blocks if @blocks

      @blocks = insns.map do |insn|
        [insn.pos, @ir.new_block("pos_#{insn.pos}")]
      end.to_h
    end

    CantCompile = Class.new(StandardError)

    def compile_entry
      @entry_block = @ir.entry
      with_block(@entry_block) do
        asm.jit_prelude
        asm.br blocks.fetch(0)
      end
    end

    def with_block(block)
      old_asm, old_block = @asm, @current_block
      @current_block = block
      @asm = IR::Assembler.new(block)
      yield
      @asm, @current_block = old_asm, old_block
    end

    def compile_exit
    end

    def compile_nop(insn)
      asm.nop # actually needed?
    end

    def compile_get_ep(level)
      # ep = cfp->ep
      cfp = asm.cfp
      ep = asm.load(cfp, CFPStruct.offset(:ep), 8)
      level.times do
        ep = asm.and(asm.load(ep, -8, 8), ~3)
      end
      ep
    end

    def compile_getlocal_generic(idx, level)
      local_offset = -idx * 8

      ep = compile_get_ep(level)
      val = asm.load(ep, local_offset)

      push_stack(val)
    end

    def compile_getlocal_WC_0(insn)
      compile_getlocal_generic(insn[:idx], 0)
    end

    def compile_getlocal_WC_1(insn)
      compile_getlocal_generic(insn[:idx], 1)
    end

    def compile_setlocal_generic(idx, level)
      local_offset = -idx * 8

      ep = compile_get_ep(level)
      val = asm.load(ep, local_offset)

      val = pop_stack
      asm.store(ep, -idx * 8, 8, val)
    end

    def compile_setlocal_WC_0(insn)
      compile_setlocal_generic(insn[:idx], 0)
    end

    def compile_setlocal_WC_1(insn)
      compile_setlocal_generic(insn[:idx], 1)
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

    def compile_putobject_INT2FIX_0_(insn)
      push_stack(Fiddle.dlwrap(0))
    end

    def compile_putobject_INT2FIX_1_(insn)
      push_stack(Fiddle.dlwrap(1))
    end

    def compile_dup(insn)
      val = pop_stack
      push_stack val
      push_stack val
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

      target_insn = blocks.fetch(insn.pos + insn.len + insn[:dst])
      next_insn   = blocks.fetch(insn.pos + insn.len)

      asm.br_cond cond, next_insn, target_insn
    end

    def compile_jump(insn)
      target_insn = blocks.fetch(insn.pos + insn.len + insn[:dst])
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

    VM_ENV_DATA_INDEX_SPECVAL = -1

    # From vm_core.h
    VM_FRAME_MAGIC_METHOD = 0x11110001
    VM_ENV_FLAG_LOCAL     = 0x0002

    def compile_opt_send_without_block(insn)
      ci, cc = insn[:cd]

      # FIXME: check that ci is "simple"

      # FIXME: guard for cc.klass

      raise CantCompile, "empty CC" if cc.empty?

      cme = cc.cc.cme_

      if cme.def.type != C.VM_METHOD_TYPE_ISEQ
        raise CantCompile, "not ISEQ"
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
        jit_func = @entry_block
      end

      if jit_func == 0
        # Side exit _into_ the next control frame

        ci.argc.times do
          asm.vm_pop
        end
        asm.vm_pop

        asm.update_pc insn.next_pc
        asm.update_sp
        asm.side_exit

        asm.vm_push(Qnil)
        return :stop
      else
        raise if jit_func.nil?

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

      block = blocks.fetch(insn.pos)

      with_block(block) do
        asm.comment "YARV: #{insn}"

        asm.update_pc insn.pc
        asm.update_sp

        send(visitor_method, insn)

        unless @current_block.insns.any?(&:branch_or_return?)
          next_block = blocks.fetch(insn.pos + insn.len)
          asm.br next_block
        end
      end
    end

    def apply_passes(ir)
      Pass.apply_all(ir)
    end

    def compile
      label = iseq.body.location.label
      STDERR.puts "JIT compiling #{label.inspect}@#{iseq_ptr}"
      pp insns
      pp insns.map(&:name).sort.uniq

      compile_entry
      insns.each do |insn|
        ret = compile_insn(insn)
        break if :stop == ret
      rescue CantCompile => e
        STDERR.puts "failed to compile #{insn.inspect}: #{e.message}"
        return nil
      end

      ir = apply_passes(@ir)

      code = ir.to_x86

      puts "=== ISEQ: #{label.inspect}@#{iseq_ptr}"
      puts code.logger
      puts "==="
      STDOUT.flush

      STATS.increment(:compile_success)

      code.to_ptr
    end

    # Compile and set jit_func
    def compile!
      ptr = compile
      iseq.body.jit_func = ptr
      ptr
    end
  end
end
