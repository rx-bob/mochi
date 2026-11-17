require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/row_identity"
require "../../src/tooling/lint_runner"

module LintRowIdentitySpecSupport
  extend self

  def with_project(prefix = "mochi_lint_row_identity", &)
    root = File.join(Dir.tempdir, "#{prefix}_#{Random.new.hex(8)}")
    Dir.mkdir_p(File.join(root, "lib"))
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write(root : String, relative_path : String, source : String) : String
    path = File.join(root, relative_path)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def config(root : String, rules : Hash(String, String)? = nil) : Lint::Config
    yaml = String.build do |io|
      io << "version: 1\n"
      io << "include:\n  - \"lib/**/*.rb\"\n"
      if rules
        io << "rules:\n"
        rules.each { |rule, level| io << "  #{rule}: #{level}\n" }
      end
    end
    write(root, ".mochi-lint.yml", yaml)
    Lint::Config.load(root, true, nil, root)
  end

  def index(root : String, rules : Hash(String, String)? = nil) : Lint::ProjectIndex
    lint_config = config(root, rules)
    files = Lint::FileDiscovery.discover(lint_config.project_root, lint_config)
    Lint::ProjectIndex.build(files, lint_config)
  end

  def diagnostics(root : String, rules : Hash(String, String)? = nil) : Array(Lint::Diagnostic)
    project_index = index(root, rules)
    begin
      Lint::Rules::RowIdentity.diagnostics(project_index)
    ensure
      project_index.close
    end
  end

  def rule(diagnostics : Array(Lint::Diagnostic), id : String) : Array(Lint::Diagnostic)
    diagnostics.select { |diagnostic| diagnostic.rule == id }
  end

  def run_lint(root : String) : Tuple(Int32, String, String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = LintRunner.new.run(["-i", root], stdout, stderr, root)
    {status, stdout.to_s, stderr.to_s}
  end
end

describe Lint::Rules::RowIdentity do
  it "is off by default and reports an explicit index key when enabled" do
    LintRowIdentitySpecSupport.with_project do |root|
      LintRowIdentitySpecSupport.write(root, "lib/IndexRows.rb", <<-RUBY)
        class IndexRows
          @tag_name = "index-rows"

          def html
            %Q{
              {each @rows as row, i, key: i}
                <p>{row["name"]}</p>
              {end}
            }
          end
        end
        RUBY

      LintRowIdentitySpecSupport.diagnostics(root).should be_empty

      diagnostics = LintRowIdentitySpecSupport.rule(
        LintRowIdentitySpecSupport.diagnostics(root, {"templates/unstable-key" => "warning"}),
        Lint::Rules::RowIdentity::RULE,
      )
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.path.should eq "lib/IndexRows.rb"
      diagnostic.start_line.should eq 6
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.message.should eq "each row key uses loop index 'i'; positional identity can associate drafts, focus, or child state with another record after reorder"
      diagnostic.suggestion.should eq "Add an explicit key using a stable domain identity."
    end
  end

  it "accepts an explicit non-index key on a literal reorder" do
    LintRowIdentitySpecSupport.with_project do |root|
      LintRowIdentitySpecSupport.write(root, "lib/KeyedReorder.rb", <<-RUBY)
        class KeyedReorder
          @tag_name = "keyed-reorder"

          def html
            %Q{
              {each [{label: "a"}].reverse as row, key: row["label"]}
                <p>{row["label"]}</p>
              {end}
              {each [{label: "b"}].sort as row, key: row["label"]}
                <p>{row["label"]}</p>
              {end}
            }
          end
        end
        RUBY

      LintRowIdentitySpecSupport.rule(
        LintRowIdentitySpecSupport.diagnostics(root, {"templates/unstable-key" => "warning"}),
        Lint::Rules::RowIdentity::RULE,
      ).should be_empty
    end
  end

  it "accepts stable keys, automatic key/id fields, static menus, and unknown collections" do
    LintRowIdentitySpecSupport.with_project do |root|
      LintRowIdentitySpecSupport.write(root, "lib/StableRows.rb", <<-RUBY)
        class StableRows
          @tag_name = "stable-rows"

          def html
            %Q{
              {each @rows as row, key: row["id"]}
                <p>{row["name"]}</p>
              {end}
              {each @rows as row, key: row_key(row)}
                <p>{row["name"]}</p>
              {end}
              {each @rows as row}
                <p>{row["name"]}</p>
              {end}
              {each rows_for(@rows) as row}
                <p>{row["name"]}</p>
              {end}
              {each ["Home", "Costs"] as item}
                <p>{item}</p>
              {end}
              {each [{id: 1}, {id: 2}].reverse as row}
                <p>{row["name"]}</p>
              {end}
              {each [{key: "a"}].sort as row}
                <p>{row["name"]}</p>
              {end}
              {each [{"id" => 1}, {"id" => 2}].reverse as row}
                <p>{row["name"]}</p>
              {end}
              {each [{:key => "a"}].sort as row}
                <p>{row["name"]}</p>
              {end}
              {each [{label: "a"}].first as row}
                <p>{row["label"]}</p>
              {end}
              {each [row].reverse as row}
                <p>{row["name"]}</p>
              {end}
              {each [{**row}].reverse as row}
                <p>{row["name"]}</p>
              {end}
            }
          end
        end
        RUBY

      LintRowIdentitySpecSupport.rule(
        LintRowIdentitySpecSupport.diagnostics(root, {"templates/unstable-key" => "warning"}),
        Lint::Rules::RowIdentity::RULE,
      ).should be_empty
    end
  end

  it "reports direct reorder and filter operations on literal rows without key/id" do
    LintRowIdentitySpecSupport.with_project do |root|
      LintRowIdentitySpecSupport.write(root, "lib/ReorderedRows.rb", <<-RUBY)
        class ReorderedRows
          @tag_name = "reordered-rows"

          def html
            %Q{
              {each [{label: "a"}, {label: "b"}].reverse as row}
                <p>{row["label"]}</p>
              {end}
              {each ["b", "a"].sort as item}
                <p>{item}</p>
              {end}
              {each %w[b a].sort as item}
                <p>{item}</p>
              {end}
              {each [{label: "a"}].sort.reverse as row}
                <p>{row["label"]}</p>
              {end}
              {each [{label: "a"}].filter as row}
                <p>{row["label"]}</p>
              {end}
            }
          end
        end
        RUBY

      diagnostics = LintRowIdentitySpecSupport.rule(
        LintRowIdentitySpecSupport.diagnostics(root, {"templates/unstable-key" => "warning"}),
        Lint::Rules::RowIdentity::RULE,
      )
      diagnostics.size.should eq 5
      diagnostics[0].message.should contain "uses 'reverse' on literal rows without a key or id"
      diagnostics[0].message.should contain "positional identity can associate drafts, focus, or child state with another record after reorder"
      diagnostics[1].message.should contain "uses 'sort' on literal rows without a key or id"
      diagnostics[2].message.should contain "uses 'sort' on literal rows without a key or id"
      diagnostics[3].message.should contain "uses 'sort' on literal rows without a key or id"
      diagnostics[4].message.should contain "uses 'filter' on literal rows without a key or id"
    end
  end

  it "resolves index and item names through nested row scopes" do
    LintRowIdentitySpecSupport.with_project do |root|
      LintRowIdentitySpecSupport.write(root, "lib/NestedRows.rb", <<-RUBY)
        class NestedRows
          @tag_name = "nested-rows"

          def html
            %Q{
              {each @groups as group, group_index, key: group["id"]}
                {each group["items"] as item, item_index, key: item_index}
                  <p>{item["name"]}</p>
                {end}
              {end}
              {each @groups as group, group_index, key: group["id"]}
                {each group["items"] as item, item_index, key: group_index}
                  <p>{item["name"]}</p>
                {end}
              {end}
              {each @groups as group, group_index, key: group["id"]}
                {each group["items"] as item, item_index, key: item["id"]}
                  <p>{item["name"]}</p>
                {end}
              {end}
              {each @groups as index, group_index, key: index}
                <p>{index["name"]}</p>
              {end}
            }
          end
        end
        RUBY

      diagnostics = LintRowIdentitySpecSupport.rule(
        LintRowIdentitySpecSupport.diagnostics(root, {"templates/unstable-key" => "warning"}),
        Lint::Rules::RowIdentity::RULE,
      )
      diagnostics.size.should eq 2
      diagnostics[0].message.should contain "loop index 'item_index'"
      diagnostics[1].message.should contain "loop index 'group_index'"
      diagnostics[0].start_byte.should_not eq diagnostics[1].start_byte
    end
  end
end

describe LintRunner do
  it "keeps row identity advice off by default and fails when enabled" do
    LintRowIdentitySpecSupport.with_project do |root|
      LintRowIdentitySpecSupport.write(root, "lib/IndexRows.rb", <<-RUBY)
        class IndexRows
          @tag_name = "index-rows"

          def html
            %Q{
              {each @rows as row, index, key: index}
                <p>{row["name"]}</p>
              {end}
            }
          end
        end
        RUBY

      status, output, error = LintRowIdentitySpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty

      LintRowIdentitySpecSupport.config(root, {"templates/unstable-key" => "warning"})
      status, output, error = LintRowIdentitySpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "templates/unstable-key: each row key uses loop index 'index'"
      error.should be_empty

      LintRowIdentitySpecSupport.config(root, {"templates/unstable-key" => "off"})
      status, output, error = LintRowIdentitySpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
