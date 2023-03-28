module HawthJit
  class Pass
    class FlattenStackOperations < Pass
      TempPhi = Data.define(:merge_ref, :sources)
      TempPush = Data.define(:block, :value)

      def process
        output_ir = @input_ir.dup

        sp_at_block = {
          output_ir.entry => 0
        }

        flow = DataFlow.forward(
          output_ir,
          init: [],
          transfer: -> (value, block) do
            stack = value.dup
            block.insns.each do |insn|
              case insn.name
              when :vm_push
                stack << TempPush.new(block.ref, insn.input)
              when :vm_pop
                stack.pop
              end
            end
            [block.ref, stack]
          end,
          merge: -> (incoming, block) {
            blocks = incoming.map(&:first)
            stacks = incoming.map(&:last)

            if stacks.size == 1
              next stacks[0]
            end

            stack = stacks[0].zip(*stacks[1..])
            stack.map! do |values|
              next values[0] if values.uniq.size == 1

              TempPhi.new(block.ref, values.map.with_index { |v, idx| [v, blocks[idx]] })
            end

            stack
          }
        )

        phis = flow.in.values.flatten.grep(TempPhi).uniq
        phis_by_merge = phis.group_by(&:merge_ref)
        phis_to_var = phis.map { [_1, output_ir.build_output] }.to_h

        temp_to_var = -> (temp) {
          case temp
          when TempPhi
            phis_to_var[temp]
          when TempPush
            temp_to_var[temp.value]
          else
            temp
          end
        }

        output_ir.blocks.each do |block|
          # insert phis
          block.insns.unshift *phis_by_merge.fetch(block.ref, []).map { |phi|
            output = phis_to_var[phi]
            IR::PHI.new([output], phi.sources.flat_map { |(value, block)|
              [temp_to_var[value], block]
            })
          }
        end

        # Replace all vm_pop, vm_stack_topn, and capture_stack_map with
        # references to the originally pushed variable or constant.
        output_ir.blocks.each do |block|
          stack = flow.in[block.ref]
          stack.map!{ temp_to_var[_1] }

          block.insns.each_with_index do |insn, idx|
            current_sp = stack.length
            case insn.name
            when :vm_push
              insn.props[:sp] = current_sp
              stack << insn.input
            when :vm_pop
              value = stack.pop
              unless insn.outputs.empty?
                block.insns[idx] = [
                  (IR::ASSIGN.new(insn.outputs, [value])),
                  (IR::VM_POP.new([], []))
                ].compact
              end
              insn.props[:sp] = current_sp
            when :vm_stack_topn
              n = insn.input
              value = stack[-n-1] or raise "bad value for topn"
              block.insns[idx] = IR::ASSIGN.new(insn.outputs, [value])
            when :update_sp
              insn.props[:sp] = current_sp
            when :push_frame
              insn.props[:sp] = current_sp
            when :capture_stack_map
              insn.props[:sp] = current_sp

              stack_map = IR::StackMap.new(
                insn.inputs[0],
                stack.dup
              )

              block.insns[idx] = IR::ASSIGN.new(insn.outputs, [stack_map])
            end
          end
          block.insns.flatten!
        end

        # remove elidable push/pop pairs
        output_ir.blocks.each do |block|
          stack = []
          block.insns.each_with_index do |insn, idx|
            case insn.name
            when :vm_push
              stack << idx
            when :vm_pop
              unless stack.empty?
                prev_idx = stack.pop
                block.insns[prev_idx] = nil
                block.insns[idx] = nil
              end
            when :side_exit, :call_jit_func, :push_frame
              stack.clear
            end
          end
          block.insns.compact!
        end

        output_ir
      end
    end
  end
end
