# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/tree_sitter/imports_extractor"

IMPORTS_FIXTURES_DIR = File.expand_path("../../../compiler/spec_data/ruby", __dir__)

def load_imports_fixture(name)
  File.read(File.join(IMPORTS_FIXTURES_DIR, name))
end

describe TreeSitter::ImportsExtractor do
  it "extracts simple require statements with double quotes" do
    code = load_imports_fixture("imports_simple.rb")
    imports = TreeSitter::ImportsExtractor.extract_imports(code)
    _(imports).must_equal ["json", "file_utils"]
  end

  it "extracts require statements with single quotes" do
    code = load_imports_fixture("imports_single_quotes.rb")
    imports = TreeSitter::ImportsExtractor.extract_imports(code)
    _(imports).must_equal ["json", "file_utils"]
  end

  it "extracts mixed quote styles" do
    code = load_imports_fixture("imports_mixed.rb")
    imports = TreeSitter::ImportsExtractor.extract_imports(code)
    _(imports).must_equal ["json", "file_utils", "http/client"]
  end

  it "extracts relative path requires" do
    code = load_imports_fixture("imports_relative.rb")
    imports = TreeSitter::ImportsExtractor.extract_imports(code)
    _(imports).must_equal ["./lib/helper", "../utils/parser"]
  end

  it "returns empty array when no requires" do
    code = load_imports_fixture("imports_none.rb")
    imports = TreeSitter::ImportsExtractor.extract_imports(code)
    _(imports).must_equal []
  end

  it "ignores commented out requires" do
    code = load_imports_fixture("imports_with_comments.rb")
    imports = TreeSitter::ImportsExtractor.extract_imports(code)
    _(imports).must_equal ["json", "file_utils"]
  end

  it "handles indented requires" do
    code = load_imports_fixture("imports_indented.rb")
    imports = TreeSitter::ImportsExtractor.extract_imports(code)
    _(imports).must_equal ["json", "file_utils"]
  end
end
