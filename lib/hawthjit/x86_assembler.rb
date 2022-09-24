module HawthJit
  class X86Assembler
    X86 = AsmJIT::X86

    def initialize
      @code = AsmJIT::CodeHolder.new
      @disasm = +""
      @code.logger = @disasm
      @asm = X86::Assembler.new(@code)
    end

    def compile(ir)
      ir.each do |op, *operands|
        case op
        when :comment
          @disasm << operands[0]
        else
          @asm.emit(op.to_s, *operands)
        end
      end

      @code
    end
  end
end
