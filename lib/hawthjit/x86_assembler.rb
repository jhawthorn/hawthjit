module HawthJit
  class X86Assembler
    X86 = AsmJIT::X86

    # Callee-saved registers
    # We make the same choices as YJIT
    BP = X86::REGISTERS[:rbx]
    CFP = X86::REGISTERS[:r13]
    EC = X86::REGISTERS[:r12]

    SCRATCH_REGS = [:rax, :rcx]
    GP_REGS = [:rdx, :rsi, :rdi, :r8, :r9, :r10, :r11]
    C_ARG_REGS = %i[rdi rsi rdx rcx r8 r9]
    CALLER_SAVE = %i[rax rcx rdx rdi rsi rsp r8 r9 r10 r11]
    CALLEE_SAVE = %i[rbx rbp r12 r13 r14 r15]

    attr_reader :asm
    attr_reader :disasm

    def initialize(ir)
      @code = AsmJIT::CodeHolder.new
      @disasm = +""
      @code.logger = @disasm
      @asm = X86::Assembler.new(@code)

      @ir = ir
    end

    def allocate_regs!
      @reg_allocation = Pass::X86AllocateRegisters.new(@ir)
      @reg_allocation.process

      @regs = @reg_allocation.assigns.freeze

      @ir.blocks.each do |block|
        block.insns.each_with_index do |insn, idx|
          if insn.name =~ /call/
            # FIXME
            in_use = GP_REGS - insn.outputs
            insn.props[:preserve_regs] = in_use
            #insn.props[:preserve_regs] = live - insn.outputs
          end
        end
      end

      #p @regs
    end

    def x86_labels
      @x86_labels ||=
        Hash.new do |h, k|
          raise TypeError, "expected IR::BlockRef, got #{k.inspect}" unless IR::BlockRef === k
          h[k] = asm.new_label
        end
    end

    def compile
      allocate_regs!

      @ir.blocks.each do |block|
        asm.bind(x86_labels[block.ref])

        block.insns.each do |insn|
          op = insn.opcode
          p insn
          @disasm << "# #{insn}\n" unless op == :comment
          send("ir_#{op}", insn)
        end
      end

      #side_exit_label

      if @side_exit_label
        asm.bind(side_exit_label)
        comment "side exit"

        asm.mov(:rax, STATS.addr_for(:side_exits))
        asm.add(X86.qword_ptr(:rax, 0), 1)

        jit_suffix
        asm.mov :rax, Qundef
        asm.ret
      end

      @code
    end

    def side_exit_label
      @side_exit_label ||= asm.new_label
    end

    def comment(text)
      @disasm << "# #{text}\n"
    end

    def ir_comment(insn)
      comment insn.inputs[0]
    end

    def ir_cfp(insn)
      asm.mov out(insn), CFP
    end

    def ir_load(insn)
      offset = insn.inputs[1] || 0
      size = insn.inputs[2] || 8
      mem = X86.ptr(input(insn), offset, size)
      asm.mov out(insn), mem
    end

    def ir_store(insn)
      inputs = insn.inputs.dup
      value = inputs.pop
      offset = inputs[1] || 0
      size = inputs[2] || 8

      mem = X86.ptr(input(insn), offset, size)
      asm.mov mem, cast_input(value)
    end

    BIN_OPS = %i[
      add
      sub
      shr
      imul

      or xor and
    ]

    BIN_OPS.each do |name|
      define_method(:"ir_#{name}") do |insn|
        out = out(insn)
        asm.mov(out, input(insn, 0))
        asm.emit(name.to_s, out, input(insn, 1))
      end
    end

    {
      add: :o,
      sub: :c,
      imul: :o # FIXME: probably wrong
    }.each do |name, cc|
      define_method(:"ir_#{name}_guard_overflow") do |insn|
        out = out(insn)
        asm.mov(out, input(insn, 0))
        asm.emit(name.to_s, out, input(insn, 1))
        asm.jo side_exit_label
      end

      define_method(:"ir_#{name}_with_overflow") do |insn|
        value_out = out(insn, 0)
        overflow_out = out(insn, 1)

        p(overflow_out:, cc:)
        emit_set_cc(overflow_out, cc) do
          asm.mov(value_out, input(insn, 0))
          asm.emit(name.to_s, value_out, input(insn, 1))
        end
      end
    end

    def ir_pop_frame(insn)
      asm.add(CFP, CFPStruct.sizeof)
      ec_cfp_ptr = EC[:cfp]
      asm.mov(ec_cfp_ptr, CFP)
    end

    def ir_push_frame(insn)
      iseq, flags, self_, specval, cref_or_me, pc = inputs(insn)

      next_cfp = -> (member) do
        offset = CFPStruct.offset(member) - CFPStruct.sizeof
        X86.qword_ptr(CFP, offset)
      end

      sp = insn.props[:sp]

      asm.mov(:rax, cref_or_me)
      asm.mov(sp_ptr(sp + 0), :rax)
      block_handler = 0
      asm.mov(sp_ptr(sp + 1), block_handler)
      asm.mov(sp_ptr(sp + 2), flags)

      asm.mov(:rax, pc)
      asm.mov(next_cfp[:pc], :rax)
      asm.mov(:rax, iseq)
      asm.mov(next_cfp[:iseq], :rax)
      asm.mov(next_cfp[:block_code], 0)
      asm.mov(next_cfp[:jit_return], 0)

      asm.lea(:rax, sp_ptr(sp + 3))
      asm.mov(next_cfp[:sp], :rax)
      asm.mov(next_cfp[:__bp__], :rax)
      asm.sub(:rax, 8)
      asm.mov(next_cfp[:ep], :rax)

      asm.lea(:rax, X86.qword_ptr(CFP, -CFPStruct.sizeof))
      asm.mov(EC[:cfp], :rax)
    end

    def preserve_regs(insn)
      preserve_regs = insn.props[:preserve_regs]
      #preserve_regs.map! { @regs.fetch(_1) }

      preserve_regs.each do |reg|
        asm.push(reg)
      end

      yield

      preserve_regs.reverse_each do |reg|
        asm.pop(reg)
      end
    end

    def ir_c_call(insn)
      ptr = insn.inputs[0]

      preserve_regs(insn) do
        # FIXME: this can clobber the regs in use :(
        inputs(insn)[1..].each_with_index do |var, i|
          reg = C_ARG_REGS[i] or raise("too many args")

          asm.mov(reg, var)
        end

        asm.call(ptr)
      end

      asm.mov(out(insn), :rax)
    end

    def ir_call_jit_func(insn)
      ptr = input(insn)

      if IR::BlockRef === ptr
        ptr = x86_labels[ptr]
      end

      raise "call to null pointer" if ptr == 0
      raise "call to nil pointer??" if ptr.nil?

      preserve_regs(insn) do
        callee_cfp = X86.qword_ptr(CFP, -CFPStruct.sizeof)
        asm.lea(:rsi, callee_cfp)
        asm.mov(:rdi, EC)

        asm.call(ptr)
      end

      asm.mov(out(insn), :rax)
      # FIXME: side exit if Qnil
    end

    def ir_breakpoint(insn)
      asm.int3
    end

    def ir_assign(insn)
      asm.mov(out(insn), input(insn))
    end

    def condition_code(signedness, op)
      if signedness == :unsigned
        raise "not implemented: #{op.inspect}"
      elsif signedness == :signed
        case op
        when :<  then "l"  # less than
        when :<= then "le" # less than or equal
        when :>  then "g"  # greater than
        when :>= then "ge" # greater than or equal
        else
          raise "not implemented: #{cond.inspect}"
        end
      else
        raise ArgumentError, "bad signedness: #{signedness.inspect}"
      end
    end

    def invert_cc(cc)
      case cc
      when "l" then "ge"
      when "ge" then "l"
      when "le" then "g"
      when "g" then "le"

      when "z", "e" then "nz"
      when "nz", "ne" then "z"
      else
        raise "not implemented: #{cc.inspect}"
      end
    end

    #def next_insn_pos
    #  pos = @pos + 1
    #  while pos < @ir.insns.size && IR::COMMENT === @ir.insns[pos]
    #    pos += 1
    #  end
    #  pos
    #end

    #def next_insn
    #  @ir.insns[next_insn_pos]
    #end

    def emit_br_cc(cc, label_if, label_else)
      x86_label_if = x86_labels[label_if]
      x86_label_else = x86_labels[label_else]

      #if (bind_insn = next_insn)&.name == :bind
      #  if bind_insn.input == label_if
      #    asm.emit "j#{invert_cc(cc)}", x86_label_else
      #    return
      #  end

      #  if bind_insn.input == label_else
      #    asm.emit "j#{cc}", x86_label_if
      #    return
      #  end
      #end

      # General case: two jumps
      asm.emit "j#{cc}", x86_label_if
      asm.jmp x86_label_else
    end

    def ir_cmp_s(insn)
      cmp_insn = insn
      a, op, b = inputs(insn)
      cc = condition_code(:signed, op)

      #if next_insn.name == :br_cond && next_insn.inputs[0] == cmp_insn.output
      #  br_insn = next_insn
      #  @pos = next_insn_pos

      #  cond, label_if, label_else = inputs(br_insn)

      #  @disasm << "# #{br_insn} (merged)\n"
      #  asm.cmp(a, b)
      #  emit_br_cc(cc, label_if, label_else)
      #else
        asm.xor(:rax, :rax)
        asm.cmp(a, b)
        asm.emit("set#{cc}", :al)
        asm.mov(out(insn), :rax)
      #end
    end

    def ir_cmp_u(insn)
      comment "fixme"
      asm.int3
    end

    def ir_rtest(insn)
      val = input(insn)
      output = out(insn)

      asm.xor(:rax, :rax)
      asm.test(val, ~Qnil)
      asm.setnz(:al)
      asm.mov(output, :rax)
    end

    def ir_rbool(insn)
      val = input(insn)
      output = out(insn)
      scratch = :rax

      asm.test(val, val)
      asm.mov(output, Qfalse)
      asm.mov(scratch, Qtrue)
      asm.cmovne(output, scratch)
    end

    def ir_bind(insn)
      label = input(insn)
      asm.bind x86_labels[label]
    end

    def ir_br_cond(insn)
      cond, label_if, label_else = inputs(insn)

      asm.test cond, cond
      emit_br_cc("nz", label_if, label_else)
    end

    # Unconditional branch
    def ir_br(insn)
      label = input(insn)
      x86_label = x86_labels[label]
      asm.jmp x86_label
    end

    def ir_update_pc(insn)
      scratch = :rax
      asm.mov(scratch, input(insn))
      asm.mov(CFP[:pc], scratch)
    end

    def ir_update_sp(insn)
      scratch = :rax

      input_sp = input(insn)

      asm.lea(scratch, sp_ptr(insn.props.fetch(:sp)))
      asm.mov(CFP[:sp], scratch)
    end

    def sp_ptr(offset)
      X86.ptr(BP, offset * 8, 8)
    end

    def ir_vm_push(insn)
      asm.mov sp_ptr(insn.props[:sp]), input(insn)
    end

    def ir_vm_pop(insn)
      if insn.outputs.empty?
      else
        asm.mov out(insn), sp_ptr(insn.props.fetch(:sp))
      end
    end

    def emit_set_cc(out, cc)
      asm.xor(:rax, :rax)
      yield
      asm.emit("set#{cc}", :al)
      asm.mov(out, :rax)
    end

    def ir_test_fixnum(insn)
      reg = input(insn)
      emit_set_cc(out(insn), "nz") do
        asm.test reg, 1
      end
    end

    def ir_guard_not(insn)
      reg = input(insn)
      asm.test reg, reg
      asm.jnz side_exit_label
    end

    def ir_guard(insn)
      reg = input(insn)
      asm.test reg, reg
      asm.jz side_exit_label
    end

    def ir_side_exit(insn)
      asm.jmp side_exit_label
    end

    def set_bp_from_cfp
      asm.mov(BP, CFP[:__bp__])
    end

    def ir_jit_prelude(insn)
      # Save callee-saved regs
      asm.push(BP)
      asm.push(CFP)
      asm.push(EC)

      asm.mov(CFP, :rsi)
      asm.mov(EC, :rdi)
      set_bp_from_cfp
    end

    def jit_suffix
      asm.pop(EC)
      asm.pop(CFP)
      asm.pop(BP)
    end

    def ir_jit_return(insn)
      jit_suffix

      asm.mov :rax, input(insn)
      asm.ret
    end

    def out(insn, n=nil)
      if n
        @regs.fetch(insn.outputs[n] || raise)
      else
        @regs.fetch(insn.output)
      end
    end

    def inputs(insn)
      insn.inputs.size.times.map do |i|
        input(insn, i)
      end
    end

    def cast_input(x)
      case x
      when IR::OutOpnd
        @regs.fetch(x)
      else
        x
      end
    end

    def input(insn, index=0)
      x = insn.inputs[index]
      cast_input(x)
    end
  end
end
