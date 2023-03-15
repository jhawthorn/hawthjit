require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "test"
  if RUBY_VERSION < "3.3"
    t.ruby_opts = %w[--mjit=pause]
  else
    t.ruby_opts = %w[--rjit=pause]
  end
  t.test_files = FileList['test/*_test.rb']
  t.verbose = true
end

task default: :test
