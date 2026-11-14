require "spec"
require "file_utils"
require "../../src/gvm/rite_verifier"
require "../../src/gvm/rite_debug_info"

private def compile_contract(source : String, &)
  mrbc = ENV["MRBC"]? || File.expand_path("../../../build_wasm/mruby/src/build/mochi-v2-host/bin/mrbc", __DIR__)
  dir = File.tempname("mochi-verifier")
  Dir.mkdir_p(dir)
  begin
    input = File.join(dir, "contract.rb")
    output = File.join(dir, "contract.mrb")
    File.write(input, source)
    log = IO::Memory.new
    Process.run(mrbc, ["-g", "-o", output, input], output: log, error: log).success?.should be_true
    yield File.read(output).to_slice
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe RiteVerifier do
  it "walks real helper definitions, qualified constants, and next bytecode" do
    compile_contract(<<-RUBY) { |bytes| RiteVerifier.verify!(bytes, "helper.rb") }
module RecordData
  BASE = 7
  def self.build
    total = 0
    [1, 2].each { |item| next if item == 1; total += item }
    [1, 2].map { |item| next BASE if item == 2; item + total }
  end
end
RecordData::BASE
RecordData.build
RUBY
  end

  it "rejects unsupported control flow at its real IREP and authored line" do
    {
      "[1].each { break 3 }"           => "block break",
      "[1].each { return 3 }"          => "nonlocal block return",
      "begin; unknown; rescue; 3; end" => "rescue/ensure",
      "1..3"                           => "Range expressions",
    }.each do |expression, construct|
      compile_contract("class Probe\n  def work\n    #{expression}\n  end\nend\n") do |bytes|
        error = expect_raises(RiteVerifier::Unsupported) { RiteVerifier.verify!(bytes, "probe.rb") }
        error.construct.should contain(construct)
        error.irep_index.should be > 0
        RiteDebugInfo.line_for(bytes, error.irep_index, error.pc).should eq(3)
      end
    end
  end

  it "keeps two-argument array slicing supported" do
    compile_contract("items[1, 2]\n") do |bytes|
      RiteVerifier.verify!(bytes, "slice.rb")
    end
  end

  it "accepts loop jumps but rejects malformed headers and record lengths" do
    compile_contract("i = 0\nwhile i < 4\n i += 1\n next if i == 2\n break if i == 3\nend\n") do |bytes|
      RiteVerifier.verify!(bytes, "loop.rb")
      expect_raises(Exception, "Invalid RITE0400") { RiteVerifier.verify!(bytes[0, 19], "bad.rb") }
      corrupt = bytes.dup
      # IREP starts at20, its first record at32: impossible own-record length.
      corrupt[32] = 0x7f_u8
      expect_raises(Exception, "Invalid IREP length") { RiteVerifier.verify!(corrupt, "bad.rb") }
    end
  end
end
