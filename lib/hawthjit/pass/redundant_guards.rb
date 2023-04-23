# frozen_string_literal: true

module HawthJit
  class Pass
    class RedundantGuards < Pass
      def process
        output_ir = @input_ir.dup

        transfer_proc = -> (known_values, block, insn, idx) do
          if false
          elsif insn.name == :guard
            known_values.merge(insn.input(0) => true)
          elsif insn.name == :guard_not
            known_values.merge(insn.input(0) => false)
          else
            known_values
          end
        end

        flow = DataFlow::ByInsn.forward(
          output_ir,
          init: {},
          transfer: transfer_proc,
          merge: -> (known_values, block) {
            if known_values.size == 1
              known_values[0]
            else
              known_values.map(&:to_a).inject(:&).to_h
            end
          }
        )

        output_ir.blocks.each do |block|
          known_values = flow.in[block.ref]
          block.insns.each_with_index do |insn, idx|
            if false
            elsif (insn.name == :guard || insn.name == :guard_not) && known_values.key?(insn.input(0))
              expected = insn.name == :guard ? true : false
              known = known_values[insn.input(0)]

              if expected == known
                block.insns[idx] = nil
              else
                # warn? unconditional side exit?
              end
            end

            known_values = transfer_proc.call(known_values, block, insn, idx)
          end
          block.insns.compact!
        end

        output_ir
      end
    end
  end
end
