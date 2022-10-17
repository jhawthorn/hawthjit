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

  def test_removes_unnecessary_updates
    asm.update_pc(1)
    asm.update_sp(2)

    asm.update_pc(3)
    asm.update_sp(4)

    asm.side_exit

    assert_equal 5, ir.insns.size

    run_passes

    assert_equal 3, ir.insns.size
  end

  def run_passes
    @ir = HawthJit::Pass.apply_all(@ir)
  end
end
