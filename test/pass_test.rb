require "helper"
require "hawthjit/ir"
require "hawthjit/pass"

class PassTest < HawthJitTest
  attr_reader :ir, :asm

  def setup
    super
    @original_ir = @ir = HawthJit::IR.new
    @asm = ir.assembler
  end

  def test_removes_unnecessary_calculation
    x = asm.add(1, 1)
    10.times do
      x = asm.add(x, 1)
    end

    new_ir = HawthJit::Pass::Simplify.new(ir).process

    assert_empty new_ir.insns
  end

  def test_simplifies_constant_subtraction
    a = asm.vm_pop
    ret = asm.add(a, asm.sub(2, 1))
    asm.vm_push(ret)

    assert_equal %i[ vm_pop sub add vm_push ], ir.insns.map(&:name)

    run_passes

    assert_equal %i[ vm_pop add vm_push ], ir.insns.map(&:name)
  end

  def test_removes_unnecessary_updates
    asm.update_pc(1)
    asm.update_sp

    asm.update_pc(3)
    asm.update_sp

    asm.side_exit

    assert_equal 5, ir.insns.size

    run_passes

    assert_equal 3, ir.insns.size
  end

  def test_flattens_stack_operations
    asm.vm_push 1
    asm.vm_push 2
    asm.jit_return asm.add(asm.vm_pop, asm.vm_pop)

    assert_equal 6, ir.insns.size

    run_passes

    assert_equal [:add, :jit_return], ir.insns.map(&:name)
  end

  def run_passes
    @ir = HawthJit::Pass.apply_all(@ir)
  end
end