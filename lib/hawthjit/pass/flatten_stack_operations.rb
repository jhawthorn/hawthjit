module HawthJit
  class Pass
    class FlattenStackOperations < Pass
      def process
        output_ir = @input_ir.dup

        sp_at_block = {
          output_ir.entry => 0
        }

        stack_variables_at_start = {}
        stack_variables_at_end = {}

        # goal: wherever possible remove vm_push/vm_pop pairs
        # when that isn't possible, use the originating variable instead of the
        # variable from the vm_pop to reduce data dependencies.

        output_ir.blocks.each do |block|
          sp_at_block_start = sp_at_block.fetch(block)
          current_sp = sp_at_block_start

          stack_variables = current_sp.times.map do
            output_ir.build_output
          end
          stack_variables_at_start[block] = stack_variables.dup

          push_idx = []
          to_remove = []

          block.insns.each_with_index do |insn, idx|
            case insn.name
            when :vm_push
              push_idx << idx
              stack_variables << insn.input

              insn.props[:sp] = current_sp
              current_sp += 1
            when :vm_pop
              remove_idx = push_idx.pop
              var = stack_variables.pop or raise "attempt to pop empty stack"

              to_remove << remove_idx if remove_idx

              block.insns[idx] = [
                IR::ASSIGN.new(insn.outputs, [var]),
                (IR::VM_POP.new([], []) unless remove_idx)
              ]

              current_sp -= 1
              insn.props[:sp] = current_sp
            when :update_sp
              # May need stack operations for correct side exit
              push_idx.clear

              insn.props[:sp] = current_sp
            when :push_frame
              insn.props[:sp] = current_sp
            end
          end

          to_remove.compact.each do |idx|
            block.insns[idx] = nil
          end

          block.insns.flatten!
          block.insns.compact!

          stack_variables_at_end[block] = stack_variables

          block.successors.each do |succ|
            if existing = sp_at_block[succ]
              raise "sp mismatch" unless existing == current_sp
            end
            sp_at_block[succ] = current_sp
          end
        end

        phis = {}
        stack_variables_at_end.each do |block, variables|
          block.successors.each do |succ|
            phis[succ] ||= {}
            phis[succ][block] = variables
          end
        end

        phis.each do |block, preds|
          size = preds.values[0].size
          next if size.zero?
          new_phis = size.times.map do |i|
            succ_var = stack_variables_at_start[block][i] || raise

            phi_inputs = preds.flat_map do |pred, pred_vars|
              pred_var = pred_vars[i] || raise

              [pred_var, pred]
            end

            IR::PHI.new([succ_var], phi_inputs)
          end

          block.insns.unshift(*new_phis)
        end

        output_ir
      end
    end
  end
end
