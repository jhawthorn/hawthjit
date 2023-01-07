require "helper"
require "hawthjit/ir"
require "hawthjit/pass"

class PassTest < HawthJitTest
  attr_reader :ir, :asm

  def setup
    super
    @original_ir = @ir = HawthJit::IR.new
    @asm = ir.entry.assembler
  end

  def entry = @ir.entry
  def insns = entry.insns

  def test_removes_unnecessary_calculation
    x = asm.add(1, 1)
    10.times do
      x = asm.add(x, 1)
    end

    @ir = HawthJit::Pass::Simplify.new(ir).process

    assert_empty insns
  end

  def test_simplifies_constant_subtraction
    a = ir.build_output

    ret = asm.add(a, asm.sub(2, 1))
    asm.jit_return(ret)

    run_passes

    assert_asm <<~ASM
      entry:
        v3 = add v1 1
        jit_return v3
    ASM
  end

  def test_removes_unnecessary_updates
    asm.update_pc(1)
    asm.update_sp

    asm.update_pc(3)
    asm.update_sp

    asm.side_exit

    assert_equal 5, insns.size

    run_passes

    assert_equal 3, insns.size
  end

  def test_flattens_stack_operations
    asm.vm_push 1
    asm.vm_push 2
    asm.jit_return asm.add(asm.vm_pop, asm.vm_pop)

    assert_equal 6, insns.size

    run_passes

    assert_asm <<~ASM
      entry:
        jit_return 3
    ASM
  end

  def test_simplifies_phi
    block_a = ir.new_block("a")
    block_b = ir.new_block("b")
    block_c = ir.new_block("c")

    x = asm.add(1, 2)

    block_a.asm do |asm|
      asm.vm_push x
      asm.br block_c
    end

    block_b.asm do |asm|
      asm.vm_push x
      asm.br block_c
    end

    block_c.asm do |asm|
      y = asm.vm_pop
      asm.jit_return asm.add(y, y)
    end

    cond = asm.add(1, 2)
    asm.br_cond cond, block_a, block_b

    run_passes

    assert_asm <<~ASM
      entry:
        br_cond 3 a b

      a:
        vm_push 3
        br c

      b:
        vm_push 3
        br c

      c:
        vm_pop
        jit_return 6
    ASM
  end

  def assert_asm(asm, ir: @ir)
    assert_equal asm, ir.to_s
  end

  def run_passes
    @ir = HawthJit::Pass.apply_all(@ir)
  end
end
