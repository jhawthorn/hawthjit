module HawthJit
  class DataFlow
    def initialize(
      ir,
      direction: :forward,
      init: -> () {  },
      merge:,
      transfer: -> (v, *) { v }
    )
      @ir = ir
      @worklist = Set.new
      @worklist += ir.blocks

      @merge = merge
      @transfer_proc = transfer
      init = -> () { init } unless init.respond_to?(:call)

      @in = {}
      @out = {}
      @input_map = {}

      @direction = direction

      if direction == :forward
        @in[ir.entry.ref] = init.call
        @ir.blocks.each do |block|
          @input_map[block.ref] = block.successor_refs
        end
      else
        # FIXME: need to set init for terminal blocks
        @input_map = ir.blocks.map { [_1.ref, []] }.to_h
        @ir.blocks.each do |block|
          block.successor_refs.each do |succ_ref|
            #@input_map[succ_ref] ||= []
            @input_map[succ_ref] << block.ref
          end
        end
      end
    end

    def transfer_block(block)
      @transfer_proc.call(@in[block.ref], block)
    end

    def process
      until @worklist.empty?
        block = @worklist.first
        @worklist.delete(block)

        input_blocks = @input_map[block.ref]
        inputs = input_blocks.map { @out[_1] }
        @in[block.ref] = @merge.call(inputs)
        output = transfer_block(block)

        if output != @out[block.ref]
          @out[block.ref] = output
          @worklist.merge input_blocks.map { |ref|
            @ir.block(ref)
          }
        end
      end
    end

    class ByInsn < DataFlow
      def transfer_block(block)
        initial = @in[block.ref]
        value = initial

        each_insn(block)do |insn, idx|
          value = transfer_insn(value, block, insn, idx)
        end
        value
      end

      def transfer_insn(value, block, insn, idx)
        @transfer_proc.call(value, block, insn, idx)
      end

      def remove_where!
        @ir.blocks.each do |block|
          value = @in[block.ref]
          idx_to_remove = []
          each_insn(block) do |insn, idx|
            should_remove = yield(value, block, insn, idx)
            #p(idx:, insn:, value:, should_remove:)
            value = transfer_insn(value, block, insn, idx)
            block.insns.delete_at(idx) if should_remove
          end
        end
        @ir
      end

      private
      def each_insn(block)
        case @direction
        when :backward
          last = block.insns.size
          block.insns.reverse.each_with_index do |insn, idx|
            yield insn, last - idx - 1
          end
        when :forward
          block.insns.each_with_index do |insn, idx|
            yield insn, idx
          end
        else
          raise
        end
      end
    end

    attr_reader :in, :out

    def self.forward(ir, **kwargs)
      new(ir, direction: :forward, **kwargs).tap(&:process)
    end

    def self.backward(ir, **kwargs)
      new(ir, direction: :backward, **kwargs).tap(&:process)
    end

    # in[entry] = init
    # out[*] = init
    #
    # worklist = all blocks
    # while worklist is not empty:
    #     b = pick any block from worklist
    #     in[b] = merge(out[p] for every predecessor p of b)
    #     out[b] = transfer(b, in[b])
    #     if out[b] changed:
    #         worklist += successors of b
  end
end
