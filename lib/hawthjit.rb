# https://github.com/jhawthorn/asmjit-ruby
require "asmjit"

module HawthJit
  C = RubyVM::MJIT.const_get(:C)

  CPointer = RubyVM::MJIT.const_get(:CPointer)
  CType = RubyVM::MJIT.const_get(:CType)

  Qtrue = Fiddle.dlwrap(true)
  Qfalse = Fiddle.dlwrap(false)
  Qnil = Fiddle.dlwrap(nil)

  # FIXME: Is there a non-hardcoded way to get this?
  Qundef = 0x34

  def self.compile(iseq_ptr)
    Compiler.new(iseq_ptr).compile
  end

  def self.enable
    RubyVM::MJIT.instance_eval do
      def compile(iseq_ptr)
        ptr = HawthJit.compile(iseq_ptr)
        ptr || 0
      end
    end
    RubyVM::MJIT.resume
  end
end

require "hawthjit/asm_struct"
require "hawthjit/compiler"
require "hawthjit/ir"
require "hawthjit/x86_assembler"
require "hawthjit/pass"
