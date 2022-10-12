module HawthJit
  class Pass
    class FlattenStackOperations < Pass
      def process
        output_ir = @input_ir.dup

        # Index of stack pushes which may be elided
        push_idx = []
        push_val = []

        insns = output_ir.insns
        insns.each_with_index do |insn, idx|
          case insn.name
          when :vm_push
            push_idx << idx
          when :vm_pop
            push = push_idx.pop

            if push
              push_insn = insns[push]
              insns[push] = nil
              insns[idx] = IR::ASSIGN.new([insn.output], [push_insn.input])
            end
          when :bind, :br, :br_cond
            # Don't attempt optimizing between basic blocks
            push_idx.clear
          when :update_sp
            # May need stack operations for correct side exit
            push_idx.clear
          end
        end

        insns.compact!

        output_ir
      end
    end
  end
end
