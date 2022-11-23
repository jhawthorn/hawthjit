# https://github.com/jhawthorn/asmjit-ruby
require "asmjit"

module HawthJit
  begin
    C = RubyVM::MJIT.const_get(:C)
  rescue NameError
    raise "MJIT doesn't define a 'C' module. HawthJit requires Ruby trunk?"
  end

  CPointer = RubyVM::MJIT.const_get(:CPointer)
  CType = RubyVM::MJIT.const_get(:CType)

  Qtrue = Fiddle.dlwrap(true)
  Qfalse = Fiddle.dlwrap(false)
  Qnil = Fiddle.dlwrap(nil)

  # FIXME: In the future get this from Fiddle::Qundef
  if Qnil == 0x04
    Qundef = 0x24
  elsif Qnil == 0x08
    Qundef = 0x34
  else
    raise "unknown value for Qnil: #{Qnil}"
  end

  SIZEOF_VALUE = 8

  def self.compile(iseq_ptr)
    Compiler.new(iseq_ptr).compile
  end

  def self.enable(print_stats: true)
    RubyVM::MJIT.instance_eval do
      def compile(iseq_ptr)
        ptr = HawthJit.compile(iseq_ptr)
        ptr || 0
      end
    end
    RubyVM::MJIT.resume

    if print_stats
      at_exit {
        RubyVM::MJIT.instance_eval do
          def compile(iseq_ptr)
            0
          end
        end
        RubyVM::MJIT.pause # doesn't work :(
        HawthJit::STATS.print_stats
      }
    end
  end
end

require "hawthjit/asm_struct"
require "hawthjit/compiler"
require "hawthjit/ir"
require "hawthjit/x86_assembler"
require "hawthjit/pass"
require "hawthjit/stats"
