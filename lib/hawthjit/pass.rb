module HawthJit
  class Pass
    def initialize(input_ir)
      @input_ir = input_ir
    end

    require "hawthjit/pass/drop_unused_labels"
    require "hawthjit/pass/skip_useless_updates"
    require "hawthjit/pass/flatten_stack_operations"

    PASSES = [
      Pass::DropUnusedLabels,
      Pass::SkipUselessUpdates,
      Pass::FlattenStackOperations
    ]

    def self.apply_all(ir)
      PASSES.inject(ir) do |ir, pass|
        pass.new(ir).process
      end
    end
  end
end
