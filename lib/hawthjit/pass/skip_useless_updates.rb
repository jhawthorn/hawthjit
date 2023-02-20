module HawthJit
  class Pass
    class SkipUselessUpdates < Pass
      def process
        output_ir = @input_ir.dup

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
            can_remove = !successors_require_update?(block.ref, key)

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

      def successors_require_update?(blockref, key, seen: [blockref])
        block = @input_ir.block(blockref)
        succs = block.successors
        succs.any? do |succ|
          next_significant_insn = succ.insns.detect do |insn|
            insn.name == key || requires_update?(insn)
          end

          if next_significant_insn
            next true if requires_update?(next_significant_insn)
            next false if next_significant_insn.name == key
            raise
          end

          if seen.include?(succ.ref)
            # We're in a loop with no required updates
            false
          else
            # Continue DFS on successors
            successors_require_update?(succ.ref, key, seen: seen | [succ.ref])
          end
        end
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
