# $ ruby --mjit=pause --mjit-wait --mjit-min-calls=5 hawthjit.rb
# 246
# 246
# 246
# 246
# JIT compiling 0x7f88e88894b0
# 246
# 246
# 246
# 246
# 246
# 246

# https://github.com/jhawthorn/asmjit-ruby
require "asmjit"

def asm_double
  x86 = AsmJIT::X86
  code = AsmJIT::CodeHolder.new
  asm = x86::Assembler.new(code)

  # jit_func(rb_execution_context_t *, rb_control_frame_t *)
  #          RDI                       RSI
  ec_reg = :rdi
  cfp_reg = :rsi

  cfp_sp_ptr = x86.qword_ptr(cfp_reg, 0x8)
  asm.mov(:rax, cfp_sp_ptr) # sp = cfp->sp
  local0_offset = -(3 + 1) * 8
  asm.mov(:rax, x86.qword_ptr(:rax, local0_offset))

  asm.sub(:rax, 1)    # remove tag bit
  asm.add(:rax, :rax) # double rax (not safe from overflow ¯\_(ツ)_/¯)
  asm.add(:rax, 1)    # re-add tag bit

  # pop frame
  ec_cfp_ptr = x86.qword_ptr(ec_reg, 0x10)
  asm.add(ec_cfp_ptr, 0x40)

  asm.ret

  code.to_ptr
end

class << RubyVM::MJIT
  def compile(iseq_ptr)
    if iseq_ptr.body.location.label == "double"
      puts "JIT compiling #{iseq_ptr}"
      asm_double
    else
      # Don't jit
      0
    end
  end
end

def double(n)
  n * 2
end

RubyVM::MJIT.resume

10.times do
  p double(123)
end

