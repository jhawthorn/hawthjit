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

  def test_simplifies_add_overflow
    x = asm.assign(2)
    x, _o = asm.add_with_overflow(x, x)
    asm.jit_return(x)

    run_passes

    assert_asm <<~ASM
      entry:
        jit_return 4
    ASM
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

    run_passes

    assert_asm <<~ASM
      entry:
    ASM
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

    cond = ir.build_output
    asm.br_cond cond, block_a, block_b

    run_passes

    assert_asm <<~ASM
      entry:
        br_cond v4 a b

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

  def test_simplifies_unconditional_br_cond
    block_a = ir.new_block("a") do |asm|
      asm.jit_return 123
    end
    block_b = ir.new_block("b") do |asm|
      asm.jit_return 456
    end

    _v, o = asm.add_with_overflow(1, 1)
    asm.br_cond(o, block_a, block_b)

    run_passes

    assert_asm <<~ASM
      entry:
        jit_return 456
    ASM
  end

  def test_removes_unnecessary_updates_with_loop
    block_a = ir.new_block("a")
    block_b = ir.new_block("b")
    block_c = ir.new_block("c")

    x = ir.build_output
    asm.br block_a

    block_a.asm do |asm|
      asm.update_sp

      asm.br_cond x, block_b, block_c
    end

    block_b.asm do |asm|
      asm.br_cond x, block_a, block_c
    end

    block_c.asm do |asm|
      asm.jit_return 0
    end

    run_passes

    assert_asm <<~ASM
      entry:
        br a

      a:
        br_cond v1 b c

      b:
        br_cond v1 a c

      c:
        jit_return 0
    ASM
  end

  def test_redundant_multiply
    # x * x + x * x
    x = ir.build_output
    m1, _o1 = asm.imul_with_overflow(x, x)
    m2, _o2 = asm.imul_with_overflow(x, x)
    a1 = asm.add(m1, m2)
    asm.jit_return a1

    run_passes

    assert_asm <<~ASM
      entry:
        v2, v3 = imul_with_overflow v1 v1
        v6 = add v2 v2
        jit_return v6
    ASM
  end

  def test_common_subexpression
    # Example from https://www.pypy.org/posts/2022/07/toy-optimizer.html
    # a * (b + 17) + (b + 17)
    v1 = asm.param(0)
    v2 = asm.param(1)
    v3 = asm.add(v2, 17)
    v4 = asm.imul(v1, v3)
    v5 = asm.add(v2, 17) # should be eliminated
    v6 = asm.add(v4, v5)
    asm.jit_return v6

    run_passes

    assert_asm <<~ASM
      entry:
        v1 = param 0
        v2 = param 1
        v3 = add v2 17
        v4 = imul v1 v3
        v6 = add v4 v3
        jit_return v6
    ASM
  end

  def assert_asm(asm, ir: @ir)
    assert_equal asm, ir.to_s
  end

  def run_passes
    @ir = HawthJit::Pass.apply_all(@ir)
  end
end
