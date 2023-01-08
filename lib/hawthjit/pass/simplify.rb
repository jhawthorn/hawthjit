module HawthJit
  class Pass
    class Simplify < Pass
      def process
        output_ir = @input_ir.dup

        sources = {}
        remap = {}

        blocks = output_ir.blocks

        again = true
        while again
          again = false

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
                  again = true
                  source_insn.input
                else
                  input
                end
              end

              if insn.name == :phi &&
                  (insn.inputs.each_slice(2).map(&:first).uniq.size == 1)
                insns[idx] = IR::ASSIGN.new(insn.outputs, [insn.inputs[0]])

                again = true
              end

              if insn.name == :rtest &&
                  (source_insn = sources[insn.input])&.name == :rbool
                # rtest(rbool(x)) == x
                insns[idx] = IR::ASSIGN.new(insn.outputs, source_insn.inputs)

                again = true
              end

              if insn.name == :add && constant_inputs?(insn)
                a, b = insn.inputs
                val = a + b
                insns[idx] = IR::ASSIGN.new(insn.outputs, [val])

                again = true
              end

              if insn.name == :sub && constant_inputs?(insn)
                a, b = insn.inputs
                val = a - b
                insns[idx] = IR::ASSIGN.new(insn.outputs, [val])

                again = true
              end

              if insn.name == :test_fixnum && Integer === insn.input
                insns[idx] = IR::ASSIGN.new(insn.outputs, [insn.input & 1])

                again = true
              end

              if (insn.name == :guard || insn.name == :guard_not) && Integer === insn.input
                val = insn.input
                val ^= 1 if insn.name == :guard_not

                case val
                when 0
                  insns[idx] = output_ir.build(:side_exit)
                when 1
                  insns[idx] = nil
                else
                  raise "bad value for guard: #{val.inspect}"
                end
              end
            end

            insns.compact!
          end

          ## Remove any unused side-effect free code
          size_before = blocks.sum { _1.insns.size }

          used_inputs = blocks.
            flat_map(&:insns).
            flat_map(&:inputs).
            grep(IR::OutOpnd).
            to_set

          blocks.each do |block|
            block.insns.select! do |insn|
              side_effect?(insn) || insn.outputs.any? { used_inputs.include?(_1) }
            end

            block.insns.each do |insn|
              if insn.name == :vm_pop && !used_inputs.include?(insn.outputs[0])
                insn.outputs.clear
              end
            end
          end

          size_after = blocks.sum { _1.insns.size }

          again ||= (size_before != size_after)
        end

        output_ir
      end

      def constant_inputs?(insn)
        insn.inputs.none? { |x| IR::OutOpnd === x }
      end
    end
  end
end
