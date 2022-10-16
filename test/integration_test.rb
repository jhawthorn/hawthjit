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

  def run_jit(code)
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
      IO.open(3).write Marshal.dump({
        ret: ret
      })
    RUBY
    args = []
    args.concat %W[-I#{lib_path} --mjit=pause --mjit-wait --mjit-verbose] unless no_jit?
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
