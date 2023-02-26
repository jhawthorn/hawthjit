module HawthJit
  class Pass
    # Lower vm_* instructions
    class VMLower < Pass
      def process
        output_ir = @input_ir.dup

        output_ir.blocks.each do |block|
          block.insns.map! do |insn|
            if IR::VM_GETLOCAL === insn
              idx, level = insn.inputs
              val = nil
              assemble(output_ir) do |asm|
                # FIXME: not sure this is right for level > 0
                local_offset = -idx * 8

                ep = compile_get_ep(asm, level)
                val = asm.load(ep, local_offset)
              end + [IR::ASSIGN.new(insn.outputs, [val])]
            else
              insn
            end
          end
          block.insns.flatten!
        end

        #puts output_ir

        output_ir
      end

      def compile_get_ep(asm, level)
        # ep = cfp->ep
        cfp = asm.cfp
        ep = asm.load(cfp, CFPStruct.offset(:ep), 8)
        level.times do
          ep = asm.and(asm.load(ep, -8, 8), ~3)
        end
        ep
      end

      def assemble(output_ir, &block)
        ir_block = IR::Block.new(output_ir, "_tmp")
        ir_block.asm(&block)
        ir_block.insns
      end
    end
  end
end
