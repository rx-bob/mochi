require "spec"
require "../spec_data_loader"
require "../../src/tree-sitter/imports_extractor"

def get_imports(rb_file : String) : Array(String)
  code = SpecDataLoader.load(rb_file)
  TreeSitter::ImportsExtractor.extract_imports(code)
end

describe TreeSitter::ImportsExtractor do
  it "extracts simple require statements with double quotes" do
    imports = get_imports("ruby/imports_simple.rb")
    imports.should eq ["json", "file_utils"]
  end

  it "extracts require statements with single quotes" do
    imports = get_imports("ruby/imports_single_quotes.rb")
    imports.should eq ["json", "file_utils"]
  end

  it "extracts mixed quote styles" do
    imports = get_imports("ruby/imports_mixed.rb")
    imports.should eq ["json", "file_utils", "http/client"]
  end

  it "extracts relative path requires" do
    imports = get_imports("ruby/imports_relative.rb")
    imports.should eq ["./lib/helper", "../utils/parser"]
  end

  it "returns empty array when no requires" do
    imports = get_imports("ruby/imports_none.rb")
    imports.should eq [] of String
  end

  it "ignores commented out requires" do
    imports = get_imports("ruby/imports_with_comments.rb")
    imports.should eq ["json", "file_utils"]
  end

  it "handles indented requires" do
    imports = get_imports("ruby/imports_indented.rb")
    imports.should eq ["json", "file_utils"]
  end

  it "records literal require boundaries with source locations" do
    calls = TreeSitter::ImportsExtractor.extract_import_calls(
      "require \"json\"\nrequire_relative \"lib/helper\"\n",
      "lib/loader.rb"
    )
    calls.map(&.method).should eq(["require", "require_relative"])
    calls.map(&.path).should eq(["json", "lib/helper"])
    calls.map(&.line).should eq([1, 2])
    calls.map(&.column).should eq([1, 1])
  end

  it "rejects dynamic require paths with Ruby source context" do
    error = expect_raises(TreeSitter::ImportError) do
      TreeSitter::ImportsExtractor.extract_import_calls(
        "name = \"feature\"\nrequire name\n",
        "lib/loader.rb"
      )
    end
    error.message.to_s.should contain("unsupported dynamic Ruby require at lib/loader.rb:2:1")
  end

  it "rejects interpolated require paths with Ruby source context" do
    error = expect_raises(TreeSitter::ImportError) do
      TreeSitter::ImportsExtractor.extract_import_calls(
        "feature = \"chart\"\nrequire \"lib/\#{feature}\"\n",
        "lib/loader.rb"
      )
    end
    error.message.to_s.should contain("interpolated paths cannot be resolved")
    error.message.to_s.should contain("lib/loader.rb:2:1")
  end

  it "rejects load and autoload as unsupported loading expressions" do
    error = expect_raises(TreeSitter::ImportError) do
      TreeSitter::ImportsExtractor.extract_import_calls(
        "load \"lib/feature.rb\"\n",
        "lib/loader.rb"
      )
    end
    error.message.to_s.should contain("unsupported Ruby loading expression 'load' at lib/loader.rb:1:1")

    autoload_error = expect_raises(TreeSitter::ImportError) do
      TreeSitter::ImportsExtractor.extract_import_calls(
        "autoload :Feature, \"lib/feature.rb\"\n",
        "lib/loader.rb"
      )
    end
    autoload_error.message.to_s.should contain("unsupported Ruby loading expression 'autoload'")
  end

  it "rejects empty and multiple require paths" do
    empty = expect_raises(TreeSitter::ImportError) do
      TreeSitter::ImportsExtractor.extract_import_calls("require \"\"\n", "lib/loader.rb")
    end
    empty.message.to_s.should contain("unsupported empty Ruby require")

    multiple = expect_raises(TreeSitter::ImportError) do
      TreeSitter::ImportsExtractor.extract_import_calls(
        "require \"json\", \"date\"\n",
        "lib/loader.rb"
      )
    end
    multiple.message.to_s.should contain("use one literal string path")
  end
end
