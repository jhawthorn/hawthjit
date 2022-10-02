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

    attr_reader :asm
    def initialize(ir)
      @code = AsmJIT::CodeHolder.new
      @disasm = +""
      @code.logger = @disasm
      @asm = X86::Assembler.new(@code)

      @ir = ir
    end

    def allocate_regs!
      lifetimes = {}

      @ir.insns.each_with_index.reverse_each do |insn, idx|
        insn.inputs.grep(IR::OutOpnd).each do |out|
          lifetimes[out] ||= idx
        end

        # Never used, allocate a register for scratch anyways ¯\_(ツ)_/¯
        insn.outputs.each do |output|
          lifetimes[output] ||= idx
        end
      end

      available = GP_REGS.dup
      live = []
      @regs = {}

      #p lifetimes

      @ir.insns.each_with_index do |insn, idx|
        outs = insn.outputs
        outs.each do |out|
          @regs[out] = available.shift or raise "out of regs"
          live << out
        end

        live.reject! do |opnd|
          if lifetimes[opnd] <= idx
            available.unshift(@regs[opnd])
            true
          else
            false
          end
        end
      end

      #p @regs
    end

    def x86_labels
      @x86_labels ||=
        Hash.new do |h, k|
          h[k] = asm.new_label
        end
    end

    def compile
      allocate_regs!

      @sp = 0

      @ir.insns.each do |insn|
        op = insn.opcode
        p op
        @disasm << "# #{insn}\n" unless op == :comment
        send("ir_#{op}", insn)
      end

      side_exit_label

      if @side_exit_label
        asm.bind(side_exit_label)
        comment "side exit"

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

    %w[add sub imul].each do |name|
      define_method(:"ir_#{name}_guard_overflow") do |insn|
        out = out(insn)
        asm.mov(out, input(insn, 0))
        asm.emit(name.to_s, out, input(insn, 1))
        asm.jo side_exit_label
      end
    end

    def ir_update_cfp(insn)
      asm.mov(CFP, input(insn))
      ec_cfp_ptr = EC[:cfp]
      asm.mov(ec_cfp_ptr, CFP)
    end

    def ir_breakpoint(insn)
      asm.int3
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

    def ir_cmp_s(insn)
      a, op, b = inputs(insn)

      asm.xor(:rax, :rax)
      asm.cmp(a, b)
      asm.emit("set#{condition_code(:signed, op)}", :al)
      asm.mov(out(insn), :rax)
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

      label_if = x86_labels[label_if]
      label_else = x86_labels[label_else]

      asm.test cond, cond
      asm.jnz label_if
      asm.jmp label_else
    end

    def ir_update_pc(insn)
      # FIXME: use a scratch reg if available
      scratch = BP
      asm.mov(scratch, input(insn))
      asm.mov(CFP[:pc], scratch)

      # Restore BP
      set_bp_from_cfp
    end

    def ir_update_sp(insn)
      # FIXME: use a scratch reg if available
      scratch = BP
      relative_sp = input(insn)
      asm.add(BP, relative_sp * 8)
      asm.mov(CFP[:sp], BP)

      # Restore BP
      set_bp_from_cfp
    end

    def ir_vm_push(insn)
      mem = X86.ptr(BP, @sp * 8, 8)
      @sp += 1

      asm.mov mem, input(insn)
    end

    def ir_vm_pop(insn)
      @sp -= 1
      mem = X86.ptr(BP, @sp * 8, 8)

      asm.mov out(insn), mem
    end

    def ir_guard_fixnum(insn)
      reg = input(insn)
      asm.test reg, 1
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

    def out(insn)
      @regs.fetch(insn.output)
    end

    def inputs(insn)
      insn.inputs.size.times.map do |i|
        input(insn, i)
      end
    end

    def input(insn, index=0)
      x = insn.inputs[index]
      case x
      when IR::OutOpnd
        @regs.fetch(x)
      else
        x
      end
    end
  end
end
