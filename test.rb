require "hawthjit"

HawthJit.enable

def double(n)
  n + n
end

10.times do
  p double(80)
end

p double("a")
