module HawthJit
  class Pass
    class CommonSubexpression < Pass
      def process
        output_ir = @input_ir.dup

        # Local Value Numbering (-ish)
        #
        # We build a canonical key for each non-side-effect operation,
        # consisting of its opcode and canonicalized inputs. When we encounter
        # a key we've seen before, we replace the instruction with an
        # assignment from the previous outputs, and we record the previous
        # outputs as the caonical versions, which allows us to perform this as
        # a single pass.
        #
        # For memory (just load currently) we don't have any alias analysis or
        # anything so we consider loads equivalent with the same parameters
        # until ANY store occurs, and then ALL existing memory values are
        # considered different.
        output_ir.blocks.each do |block|
          prev_var = {}
          prev_mem = {}

          canonical_var = Hash.new { |h,k| h[k] = k }

          block.insns.each_with_index do |insn, idx|
            if insn.name == :store
              prev_mem.clear
              next
            end

            next if side_effect?(insn)
            next if insn.outputs.size == 0

            prev = insn.name == :load ? prev_mem : prev_var

            key = [insn.name, *insn.inputs.map { canonical_var[_1] }]
            if existing = prev[key]
              mapping = insn.outputs.zip(existing)
              mapping.each do |new_output, old_output|
                canonical_var[new_output] = old_output
              end

              block.insns[idx] =
                mapping.map do |new_output, old_output|
                  IR::ASSIGN.new([new_output], [old_output])
                end
            else
              prev[key] = insn.outputs
            end

            block.insns.flatten!
          end
        end

        output_ir
      end
    end
  end
end
