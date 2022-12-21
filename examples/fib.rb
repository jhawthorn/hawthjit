# time ruby -Ilib --mjit=pause examples/fib.rb

begin
  require "hawthjit"
  HawthJit.enable(only: [:fib])
rescue LoadError => e
  puts "couldn't load hawthjit: #{e}"
end

def fib(n)
  if n < 2
    return n
  end

  return fib(n-1) + fib(n-2)
end

10.times do
  p fib(32)
end
