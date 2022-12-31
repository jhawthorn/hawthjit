# ruby -Ilib --mjit=pause --mjit-call-threshold=4 examples/branches_joined.rb

begin
  require "hawthjit"
  HawthJit.enable(only: [:foo])
rescue LoadError => e
  puts "couldn't load hawthjit: #{e}"
end


def foo(n)
  if n < 10
    5
  else
    10
  end + 1
end

10.times do
  foo(32)
end

p [foo(32), foo(3)]
