module HawthJit
  class Pass
    def initialize(input_ir)
      @input_ir = input_ir
    end

    require "hawthjit/pass/combine_blocks"
    require "hawthjit/pass/skip_useless_updates"
    require "hawthjit/pass/flatten_stack_operations"
    require "hawthjit/pass/flatten_locals"
    require "hawthjit/pass/simplify"
    require "hawthjit/pass/common_subexpression"
    require "hawthjit/pass/redundant_guards"
    require "hawthjit/pass/vm_lower"
    require "hawthjit/pass/x86_allocate_registers"

    PASSES = [
      Pass::Simplify,
      Pass::CombineBlocks,
      Pass::SkipUselessUpdates,
      Pass::FlattenStackOperations,
      Pass::FlattenLocals,
      Pass::VMLower,
      Pass::Simplify,
      Pass::CommonSubexpression,
      Pass::Simplify,
      Pass::RedundantGuards,
      Pass::Simplify,
    ]

    def self.apply_all(ir)
      PASSES.inject(ir) do |ir, pass|
        pass.new(ir).process
      end
    end

    def side_effect?(insn)
      case insn.name
      when :nop
        false
      when :call_jit_func, :c_call
        true
      when :vm_pop
        true
      else
        insn.outputs.size == 0
      end
    end
  end
end
