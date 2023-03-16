module HawthJit
  class Pass
    class SkipUselessUpdates < Pass
      def process
        output_ir = @input_ir.dup

        successor_update_required = Hash.new do |h, key|
          h[key] = DataFlow.backward(
            @input_ir,
            init: false,
            transfer: -> (block, succ) do
              next_significant_insn = block.insns.detect do |insn|
                insn.name == key || requires_update?(insn)
              end

              if next_significant_insn
                requires_update?(next_significant_insn)
              else
                succ
              end
            end,
            merge: -> (needed) { needed.any? }
          ).out
        end

        output_ir.blocks.each do |block|
          to_remove = Set.new
          pending = {}

          block.insns.each_with_index do |insn, idx|
            if insn.name == :jit_return
              to_remove.merge(pending.values)
              pending.clear
            elsif is_update?(insn)
              if pending[insn.name]
                to_remove << pending[insn.name]
              end
              pending[insn.name] = idx
            elsif requires_update?(insn)
              pending.clear
            end
          end

          # Find whether the pending insns at end of block can be removed
          pending.each do |key, idx|
            can_remove = !successor_update_required[key][block.ref]

            if can_remove
              to_remove << idx
            end
          end

          block.insns.reject!.with_index do |_, idx|
            to_remove.include?(idx)
          end
        end

        output_ir
      end

      def is_update?(insn)
        insn.name == :update_pc || insn.name == :update_sp
      end

      def requires_update?(insn)
        case insn.name
        when :call_jit_func
          true
        #when :br, :br_cond
        #  true
        else
          false
        end
      end
    end
  end
end
