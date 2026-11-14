require "spec"
require "../../src/tooling/dev_server"

describe DevServer do
  it "serves WebAssembly with the streaming compilation media type" do
    DevServer.new.get_content_type("mochi-gvm.wasm").should eq("application/wasm")
  end
end
