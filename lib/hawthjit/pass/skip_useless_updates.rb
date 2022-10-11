module HawthJit
  class Pass
    class SkipUselessUpdates < Pass
      def process
        output_ir = @input_ir.dup
        to_remove = Set.new

        pending = {}

        output_ir.instructions.each_with_index do |insn, idx|
          if is_update?(insn)
            if pending[insn.name]
              to_remove << pending[insn.name]
            end
            pending[insn.name] = idx
          elsif requires_update?(insn)
            pending.clear
          end
        end

        output_ir.insns.reject!.with_index do |_, idx|
          to_remove.include?(idx)
        end

        output_ir
      end

      def is_update?(insn)
        insn.name == :update_pc || insn.name == :update_sp
      end

      def requires_update?(insn)
        case insn.name
        when /guard/
          true
        when :side_exit, :call_jit_func
          true
        when :br, :br_cond
          true
        else
          false
        end
      end
    end
  end
end
