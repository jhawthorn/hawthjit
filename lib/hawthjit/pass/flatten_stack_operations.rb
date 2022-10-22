module HawthJit
  class Pass
    class FlattenStackOperations < Pass
      def process
        output_ir = @input_ir.dup

        # Index of stack pushes which may be elided
        push_idx = []
        push_val = []

        sp_at_label = {}
        current_sp = 0

        insns = output_ir.insns
        insns.each_with_index do |insn, idx|
          case insn.name
          when :vm_push
            push_idx << idx
            push_val << insn.input

            insn.props[:sp] = current_sp
            current_sp += 1
          when :vm_pop
            current_sp -= 1

            push = push_idx.pop
            val = push_val.pop

            if push
              insns[push] = nil
              insns[idx] = IR::ASSIGN.new([insn.output], [val])
            elsif val
              pop_insn = IR::VM_POP.new([nil], [])
              pop_insn.props[:sp] = current_sp

              insns[idx] = [
                pop_insn,
                IR::ASSIGN.new([insn.output], [val])
              ]
            else
              insn.props[:sp] = current_sp
            end
          when :br, :br_cond
            labels = insn.inputs.grep(IR::Label)
            labels.each do |label|
              sp_at_label[label] = current_sp
            end
            current_sp = nil
          when :bind
            label = insn.input
            current_sp ||= sp_at_label[label]

            # Don't attempt optimizing between basic blocks
            push_idx.clear
            push_val.clear
          when :update_sp
            # May need stack operations for correct side exit
            push_idx.clear

            insn.props[:sp] = current_sp
          when :comment
            # ignore
          end
        end

        insns.flatten!
        insns.compact!

        output_ir
      end
    end
  end
end
