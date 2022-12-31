module HawthJit
  class Pass
    class CombineBlocks < Pass
      def process
        output_ir = @input_ir.dup

        successors = Hash.new { |h, k| h[k] = [] }
        predecessors = Hash.new { |h, k| h[k] = [] }

        output_ir.blocks.each do |block|
          succs = block.successors

          succs.each do |succ|
            successors[block] << succ
            predecessors[succ] << block
          end
        end

        output = []
        queue = [output_ir.entry]

        while block = queue.shift
          next if output.include?(block)
          output << block

          cur = block
          while successors[block].size == 1 && predecessors[successors[block][0]].size == 1
            succ = successors[block][0]
            raise "expected unconditional branch in #{block.inspect}" unless block.insns.last.name == :br

            block.insns.pop
            block.insns.concat(succ.insns)

            successors[block] = successors[succ]
            #predecessors.delete(succ)
            #successors.delete(succ)
          end

          queue.concat successors[block]
        end

        output_ir.blocks = output

        output_ir
      end
    end
  end
end
