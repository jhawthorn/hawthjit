module HawthJit
  class X86Assembler
    X86 = AsmJIT::X86

    # Callee-saved registers
    # We make the same choices as YJIT
    SP = X86::REGISTERS[:rbx]
    CFP = X86::REGISTERS[:r13]
    EC = X86::REGISTERS[:r12]

    GP_REGS = [:rax, :rcx, :rsi, :rdi, :r8, :r9]

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
        lifetimes[insn.output] ||= idx
      end

      available = GP_REGS.dup
      live = []
      @regs = {}

      #p lifetimes

      @ir.insns.each_with_index do |insn, idx|
        out = insn.output
        @regs[out] = available.shift or raise "out of regs"
        live << out

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

    def compile
      allocate_regs!

      @ir.insns.each do |insn|
        op = insn.opcode
        @disasm << "# #{insn}\n" unless op == :comment
        send("ir_#{op}", insn)
      end

      @code
    end

    def ir_comment(insn)
      @disasm << "# #{insn.inputs[0]}\n"
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
      or
    ]

    BIN_OPS.each do |name|
      define_method(:"ir_#{name}") do |insn|
        out = out(insn)
        asm.mov(out, input(insn, 0))
        asm.emit(name.to_s, out, input(insn, 1))
      end
    end

    def ir_update_cfp(insn)
      asm.mov(CFP, input(insn))
      ec_cfp_ptr = EC[:cfp]
      asm.mov(ec_cfp_ptr, CFP)
    end

    def ir_ret(insn)
      asm.mov :rax, input(insn)
      asm.ret
    end

    def ir_jit_prelude(insn)
      # Save callee-saved regs
      asm.push(SP)
      asm.push(CFP)
      asm.push(EC)

      asm.mov(CFP, :rsi)
      asm.mov(EC, :rdi)
      asm.mov(SP, CFP[:sp])
    end

    def ir_jit_suffix(insn)
      asm.pop(EC)
      asm.pop(CFP)
      asm.pop(SP)
    end

    def out(insn)
      @regs.fetch(insn.output)
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
