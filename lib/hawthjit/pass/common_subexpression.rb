module HawthJit
  class Pass
    class CommonSubexpression < Pass
      def process
        output_ir = @input_ir.dup

        output_ir.blocks.each do |block|
          prev_var = {}
          prev_mem = {}

          block.insns.each_with_index do |insn, idx|
            if insn.name == :store
              prev_mem.clear
              next
            end

            next if side_effect?(insn)
            next if insn.outputs.size == 0

            prev = insn.name == :load ? prev_mem : prev_var

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
