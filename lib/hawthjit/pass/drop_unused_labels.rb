module HawthJit
  class Pass
    class DropUnusedLabels < Pass
      def process
        output_ir = @input_ir.dup

        used_labels = Set.new

        output_ir.instructions.each do |insn|
          next if IR::BIND === insn
          used_labels += insn.inputs.grep(IR::Label)
        end

        output_ir.instructions.reject! do |insn|
          IR::BIND === insn && !used_labels.include?(insn.inputs[0])
        end

        output_ir.labels = used_labels.to_a

        output_ir
      end
    end
  end
end
