module HawthJit
  class Pass
    class X86AllocateRegisters < Pass
      GP_REGS = [:rdx, :rsi, :rdi, :r8, :r9, :r10, :r11]

      attr_reader :all_liveness, :assigns

      def process
        output_ir = @input_ir

        @block_inputs  = Hash.new { |h, k| h[k] = Set.new }
        @block_outputs = Hash.new { |h, k| h[k] = Set.new }
        @predecessors  = Hash.new { |h, k| h[k] = [] }

        blocks = output_ir.blocks
        blocks.each do |block|
          block.successors.each do |succ|
            @predecessors[succ] << block
          end
        end

        # Visit each block to determine which variables are used between blocks
        to_visit = Set.new(blocks)
        while block = to_visit.first
          to_visit.delete(block)

          preds = @predecessors[block]

          defined = block.insns.flat_map(&:outputs)
          used = block.insns.flat_map(&:inputs).grep(IR::OutOpnd)
          required = @block_outputs[block] + used - defined

          if @block_inputs[block] < required
            @block_inputs[block].merge(required)

            preds.each do |pred|
              unless @block_outputs[pred] > required
                @block_outputs[pred].merge(required)
                to_visit.add(pred)
              end
            end
          end
        end

        @available = GP_REGS.dup
        @assigns = {}

        @all_liveness = {}
        blocks.each do |block|
          @all_liveness.update(liveness_for(block)) do |_, a, b|
            a | b
          end
        end

        @all_liveness.each do |var, liveness|
          reg = @available.detect do |reg|
            @assigns.all? do |other_var, other_reg|
              next true if other_reg != reg

              other_liveness = @all_liveness[other_var]
              !liveness.intersects?(other_liveness)
            end
          end

          raise "register spill" unless reg

          @assigns[var] = reg
        end

        output_ir
      end

      class Liveness
        attr_reader :blocks
        protected :blocks

        def initialize(blocks)
          @blocks = blocks
        end

        def |(other)
          new_blocks = @blocks.merge(other.blocks) do
            raise "FIXME: conflict!"
          end
          self.class.new(new_blocks)
        end

        def intersects?(other)
          blocks.any? do |block, range|
            other_range = other.blocks[block]
            other_range && range_intersects?(range, other_range)
          end
        end

        def self.from(block, range)
          new({ block => range })
        end

        def inspect
          blocks.transform_keys(&:name).inspect
        end

        private
        def range_intersects?(a, b)
          # FIXME: make this not awful
          (a.to_a & b.to_a).any?
        end
      end

      def liveness_for(block)
        insns = block.insns

        starts = {}
        ends = {}

        last_pos = block.insns.size

        insns.each_with_index do |insn, idx|
          insn.outputs.each do |out|
            starts[out] = idx
            ends[out] = idx
          end

          insn.inputs.grep(IR::OutOpnd).each do |input|
            ends[input] = idx
          end
        end
        @block_inputs[block].each do |var|
          starts[var] = 0
        end
        @block_outputs[block].each do |var|
          ends[var] = last_pos
        end

        raise "#{starts.keys.inspect} != #{ends.keys.inspect}" unless starts.keys == ends.keys

        out = {}
        starts.sort_by(&:last).each do |var, start|
          range = start..ends[var]
          out[var] = Liveness.from(block, range)
        end
        out
      end
    end
  end
end

