require "helper"

class IntegrationTest < HawthJitTest
  def test_fib
    result = run_jit(<<~RUBY)
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

  def test_compiled_iseq_call
    result = run_jit(<<~RUBY, call_threshold: 2)
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

  def test_branches_rejoined
    result = run_jit(<<~RUBY, call_threshold: 2)
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


  def test_side_exit
    result = run_jit(<<~RUBY, call_threshold: 2)
      def foo(n)
        n + n
      end

      10.times { foo(32) }
      foo("foo")
    RUBY
    assert_equal "foofoo", result[:ret]
    assert_equal 1, result[:stats][:side_exits] unless no_jit?
  end

  def run_jit(code, call_threshold: nil)
    lib_path = File.expand_path("../../lib", __FILE__)
    code = <<~RUBY
      if #{!no_jit?}
        require "hawthjit"
        HawthJit.enable
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
      args.concat %W[-I#{lib_path} --mjit=pause --mjit-wait --mjit-verbose]
      args << "--mjit-call-threshold=#{call_threshold}"
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

    assert_includes out, "Successful MJIT finish" unless no_jit?

    stats
  end

  def no_jit?
    !!ENV["NO_JIT"]
  end
end
