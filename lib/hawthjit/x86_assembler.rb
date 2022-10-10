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
        p insn
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

    {
      add: :jo,
      sub: :jc,
      imul: :jo # FIXME: probably wrong
    }.each do |name, jump|
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

    def ir_push_frame(insn)
      iseq, flags, self_, specval, cref_or_me, pc = inputs(insn)

      next_cfp = -> (member) do
        offset = CFPStruct.offset(member) - CFPStruct.sizeof
        X86.qword_ptr(CFP, offset)
      end

      asm.mov(:rax, cref_or_me)
      asm.mov(sp_ptr(0), :rax)
      block_handler = 0
      asm.mov(sp_ptr(1), block_handler)
      asm.mov(sp_ptr(2), flags)

      asm.mov(:rax, pc)
      asm.mov(next_cfp[:pc], :rax)
      asm.mov(:rax, iseq)
      asm.mov(next_cfp[:iseq], :rax)
      asm.mov(next_cfp[:block_code], 0)
      asm.mov(next_cfp[:jit_return], 0)

      asm.lea(:rax, sp_ptr(3))
      asm.mov(next_cfp[:sp], :rax)
      asm.mov(next_cfp[:__bp__], :rax)
      asm.sub(:rax, 8)
      asm.mov(next_cfp[:ep], :rax)

      asm.lea(:rax, X86.qword_ptr(CFP, -CFPStruct.sizeof))
      asm.mov(EC[:cfp], :rax)
    end

    def cast(opnd)
      case opnd
      when IR::Label
        x86_labels[opnd]
      else
        opnd
      end
    end

    def ir_call_jit_func(insn)
      ptr = cast(input(insn))
      raise "call to null pointer" if ptr == 0

      GP_REGS.each do |reg|
        asm.push(reg)
      end

      callee_cfp = X86.qword_ptr(CFP, -CFPStruct.sizeof)
      asm.lea(:rsi, callee_cfp)
      asm.mov(:rdi, EC)

      asm.call(ptr)
      GP_REGS.reverse_each do |reg|
        asm.pop(reg)
      end

      # FIXME: side exit if Qnil

      asm.mov(out(insn), :rax)
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
      scratch = :rax
      asm.mov(scratch, input(insn))
      asm.mov(CFP[:pc], scratch)
    end

    def ir_update_sp(insn)
      scratch = :rax

      input_sp = input(insn)
      #raise "bad sp #{input_sp} != #{@sp}" unless input(insn) == @sp

      asm.lea(scratch, sp_ptr)
      asm.mov(CFP[:sp], scratch)
    end

    def sp_ptr(offset = 0)
      X86.ptr(BP, (@sp + offset) * 8, 8)
    end

    def ir_vm_push(insn)
      asm.mov sp_ptr, input(insn)
      @sp += 1
      puts "sp = #{@sp}"
    end

    def ir_vm_pop(insn)
      @sp -= 1
      asm.mov out(insn), sp_ptr
      puts "sp = #{@sp}"
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
