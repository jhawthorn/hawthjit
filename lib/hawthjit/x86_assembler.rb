module HawthJit
  class X86Assembler
    X86 = AsmJIT::X86

    # Callee-saved registers
    # We make the same choices as YJIT
    BP = X86::REGISTERS[:rbx]
    CFP = X86::REGISTERS[:r13]
    EC = X86::REGISTERS[:r12]

    SCRATCH_REGS = [:rax, :r11]
    GP_REGS = [:rdx, :rsi, :rdi, :rcx, :r8, :r9, :r10]
    C_ARG_REGS = %i[rdi rsi rdx rcx r8 r9]
    CALLER_SAVE = %i[rax rcx rdx rdi rsi rsp r8 r9 r10 r11]
    CALLEE_SAVE = %i[rbx rbp r12 r13 r14 r15]

    attr_reader :asm
    attr_reader :disasm

    def initialize(ir)
      @code = AsmJIT::CodeHolder.new
      @disasm = +""
      @code.logger = @disasm
      @asm = X86::Assembler.new(@code)

      @ir = ir
    end

    def allocate_regs!
      @reg_allocation = Pass::X86AllocateRegisters.new(@ir)
      @reg_allocation.process

      @regs = @reg_allocation.assigns.freeze

      @ir.blocks.each do |block|
        block.insns.each_with_index do |insn, idx|
          if insn.name =~ /call/
            live = @reg_allocation.in_use_at(block, idx).values
            in_use = live - insn.outputs.map { @regs.fetch(_1) }
            insn.props[:preserve_regs] = in_use
          end
        end
      end

      #p @regs
    end

    def x86_labels
      @x86_labels ||=
        Hash.new do |h, k|
          raise TypeError, "expected IR::BlockRef, got #{k.inspect}" unless IR::BlockRef === k
          h[k] = asm.new_label
        end
    end

    def compile
      allocate_regs!

      @visited_blocks = Set.new
      queue = @ir.blocks.dup
      while block = @next_block || queue.shift
        block = @ir.block(block) if IR::BlockRef === block

        next if @visited_blocks.include?(block.ref)
        @visited_blocks.add(block.ref)

        @next_block = nil
        compile_block(block)
      end

      side_exit_with_map.each do |stack_map, label|
        asm.bind(label)
        comment "side exit #{stack_map}"
        build_side_exit_with_map(stack_map)
      end

      if @side_exit_label
        asm.bind(side_exit_label)
        comment "side exit"
        build_side_exit
      end

      @code
    end

    def compile_block(block)
      asm.bind(x86_labels[block.ref])

      block.insns.each do |insn|
        raise if @next_block # can only be set on last instruction

        op = insn.opcode
        @disasm << "# #{insn}\n" unless op == :comment
        method = "ir_#{op}"
        send(method, insn)
      rescue
        raise "exception when handling #{insn.inspect}"
      end
    end

    def build_side_exit_with_map(stack_map)
      stack_map.stack_values.each_with_index do |val, idx|
        asm.mov sp_ptr(idx), cast_input(val)
      end

      # update sp
      sp = stack_map.stack_values.size
      asm.lea(:rax, sp_ptr(sp))
      asm.mov(CFP[:sp], :rax)

      # update pc
      asm.mov(:rax, stack_map.pc)
      asm.mov(CFP[:pc], :rax)

      asm.jmp(side_exit_label)
    end

    def build_side_exit
      asm.mov(:rax, STATS.addr_for(:side_exits))
      asm.add(X86.qword_ptr(:rax, 0), 1)

      jit_suffix
      asm.mov :rax, Qundef
      asm.ret
    end

    def side_exit_label
      @side_exit_label ||= asm.new_label
    end

    def side_exit_with_map
      @side_exit_with_map ||= Hash.new do |h, k|
        h[k] = asm.new_label
      end
    end

    def comment(text)
      @disasm << "# #{text}\n"
    end

    def ir_comment(insn)
      comment insn.inputs[0]
    end

    def ir_cfp(insn)
      asm.mov out(insn), CFP
    end

    def ir_load(insn)
      offset = insn.inputs[1] || 0
      size = insn.inputs[2] || 8
      mem = X86.ptr(input(insn), offset, size)
      asm.mov out(insn), mem
    end

    def ir_store(insn)
      inputs = insn.inputs.dup
      value = inputs.pop
      offset = inputs[1] || 0
      size = inputs[2] || 8

      mem = X86.ptr(input(insn), offset, size)
      asm.mov mem, cast_input(value)
    end

    BIN_OPS = %i[
      add
      sub
      shr
      imul

      or xor and
    ]

    BIN_OPS.each do |name|
      define_method(:"ir_#{name}") do |insn|
        out = out(insn)
        asm.mov(out, input(insn, 0))
        asm.emit(name.to_s, out, input(insn, 1))
      end
    end

    {
      add: :o,
      sub: :c,
      imul: :o # FIXME: probably wrong
    }.each do |name, cc|
      define_method(:"ir_#{name}_with_overflow") do |insn|
        value_out = out(insn, 0)
        overflow_out = out(insn, 1)

        emit_set_cc(overflow_out, cc) do
          asm.mov(value_out, input(insn, 0))
          asm.emit(name.to_s, value_out, input(insn, 1))
        end
      end
    end

    def ir_pop_frame(insn)
      asm.add(CFP, CFPStruct.sizeof)
      ec_cfp_ptr = EC[:cfp]
      asm.mov(ec_cfp_ptr, CFP)
    end

    def mov64(dest, value)
      # FIXME: double check this range, can probably support negative
      if (0..(2**31)).cover?(value)
        asm.mov(dest, value)
      else
        asm.mov(:rax, value)
        asm.mov(dest, :rax)
      end
    end

    def ir_push_frame(insn)
      iseq, flags, self_, specval, cref_or_me, pc = inputs(insn)

      next_cfp = -> (member) do
        offset = CFPStruct.offset(member) - CFPStruct.sizeof
        X86.qword_ptr(CFP, offset)
      end

      sp = insn.props[:sp]

      mov64(sp_ptr(sp + 0), cref_or_me)
      mov64(sp_ptr(sp + 1), specval)
      mov64(sp_ptr(sp + 2), flags)

      mov64(next_cfp[:pc], pc)
      mov64(next_cfp[:iseq], iseq)
      mov64(next_cfp[:block_code], 0)
      mov64(next_cfp[:jit_return], 0)

      asm.mov(next_cfp[:self], self_)

      asm.lea(:rax, sp_ptr(sp + 3))
      asm.mov(next_cfp[:sp], :rax)
      asm.mov(next_cfp[:__bp__], :rax)
      asm.sub(:rax, 8)
      asm.mov(next_cfp[:ep], :rax)

      asm.lea(:rax, X86.qword_ptr(CFP, -CFPStruct.sizeof))
      asm.mov(EC[:cfp], :rax)
    end

    def preserve_regs(insn)
      preserve_regs = insn.props[:preserve_regs]
      #preserve_regs.map! { @regs.fetch(_1) }

      odd = preserve_regs.size.odd?

      preserve_regs.each do |reg|
        asm.push(reg)
      end
      asm.sub(:rsp, 8) if odd

      yield

      asm.add(:rsp, 8) if odd
      preserve_regs.reverse_each do |reg|
        asm.pop(reg)
      end
    end

    def ir_c_call(insn)
      ptr = insn.inputs[0]

      preserve_regs(insn) do
        # FIXME: this can clobber the regs in use :(
        inputs(insn)[1..].each_with_index do |var, i|
          reg = C_ARG_REGS[i] or raise("too many args")

          asm.mov(reg, var)
        end

        asm.call(ptr)
      end

      asm.mov(out(insn), :rax)
    end

    def ir_call_jit_func(insn)
      ptr = input(insn)

      if IR::BlockRef === ptr
        ptr = x86_labels[ptr]
      end

      raise "call to null pointer" if ptr == 0
      raise "call to nil pointer??" if ptr.nil?

      preserve_regs(insn) do
        callee_cfp = X86.qword_ptr(CFP, -CFPStruct.sizeof)
        asm.lea(:rsi, callee_cfp)
        asm.mov(:rdi, EC)

        asm.call(ptr)
      end

      asm.mov(out(insn), :rax)
      # FIXME: side exit if Qnil
    end

    def ir_breakpoint(insn)
      asm.int3
    end

    def ir_assign(insn)
      asm.mov(out(insn), input(insn))
    end

    def ir_param(insn)
      if out(insn) == C_ARG_REGS[input(insn)]
        # good
      else
        raise "wrong reg assigned to param"
      end
    end

    def self.cmp_cc(op)
      case op
      when :eq then "e"  # equal
      when :ne then "ne" # not equal

      when :slt then "l"  # signed less than
      when :sle then "le" # signed less than or equal
      when :sgt then "g" # signed greater than
      when :sge then "ge" # signed greater than or equal
      else
        raise "not implemented: #{op.inspect}"
      end
    end
    def cmp_cc(...) = self.class.cmp_cc(...)

    def invert_cc(cc)
      case cc.to_s
      when "l" then "ge"
      when "ge" then "l"
      when "le" then "g"
      when "g" then "le"

      when "z", "e" then "nz"
      when "nz", "ne" then "z"
      else
        raise "not implemented: #{cc.inspect}"
      end
    end

    #def next_insn_pos
    #  pos = @pos + 1
    #  while pos < @ir.insns.size && IR::COMMENT === @ir.insns[pos]
    #    pos += 1
    #  end
    #  pos
    #end

    #def next_insn
    #  @ir.insns[next_insn_pos]
    #end

    def emit_direct_jump(block)
      x86_label = x86_labels[block]
      if @visited_blocks.include?(block)
        asm.jmp x86_label
      else
        comment "jmp #{x86_label}"
        @next_block = block
      end
    end

    def emit_br_cc(cc, label_if, label_else)
      if @visited_blocks.include?(label_else) && @visited_blocks.include?(label_if)
        # Swap order so that the not yet compiled block comes next
        label_if, label_else, cc = label_else, label_if, invert_cc(cc)
      end

      x86_label_if = x86_labels[label_if]

      asm.emit "j#{cc}", x86_label_if
      emit_direct_jump(label_else)
    end

    def ir_icmp(insn)
      a, op, b = inputs(insn)
      cc = cmp_cc(op)
      out = out(insn)

      emit_set_cc(out, cc) do
        asm.cmp(a, b)
      end
    end

    def ir_rtest(insn)
      val = input(insn)
      output = out(insn)

      emit_set_cc(output, "nz") do
        asm.test(val, ~Qnil)
      end
    end

    def ir_rbool(insn)
      val = input(insn)
      output = out(insn)
      scratch = :rax

      asm.test(val, val)
      asm.mov(output, Qfalse)
      asm.mov(scratch, Qtrue)
      asm.cmovne(output, scratch)
    end

    def ir_bind(insn)
      label = input(insn)
      asm.bind x86_labels[label]
    end

    def ir_br_cond(insn)
      cond, label_if, label_else = inputs(insn)

      with_flag_input(cond) do |cc|
        emit_br_cc(cc, label_if, label_else)
      end
    end

    # Unconditional branch
    def ir_br(insn)
      label = input(insn)
      emit_direct_jump(label)
    end

    def ir_update_pc(insn)
      scratch = :rax
      asm.mov(scratch, input(insn))
      asm.mov(CFP[:pc], scratch)
    end

    def ir_update_sp(insn)
      scratch = :rax

      input_sp = input(insn)

      asm.lea(scratch, sp_ptr(insn.props.fetch(:sp)))
      asm.mov(CFP[:sp], scratch)
    end

    def sp_ptr(offset)
      X86.ptr(BP, offset * 8, 8)
    end

    def ir_vm_push(insn)
      asm.mov sp_ptr(insn.props[:sp]), input(insn)
    end

    def ir_vm_pop(insn)
      if insn.outputs.empty?
      else
        asm.mov out(insn), sp_ptr(insn.props.fetch(:sp))
      end
    end

    def emit_set_cc(out, cc)
      yield
      unless Pass::X86AllocateRegisters::EFlag === out
        asm.emit("set#{cc}", :al)
        asm.movzx(out, :al)
      end

      #if next_insn.name == :br_cond && next_insn.inputs[0] == cmp_insn.output
      #  br_insn = next_insn
      #  @pos = next_insn_pos

      #  cond, label_if, label_else = inputs(br_insn)

      #  @disasm << "# #{br_insn} (merged)\n"
      #  asm.cmp(a, b)
      #  emit_br_cc(cc, label_if, label_else)
      #end
    end

    def ir_test_fixnum(insn)
      reg = input(insn)
      emit_set_cc(out(insn), "nz") do
        asm.test reg, 1
      end
    end

    def with_flag_input(input)
      if Pass::X86AllocateRegisters::EFlag === input
        yield input.cc
      else
        asm.test input, input
        yield :nz
      end
    end

    def ir_guard_not(insn)
      with_flag_input(input(insn, 0)) do |cc|
        asm.emit "j#{cc}", side_exit_with_map[insn.input(1)]
      end
    end

    def ir_guard(insn)
      with_flag_input(input(insn, 0)) do |cc|
        cc = invert_cc(cc)
        asm.emit "j#{cc}", side_exit_with_map[insn.input(1)]
      end
    end

    def ir_side_exit(insn)
      asm.jmp side_exit_with_map[insn.input(0)]
    end

    def set_bp_from_cfp
      asm.mov(BP, CFP[:__bp__])
    end

    def ir_jit_prelude(insn)
      # Save callee-saved regs
      asm.push(BP)
      asm.push(CFP)
      asm.push(EC)

      asm.mov(CFP, :rsi)
      asm.mov(EC, :rdi)
      set_bp_from_cfp
    end

    def jit_suffix
      asm.pop(EC)
      asm.pop(CFP)
      asm.pop(BP)
    end

    def ir_jit_return(insn)
      jit_suffix

      asm.mov :rax, input(insn)
      asm.ret
    end

    def ir_ret(insn)
      asm.mov :rax, input(insn)
      asm.ret
    end

    def out(insn, n=nil)
      if n
        @regs.fetch(insn.outputs[n] || raise)
      else
        @regs.fetch(insn.output)
      end
    end

    def inputs(insn)
      insn.inputs.size.times.map do |i|
        input(insn, i)
      end
    end

    def cast_input(x)
      case x
      when IR::OutOpnd
        @regs.fetch(x)
      else
        x
      end
    end

    def input(insn, index=0)
      x = insn.inputs[index]
      cast_input(x)
    end
  end
end
