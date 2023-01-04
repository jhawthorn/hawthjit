require "helper"
require "hawthjit"

class AssemblerTest < HawthJitTest
  attr_reader :ir, :asm

  def setup
    @ir = HawthJit::IR.new
    @asm = @ir.entry.assembler
  end

  def test_simple_math
    asm.jit_prelude
    x = asm.add(1, 2)
    asm.jit_return x

    code, disasm = compile(ir)

    assert_includes disasm, <<~EXPECTED
      # v1 = add 1 2
      mov rdx, 1
      add rdx, 2
    EXPECTED
  end

  def test_phi
    block_a = ir.new_block("a")
    block_b = ir.new_block("b")
    block_c = ir.new_block("c")

    ir.entry.asm do |asm|
      asm.jit_prelude
      x = asm.add(1, 2)
      asm.br_cond x, block_a, block_b
    end

    block_a.asm do |asm|
      asm.br block_c
    end

    block_b.asm do |asm|
      asm.br block_c
    end

    block_c.asm do |asm|
      x = asm.add(1, 1)
      asm.jit_return x
    end

    code, disasm = compile(ir)

    # We should see multiple assignments to v2
    assert_includes disasm, "# v2 = assign 0"
    assert_includes disasm, "# v2 = assign 1"
    assert_includes disasm, "# jit_return v2"
  end

  def compile(ir)
    assembler = HawthJit::X86Assembler.new(ir)
    code = assembler.compile
    [code, assembler.disasm]
  end
end
