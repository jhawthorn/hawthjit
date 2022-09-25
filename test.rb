require "hawthjit"

HawthJit.enable

def double(n)
  n * 2
end

10.times do
  p double(80)
end
