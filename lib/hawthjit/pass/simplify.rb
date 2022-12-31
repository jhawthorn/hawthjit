module HawthJit
  class Pass
    class Simplify < Pass
      def process
        output_ir = @input_ir.dup

        sources = {}
        remap = {}

        output_ir.blocks.flat_map(&:insns).each do |insn|
          insn.outputs.each do |out|
            sources[out] = insn
          end
        end

        output_ir.blocks.each do |block|
          insns = block.insns
          insns.each_with_index do |insn, idx|
            insn.inputs.map! do |input|
              if (source_insn = sources[input]) && source_insn.name == :assign
                source_insn.input
              else
                input
              end
            end

            if insn.name == :rtest &&
                (source_insn = sources[insn.input])&.name == :rbool
              # rtest(rbool(x)) == x
              insns[idx] = IR::ASSIGN.new(insn.outputs, source_insn.inputs)
            end

            if insn.name == :sub && constant_inputs?(insn)
              a, b = insn.inputs
              val = a - b
              insns[idx] = IR::ASSIGN.new(insn.outputs, [val])
            end

            if insn.name == :guard_fixnum && Integer === insn.input
              if insn.input & 1 == 1
                # FIXNUM: nothing to do
                insns[idx] = nil
              else
                insns[idx] = output_ir.build(:side_exit)
              end
            end
          end

          insns.compact!
        end

        ## Remove any unused side-effect free code
        #last_size = nil
        #while last_size != insns.size
        #  last_size = insns.size

        #  used_inputs = Set.new
        #  insns.each do |insn|
        #    used_inputs.merge(insn.inputs.grep(IR::OutOpnd))
        #  end

        #  insns.select! do |insn|
        #    side_effect?(insn) || insn.outputs.any? { used_inputs.include?(_1) }
        #  end

        #  insns.each do |insn|
        #    if insn.name == :vm_pop && !used_inputs.include?(insn.outputs[0])
        #      insn.outputs.clear
        #    end
        #  end
        #end

        output_ir
      end

      def constant_inputs?(insn)
        insn.inputs.none? { |x| IR::OutOpnd === x }
      end
    end
  end
end
