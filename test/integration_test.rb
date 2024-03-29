require "helper"

class IntegrationTest < HawthJitTest
  def test_fib
    result = run_jit(<<~RUBY, call_threshold: 33)
      def fib(n)
        if n < 2
          n
        else
          fib(n-1) + fib(n-2)
        end
      end

      fib(32)
      fib(32)
    RUBY
    assert_equal 2178309, result[:ret]
  end

  def test_overflow
    result = run_jit(<<~RUBY, call_threshold: 2, only: [:foo])
      def foo(n)
        n + n
      end

      foo(32)
      foo(32)

      [foo(32), foo(2**62 - 1)]
    RUBY
    assert_equal [64, 2 ** 63 - 2], result[:ret]
  end

  def test_uncompiled_iseq_call
    result = run_jit(<<~RUBY, call_threshold: 2, only: [:foo])
      def bar
        1 + 1
      end

      def foo
        bar + 1
      end

      foo
      foo
    RUBY
    assert_equal 3, result[:ret]
    assert_equal 1, result[:stats][:side_exits] unless no_jit?
  end

  def test_compiled_iseq_call
    result = run_jit(<<~RUBY, call_threshold: 2, only: [:foo, :bar])
      def bar
        1 + 1
      end

      def foo
        bar + 1
      end

      10.times {bar}
      foo
      foo
    RUBY
    assert_equal 3, result[:ret]
    assert_equal 0, result[:stats][:side_exits] unless no_jit?
  end

  def test_call_object
    result = run_jit(<<~RUBY, call_threshold: 2)
      class A
        def a
          self
        end
      end

      def foo(x)
        x.a
      end

      A.new.a
      foo(A.new)
      foo(A.new).class.name
    RUBY
    assert_equal "A", result[:ret]
    assert_equal 0, result[:stats][:side_exits] unless no_jit?
  end

  def test_simple_redundancy
    result = run_jit(<<~RUBY, call_threshold: 2)
      def foo(a, b)
        a * (b + 17) + (b + 17)
      end
      foo(1,2)
      foo(1,2)
    RUBY

    assert_equal 38, result[:ret]
    assert_equal 0, result[:stats][:side_exits] unless no_jit?
  end

  def test_cfunc_call
    result = run_jit(<<~RUBY, call_threshold: 2, only: [:foo])
      def foo(x)
        x.reverse
      end

      foo("foo")
      foo("foo")
    RUBY
    assert_equal "oof", result[:ret]
    assert_equal 0, result[:stats][:side_exits] unless no_jit?
  end

  def test_branches_rejoined
    result = run_jit(<<~RUBY, call_threshold: 2, only: [:foo])
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
      [foo(32), foo(3)]
    RUBY
    assert_equal [11, 6], result[:ret]
    assert_equal 0, result[:stats][:side_exits] unless no_jit?
  end

  def test_while_loop
    result = run_jit(<<~RUBY, call_threshold: 2, only: [:foo])
      def foo x
        while x < 5
          x += 1
        end
        x
      end

      foo(0)
      foo(0)
    RUBY
    assert_equal 5, result[:ret]
    assert_equal 0, result[:stats][:side_exits] unless no_jit?
  end

  def test_addition_in_loop
    result = run_jit(<<~RUBY, call_threshold: 2)
      x = 0
      10_000.times { x = x+1+1+1+1+1+1+1+1+1+1 }
      x
    RUBY

    assert_equal 100_000, result[:ret]
    assert_equal 0, result[:stats][:side_exits] unless no_jit?
  end

  def test_side_exit
    result = run_jit(<<~RUBY, call_threshold: 2, only: [:foo])
      def foo(n)
        n + n
      end

      10.times { foo(32) }
      foo("foo")
    RUBY
    assert_equal "foofoo", result[:ret]
    assert_equal 1, result[:stats][:side_exits] unless no_jit?
  end

  def run_jit(code, call_threshold: 2, only: nil)
    lib_path = File.expand_path("../../lib", __FILE__)
    code = <<~RUBY
      if #{!no_jit?}
        require "hawthjit"
        HawthJit.enable(only: #{only.inspect})
      end

      _test_proc = -> {
        #{code}
      }

      ret = _test_proc.call
      h = {}
      h[:ret] = ret
      h[:stats] = HawthJit::STATS.to_h unless #{no_jit?}
      IO.open(3).write Marshal.dump(h)
    RUBY

    args = []
    unless no_jit?
      args.concat %W[-I#{lib_path}]
      if defined?(RubyVM::RJIT)
        args.concat %W[--rjit-pause]
        args << "--rjit-call-threshold=#{call_threshold}"
      else
        args.concat %W[--mjit=pause --mjit-wait --mjit-verbose]
        args << "--mjit-call-threshold=#{call_threshold * 2}"
      end
    end
    args << "-e" << code

    out_r, out_w = IO.pipe
    stats_r, stats_w = IO.pipe

    opt = {}
    opt[:out] = out_w
    opt[:err] = out_w
    opt[3] = stats_w

    pid = spawn(RbConfig.ruby, *args, opt)

    out_w.close
    stats_w.close

    out_th = Thread.new { out_r.read }
    stats_th = Thread.new { stats_r.read }
    _, status = Process.waitpid2(pid)

    out = out_th.value
    stats = stats_th.value

    assert_predicate status, :success?, out

    stats = Marshal.load(stats)

    unless defined?(RubyVM::RJIT)
      assert_includes out, "Successful MJIT finish" unless no_jit?
    end

    assert stats[:stats][:compile_success] > 0, "nothing was compiled" unless no_jit?

    stats
  end

  def no_jit?
    !!ENV["NO_JIT"]
  end
end
