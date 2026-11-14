# Reproduce compiler/Ruby-surface claims without depending on Cowboy.
# Requires Ruby 2.7+ (beginless Range oracle).
# Run: ruby scripts/research_cowboy_feedback.rb
# Outputs observations, not a green/red assertion that defects should persist.
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
ROOT = File.expand_path('..', __dir__)
COMPILER = File.join(ROOT, 'compiler/mochi')
abort "Use Ruby 2.7+ for the MRI oracle" if (RUBY_VERSION.split(".").first(2).map(&:to_i) <=> [2, 7]) == -1
observations = {ruby_version: RUBY_VERSION, compiler_sha256: Digest::SHA256.file(COMPILER).hexdigest, compile: [], ruby: []}
Dir.mktmpdir('mochi-feedback-review-') do |dir|
  FileUtils.mkdir_p(["#{dir}/lib", "#{dir}/test"])
  def source(body)
    "class ProbeRoot\n  @tag_name = \"probe-root\"\n#{body}\nend\n"
  end
  cases = {}
  [118, 119, 250, 251, 252, 253, 254, 255, 256, 257, 260].each do |count|
    cases["methods_#{count}"] = source((0...count).map { |i| "def m#{i}\n #{i}\nend" }.join("\n") + "\ndef html\n %Q{<p>OK</p>}\nend")
  end
[130, 140].each do |bindings|
  methods = (0...118).map { |i| "def m#{i}\n #{i}\nend" }.join("\n")
  html = Array.new(bindings, '<span>{m0}</span>').join
  cases["methods_118_bindings_#{bindings}"] = source(methods + "\ndef html\n %Q{<div>#{html}</div>}\nend")

  distinct_html = (0...bindings).map do |i|
    %Q{<span data-slot="#{i}">{@seed + #{i}}</span>}
  end.join
  distinct_methods = (0...116).map { |i| "def m#{i}\n #{i}\nend" }.join("\n")
  cases["distinct_methods_118_bindings_#{bindings}"] = source(
    "def initialize\n @seed = 1\nend\n#{distinct_methods}\ndef html\n %Q{<div>#{distinct_html}</div>}\nend"
  )
end
  cases['missing_css_import'] = source('def html; %Q{<p>OK</p>}; end' + "\ndef css\n %Q{@import \"missing.css\";}\nend")
  cases['unbraced_event'] = source('def handle(event); end' + "\ndef html\n %Q{<review-child on:action=\"handle\"></review-child>}\nend")
  cases['state_router'] = source("def initialize\n @screen = 'one'\nend\ndef html\n %Q{<div>{if @screen == 'one'}<p>One</p>{else}<p>Two</p>{end}</div>}\nend")
  cases['stored_range'] = source("def initialize\n range = 0..2\n @value = [1,2,3][range]\nend\ndef html\n %Q{<p>{@value}</p>}\nend")
  cases.each do |name, code|
    File.write("#{dir}/lib/ProbeRoot.rb", code)
    log, status = Open3.capture2e(COMPILER, '-i', dir, '-o', "#{dir}/bundle", chdir: ROOT)
    observation = {name: name, exit: status.exitstatus, diagnostic: log.lines.grep(/unsupported|Exception|Error|ERROR|missing.css/).first(4).map(&:strip)}
    if status.success? && name == 'unbraced_event'
      observation[:template] = JSON.parse(File.read("#{dir}/bundle/components/probe-root.json"))['html_template']
    end
    observations[:compile] << observation
  end
  {
    'array_type' => '[].is_a?(Array)', 'hash_type' => '{}.is_a?(Hash)',
    'integer_type' => '1.is_a?(Integer)', 'float_type' => '1.0.is_a?(Float)',
    'two_argument_slice' => 'a = [1,2,3,4]; n = 2; a[1,n].join(",")',
    'unshift' => 'a = [2,3]; a.unshift(1); a.join(",")',
    'computed_inclusive_slice' => 'a = [1,2,3,4]; n = 2; a[1..n].join(",")',
    'computed_exclusive_slice' => 'a = [1,2,3,4]; n = 3; a[1...n].join(",")',
    'negative_slice' => 'a = [1,2,3,4]; a[1..-1].join(",")',
    'beginless_slice' => 'a = [1,2,3,4]; n = 2; a[..n].join(",")',
    'endless_slice' => 'a = [1,2,3,4]; n = 2; a[n..].join(",")'
  }.each do |name, expression|
    expected = eval(expression).to_s # Only fixed expressions above, never external input.
    File.write("#{dir}/lib/ProbeRoot.rb", source("def value\n #{expression}\nend\ndef html\n %Q{<output>{value}</output>}\nend"))
    File.write("#{dir}/test/probe_test.rb", "Mochi::Test.test(#{name.inspect}) do\n mount 'probe-root'\n assert_text 'output', #{expected.inspect}\nend\n")
    log, status = Open3.capture2e(COMPILER, 'test', '-i', dir, '--browsers=all', chdir: ROOT)
    observations[:ruby] << {name: name, expression: expression, mri: expected, exit: status.exitstatus,
      evidence: log.lines.grep(/PASS|FAIL|unsupported|Exception|Mochi runtime error/).map(&:strip)}
  end
end
puts JSON.pretty_generate(observations)
