# frozen_string_literal: true
# time ruby -Ilib --mjit=pause --mjit-call-threshold=4 examples/so_sieve.rb

# from http://www.bagley.org/~doug/shootout/bench/sieve/sieve.ruby
# from https://github.com/ruby/ruby in benchmark/so_sieve.rb
# adjusted to be JITable

begin
  require "hawthjit"
  HawthJit.enable
rescue LoadError => e
  puts "couldn't load hawthjit: #{e}"
end

num = 1000
count = i = j = 0
count2 = 0
count3 = 0
flags0 = Array.new(8192,1)
k = 0
num.times do
  k += 1
  count = 0
  flags = flags0.dup
  i = 2
  while i<8192
    i += 1
    if flags[i]
      # remove all multiples of prime: i
      j = i*i
      while j < 8192
        j += i
        flags[j] = nil
      end
      count += 1
      count3 += 1
    end
    count2 += 1
  end
end
p(count:, count2:, count3:, i:, j:, k:)
raise "bad result #{count} != 1616" unless count == 1616
