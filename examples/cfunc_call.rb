# ruby -Ilib --mjit=pause --mjit-call-threshold=4 examples/cfunc_call.rb

begin
  require "hawthjit"
  HawthJit.enable(only: [:foo])
rescue LoadError => e
  puts "couldn't load hawthjit: #{e}"
end


def foo(x)
  x.itself
end

10.times do
  foo(123)
end

p foo(123)
