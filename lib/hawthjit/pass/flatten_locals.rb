# frozen_string_literal: true

module HawthJit
  class Pass
    class FlattenLocals < Pass
      def process
        output_ir = @input_ir.dup

        transfer_proc = -> (known_locals, block, insn, idx) do
          if false
          elsif insn.name == :vm_setlocal
            key = [insn.input(0), insn.input(1)]
            known_locals.merge(
              key => insn.input(2)
            )
          elsif insn.name == :vm_getlocal
            key = [insn.input(0), insn.input(1)]
            if known_locals.key?(key)
              known_locals
            else
              known_locals.merge(
                key => insn.output
              )
            end
          elsif may_affect_locals?(insn)
            {}
          else
            known_locals
          end
        end

        flow = DataFlow::ByInsn.forward(
          output_ir,
          init: {},
          transfer: transfer_proc,
          merge: -> (known_locals_sets, block) {
            if known_locals_sets.size == 1
              known_locals_sets[0]
            else
              # FIXME: this should use PHI nodes
              common = known_locals_sets[0].select do |key, _|
                known_locals_sets.map { _1[key] }.uniq.size == 1
              end
              common
            end
          }
        )

        output_ir.blocks.each do |block|
          known_locals = flow.in[block.ref]
          block.insns.each_with_index do |insn, idx|
            if insn.name == :vm_getlocal
              key = [insn.input(0), insn.input(1)]
              if known_value = known_locals[key]
                block.insns[idx] = IR::ASSIGN.new(insn.outputs, [known_value])
              end
            end

            known_locals = transfer_proc.call(known_locals, block, insn, idx)
          end
        end

        output_ir
      end

      def may_affect_locals?(insn)
        # FIXME: should detect whether locals could be modified by an external
        # source
        false
      end
    end
  end
end
