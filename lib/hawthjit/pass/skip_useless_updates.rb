module HawthJit
  class Pass
    class SkipUselessUpdates < Pass
      def process
        output_ir = @input_ir.dup

        [:update_pc, :update_sp].each do |insn_name|
          flow = DataFlow::ByInsn.backward(
            output_ir,
            init: false,
            transfer: -> (value, block, insn, idx) do
              if insn_name == insn.name
                false
              elsif requires_update?(insn)
                true
              else
                value
              end
            end,
            merge: -> (needed) { needed.any? }
          )
          flow.remove_where! do |needed, block, insn, _|
            insn.name == insn_name && !needed
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
        when :push_frame
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
