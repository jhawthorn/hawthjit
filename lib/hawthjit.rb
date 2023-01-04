# https://github.com/jhawthorn/asmjit-ruby
require "asmjit"
require "benchmark"

module HawthJit
  if !RubyVM::MJIT.enabled?
    raise "MJIT isn't inabled. Ruby must be run with --mjit=pause"
  end

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
    label = iseq_ptr.body.location.label
    if should_compile?(iseq_ptr)
      ret = nil
      time = Benchmark.realtime do
        ret = Compiler.new(iseq_ptr).compile
      end
      if ret && ret != 0
        STDERR.puts "compiled #{label} in %.2f ms\n" % (time * 1000.0)
      end
      ret
    else
      STDERR.puts "skipping #{label}"
    end
  end

  def self.should_compile?(iseq_ptr)
    location = iseq_ptr.body.location
    path = location.pathobj
    path = path[0] if Array === path

    return false if path == __FILE__
    return false if path.start_with?("#{__dir__}/hawthjit/")

    if @allowlist
      label = location.label
      if !@allowlist.include?(label)
        return false
      end
    end

    true
  end

  def self.enable(print_stats: true, only: nil)
    @allowlist = only && only.map(&:to_s)

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
