module HawthJit
  class Pass
    def initialize(input_ir)
      @input_ir = input_ir
    end

    require "hawthjit/pass/drop_unused_labels"
    require "hawthjit/pass/skip_useless_updates"
    require "hawthjit/pass/flatten_stack_operations"
    require "hawthjit/pass/simplify"

    PASSES = [
      Pass::DropUnusedLabels,
      Pass::SkipUselessUpdates,
      Pass::FlattenStackOperations,
      Pass::Simplify,
      Pass::Simplify, # FIXME
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
      when :call_jit_func
        true
      when :vm_pop
        true
      else
        insn.outputs.size == 0
      end
    end
  end
end
