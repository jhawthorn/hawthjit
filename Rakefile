require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.ruby_opts = %w[--mjit=pause]
  t.test_files = FileList['test/*_test.rb']
  t.verbose = true
end

task default: :test
