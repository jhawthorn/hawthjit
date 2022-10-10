begin
  require "hawthjit"
  HawthJit.enable
rescue LoadError
  puts "couldn't load hawthjit"
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
