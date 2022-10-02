# hawthjit
An(other) experimental pure-Ruby JIT compiler.

This is a pure Ruby JIT compiler for CRuby.
It uses MJIT's experimental "custom compiler" override in order to plug into the VM as well as to read CRuby's internals.
It only works against CRuby's HEAD and so far only with very simple tests.

I built this for a few reasons:
* Test out MJIT's "custom compiler" override
* Test out the Ruby bindings for asmjit: https://github.com/jhawthorn/asmjit-ruby
* Test out some optimizations on IR (still TODO)
* Experiment with method inlining (still TODO)
* See if we can more naturally define YARV instructions in Ruby (still TODO)

It's very incomplete and only takes a moderate interest in correctness and is likely to stay that way.
