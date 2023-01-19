# hawthjit
An(other) experimental pure-Ruby JIT compiler.

This is a pure Ruby JIT compiler for CRuby.
It uses MJIT's experimental "custom compiler" override in order to plug into the VM as well as to read CRuby's internals.
It only works on Ruby 3.2 and so far only with very simple tests.

## Goals
* Fast on simple benchmarks
* Utilize MJIT's "custom compiler" override
* Utilize asmjit Ruby bindings: https://github.com/jhawthorn/asmjit-ruby
* Perform optimizations on an intermediate representation
* Support method inlining (still TODO)
* Test out ways to more naturally define YARV instructions in Ruby (still TODO)

## Non-Goals
* Being "production-ready" - This is a toy JIT compiler for fun, learning, and experiments
* Compiler performance - I want to focus the effort that could be spent making the compilation itself fast elsewhere (making the generated code fast)
* Strict correctness - I'd like to have the compiler make realistic checks and guards on types, but I don't want to spend effort on bookkeeping for things like methods being overridden or TracePoint.
