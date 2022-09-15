# https://github.com/jhawthorn/asmjit-ruby
require "asmjit"

module HawthJit
  C = RubyVM::MJIT.const_get(:C)

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

require "hawthjit/compiler"
