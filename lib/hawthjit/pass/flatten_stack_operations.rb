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
            push_val << insn.input
          when :vm_pop
            push = push_idx.pop
            val = push_val.pop

            if push
              insns[push] = nil
              insns[idx] = IR::ASSIGN.new([insn.output], [val])
            elsif val
              insns[idx] = [
                IR::VM_POP.new([nil], []),
                IR::ASSIGN.new([insn.output], [val])
              ]
            end
          when :bind, :br, :br_cond
            # Don't attempt optimizing between basic blocks
            push_idx.clear
            push_val.clear
          when :update_sp
            # May need stack operations for correct side exit
            push_idx.clear
          end
        end

        insns.flatten!
        insns.compact!

        output_ir
      end
    end
  end
end
