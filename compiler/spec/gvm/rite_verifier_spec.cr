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

  it "verifies fused and fallback method definitions across child IREP 255" do
    [256, 257, 260].each do |count|
      source = String.build do |builder|
        builder << "class BoundaryProbe\n"
        count.times do |method|
          builder << "  def method_#{method}; #{method}; end\n"
        end
        builder << "end\nBoundaryProbe.new\n"
      end
      compile_contract(source) do |bytes|
        RiteVerifier.verify!(bytes, "boundary.rb")
      end
    end
  end

  it "rejects invalid method children and truncated extension instructions" do
    compile_contract("class Probe\n  def item; 1; end\nend\n") do |bytes|
      corrupt_child = bytes.dup
      root_size = (bytes[32].to_u32 << 24) | (bytes[33].to_u32 << 16) |
                  (bytes[34].to_u32 << 8) | bytes[35].to_u32
      class_body = 32 + root_size.to_i
      corrupt_child[class_body + 19] = 255_u8 # TDEF child IREP ordinal
      expect_raises(Exception, "Invalid method-definition operand") do
        RiteVerifier.verify!(corrupt_child, "bad-child.rb")
      end
    end

    compile_contract("1\n") do |bytes|
      corrupt = bytes.dup
      corrupt[48] = 117_u8 # OP_EXT3
      corrupt[49] = 99_u8  # OP_METHOD, short stream has no full operand set
      expect_raises(Exception, "Truncated extension operands") do
        RiteVerifier.verify!(corrupt, "truncated-extension.rb")
      end
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
