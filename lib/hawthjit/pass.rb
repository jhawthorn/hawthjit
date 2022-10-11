module HawthJit
  class Pass
    def initialize(input_ir)
      @input_ir = input_ir
    end

    def self.apply_all(ir)
      ir = Pass::DropUnusedLabels.new(ir).process
      ir = Pass::SkipUselessUpdates.new(ir).process
    end
  end
end

require "hawthjit/pass/drop_unused_labels"
require "hawthjit/pass/skip_useless_updates"
