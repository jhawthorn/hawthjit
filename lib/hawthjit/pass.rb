module HawthJit
  class Pass
    def initialize(input_ir)
      @input_ir = input_ir
    end
  end
end

require "hawthjit/pass/drop_unused_labels"
