module HawthJit
  class Pass
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

          ordered_insns = block.insns
          ordered_insns = ordered_insns.reverse if @direction == :backward

          block.insns.each_with_index do |insn, idx|
            value = transfer_insn(value, block, insn, idx)
          end
          value
        end

        def transfer_insn(value, block, insn, idx)
          @transfer_proc.call(value, block, insn, idx)
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

    def initialize(input_ir)
      @input_ir = input_ir
    end

    require "hawthjit/pass/combine_blocks"
    require "hawthjit/pass/skip_useless_updates"
    require "hawthjit/pass/flatten_stack_operations"
    require "hawthjit/pass/simplify"
    require "hawthjit/pass/common_subexpression"
    require "hawthjit/pass/vm_lower"
    require "hawthjit/pass/x86_allocate_registers"

    PASSES = [
      Pass::Simplify,
      Pass::CombineBlocks,
      Pass::SkipUselessUpdates,
      Pass::FlattenStackOperations,
      Pass::VMLower,
      Pass::Simplify,
      Pass::CommonSubexpression,
      Pass::Simplify,
    ]

    def self.apply_all(ir)
      PASSES.inject(ir) do |ir, pass|
        pass.new(ir).process
      end
    end

    def side_effect?(insn)
      case insn.name
      when :nop
        false
      when :call_jit_func, :c_call
        true
      when :vm_pop
        true
      else
        insn.outputs.size == 0
      end
    end
  end
end
