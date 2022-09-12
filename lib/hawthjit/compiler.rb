module HawthJit
  class Compiler
    class Operand
      attr_reader :value

      def initialize(decl, value)
        @decl = decl
        @value = value
      end

      def name
        @decl[:name]
      end

      def type
        @decl[:type]
      end

      def insn_inspect
        "#{name}=#{inspect_value}"
      end

      ID2SYM = Fiddle::Function.new(Fiddle.dlopen(nil)["rb_id2sym"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)

      class CallInfo
        attr_reader :argc, :flag, :mid, :sym
        def initialize(ci)
          @argc = C.vm_ci_argc(ci)
          @flag = C.vm_ci_flag(ci)

          ptr = ci.to_i
          if ptr[0]
            # embedded
            @mid = ptr >> 32
          else
            binding.irb
          end
          @sym = Fiddle.dlunwrap(ID2SYM.call(@mid))
        end

        def inspect
          "call_info(mid: #{sym}, argc: #{argc}, flag: #{flag})"
        end
      end

      class CallCache
        def initialize(cc)
          @cc = cc
        end

        def inspect
          if @cc.klass && @cc.cme_
            "call_cache(full)"
          else
            "call_cache(empty)"
          end
        end
      end

      def inspect_value
        case type
        when "VALUE"
          Fiddle.dlunwrap(value).inspect
        when "lindex_t"
          value
        when "CALL_DATA"
          cd = C.CALL_DATA.new(value)
          ci = CallInfo.new cd.ci
          cc = CallCache.new cd.cc
          [ci, cc].inspect
        else
          "(#{type})#{value}"
        end
      end
    end

    class Insn
      attr_reader :insn, :operands
      def initialize(insn, operands)
        @insn = insn
        @operands = operands
      end

      def name
        insn.name
      end

      def [](name)
        name = name.to_s
        operand = operands.detect { |x| x.name == name }
        operand.value
      end

      def inspect
        segments = [name, *operands.map(&:insn_inspect)]
        "#<#{self.class} #{segments.join(" ")}>"
      end
    end

    INSNS = RubyVM::MJIT.const_get(:INSNS)

    attr_reader :iseq
    alias iseq_ptr iseq

    def body
      iseq.body
    end

    X86 = AsmJIT::X86
    attr_reader :asm
    def initialize(iseq)
      @iseq = iseq
      @code = AsmJIT::CodeHolder.new
      @asm = X86::Assembler.new(@code)
    end

    def insns
      return @insns if @insns

      insns = []
      pos = 0
      while pos < body.iseq_size
        insn = INSNS.fetch(C.rb_vm_insn_decode(body.iseq_encoded[pos]))
        operands = insn.opes.map.with_index do |type, i|
          Operand.new(
            type,
            body.iseq_encoded[pos + i + 1]
          )
        end
        insns << Insn.new(insn, operands)
        pos += insn.len
      end

      @insns = insns
    end

    CantCompile = Class.new(StandardError)

    def compile_entry
    end

    def compile_getlocal_WC_0(insn)
      cfp_reg = :rsi
      cfp_sp_ptr = X86.qword_ptr(cfp_reg, 0x8)
      asm.mov(:rax, cfp_sp_ptr) # sp = cfp->sp
      local0_offset = -(insn[:idx] + 1) * 8
      asm.mov(:rax, X86.qword_ptr(:rax, local0_offset))
      asm.push(:rax)
    end

    def compile_leave(insn)
      ec_reg = :rdi
      ec_cfp_ptr = X86.qword_ptr(ec_reg, 0x10)
      asm.add(ec_cfp_ptr, 0x40)

      asm.pop(:rax)
      asm.ret
    end

    def compile_putobject(insn)
      value = insn.operands[0].value
      asm.push(value)
    end

    def compile_opt_mult(insn)
      # FIXME: Assumes fixnum * fixnum
      asm.pop(:rax)
      asm.pop(:rcx)

      asm.shr(:rax, 1)
      asm.sub(:rcx, 1)
      asm.imul(:rax, :rcx)
      asm.or(:rax, 1)

      asm.push(:rax)
    end

    def compile_insn(insn)
      visitor_method = :"compile_#{insn.name}"
      raise CantCompile unless respond_to?(visitor_method)
      send(visitor_method, insn)
    end

    ALLOWLIST = %w[
      double fib
    ]

    def compile
      label = iseq.body.location.label
      pp iseq.body.location
      if ALLOWLIST.include? label
        puts "JIT compiling #{label.inspect}@#{iseq_ptr}"
        pp insns
        pp insns.map(&:name).sort.uniq

        compile_entry
        insns.each do |insn|
          compile_insn(insn)
        rescue CantCompile
          puts "failed to compile #{insn.inspect}"
          return nil
        end

        @code.to_ptr
      end
    end
  end
end
