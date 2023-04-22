module HawthJit
  class Pass
    class CommonSubexpression < Pass
      def process
        output_ir = @input_ir.dup

        output_ir.blocks.each do |block|
          prev = {}

          block.insns.each_with_index do |insn, idx|
            next if side_effect?(insn)
            next if insn.name == :load # FIXME: need to check for memory side effects elsewhere
            next if insn.outputs.size == 0

            key = [insn.name, *insn.inputs]
            if existing = prev[key]
              block.insns[idx] =
                insn.outputs.zip(existing).map do |new_output, old_output|
                  IR::ASSIGN.new([new_output], [old_output])
                end
            else
              prev[key] = insn.outputs
            end

            block.insns.flatten!
          end
        end

        output_ir
      end
    end
  end
end
