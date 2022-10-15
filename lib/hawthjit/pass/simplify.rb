module HawthJit
  class Pass
    class Simplify < Pass
      def process
        output_ir = @input_ir.dup

        sources = {}
        remap = {}

        output_ir.insns.each do |insn|
          insn.outputs.each do |out|
            sources[out] = insn
          end
        end

        output_ir.insns.each do |insn|
          insn.inputs.map! do |input|
            if (source_insn = sources[input]) && source_insn.name == :assign
              source_insn.input
            else
              input
            end
          end
        end

        # Remove any unused side-effect free code
        used_inputs = Set.new
        output_ir.insns.each do |insn|
          used_inputs.merge(insn.inputs.grep(IR::OutOpnd))
        end

        output_ir.insns.select! do |insn|
          side_effect?(insn) || insn.outputs.any? { used_inputs.include?(_1) }
        end

        output_ir
      end
    end
  end
end
