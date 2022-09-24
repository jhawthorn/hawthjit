module HawthJit
  class X86Assembler
    X86 = AsmJIT::X86

    # Callee-saved registers
    # We make the same choices as YJIT
    SP = X86::REGISTERS[:rbx]
    CFP = X86::REGISTERS[:r13]
    EC = X86::REGISTERS[:r12]

    attr_reader :asm
    def initialize
      @code = AsmJIT::CodeHolder.new
      @disasm = +""
      @code.logger = @disasm
      @asm = X86::Assembler.new(@code)
    end

    def compile(ir)
      ir.each do |op, *operands|
        if respond_to?("ir_#{op}")
          send("ir_#{op}", *operands)
        else
          # by default, just emit
          @asm.emit(op.to_s, *operands)
        end
      end

      @code
    end

    def ir_comment(comment)
      @disasm << comment
    end

    def ir_jit_prelude
      # Save callee-saved regs
      asm.push(SP)
      asm.push(CFP)
      asm.push(EC)

      asm.mov(CFP, :rsi)
      asm.mov(EC, :rdi)
      asm.mov(SP, CFP[:sp])
    end

    def ir_jit_suffix
      asm.pop(EC)
      asm.pop(CFP)
      asm.pop(SP)
      asm.ret
    end
  end
end
