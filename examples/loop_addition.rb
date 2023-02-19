# time ruby -Ilib --mjit=pause examples/loop_addition.rb

begin
  require "hawthjit"
  HawthJit.enable
rescue LoadError => e
  puts "couldn't load hawthjit: #{e}"
end

x = 0
10_000_000.times { a = 1; x = x+a+1+1+1+1+1+1+1+1+1 }
raise unless x == 100_000_000
