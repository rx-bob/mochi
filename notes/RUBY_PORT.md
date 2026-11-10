# Mochi Crystal-to-Ruby Port Plan

## Overview

This document describes the full migration of the Mochi compiler from Crystal to
standard Ruby (MRI/CRuby) with [Sorbet](https://sorbet.org/) for gradual static
typing.

**Goal:** Replace every Crystal source file under `compiler/src/` with equivalent
Ruby code that produces *byte-identical* build output, ensuring zero regressions
as validated by the existing E2E test suite (32 Playwright tests).

**Why Ruby?** The Mochi component format is already Ruby. Porting the compiler to
Ruby unifies the toolchain, lowers the contributor barrier, and enables the use
of the full Ruby ecosystem (gems, debugging tools, LSP). Sorbet provides
compile-time type safety comparable to Crystal's type system.

**Why Sorbet?** Sorbet provides gradual typing -- files can be adopted
incrementally from `typed: false` to `typed: strict`. It catches nil errors,
wrong argument types, and missing methods at dev time. The `sorbet-runtime`
gem provides runtime type checks via `sig` blocks, and `T::Struct` replaces
Crystal's `struct` with typed, immutable-by-default data classes.

---

## Architectural Decisions

### Directory Layout

```
mochi/
  compiler/              # existing Crystal implementation (kept as reference)
  compiler_rb/           # NEW -- Ruby port
    src/
      mochi.rb           # CLI entry point
      data_models/       # RubyDef, RubyVariable, WebComponent, MochiComponent, ...
      html/              # ConditionalProcessor, EachProcessor, extractors
      ruby/              # Code generators, InjectUtils, RubyRewriter, RubyUnderstander
      tree_sitter/       # FFI bindings + AST extractors
      lexbor/            # FFI bindings + HTML parsing wrappers
      quickjs/           # FFI bindings + Runtime, Opal Compiler/Builder
      caching/           # WarthogDB FFI + Cache
      webcomponents/     # ComponentGenerator
      entrypoints/       # BuildMain, BuilderMan, Compiler (transpiler)
      batteries/         # CoreBattery, SorbetTypesBat
      generated/         # Embedded Ruby fragment strings
      js/                # JsLoggerGenerator
      opal/              # OpalRuntimeGenerator
      tooling/           # DevServer
      initializer.rb
    spec/                # Ported unit tests (Minitest)
    Gemfile
    sorbet/              # Sorbet config + RBI files
      config
      rbi/
        shims/           # Hand-written RBIs for FFI bindings
```

### Sorbet Adoption Strategy

Following https://sorbet.org/docs/adopting:

1. **Phase 1 (Epic 0):** Add `sorbet` and `sorbet-runtime` to Gemfile. Run
   `srb init` to generate `sorbet/config`. Set default sigil to `typed: false`.
2. **Phase 2 (Epics 1-3):** Port data models and pure-string processors at
   `typed: strict`. These have no FFI and are straightforward to type.
3. **Phase 3 (Epics 4-7):** Port FFI-heavy code at `typed: true` initially.
   Write RBI shims in `sorbet/rbi/shims/` for the `ffi` gem bindings. Upgrade
   to `typed: strict` where possible.
4. **Phase 4 (Epics 8-10):** Port orchestration code at `typed: true`, upgrade
   to `typed: strict` after stabilization.
5. **Phase 5 (Epic 11):** Run `srb tc` in CI. All files at minimum `typed: true`,
   core data models and processors at `typed: strict`.

**Sorbet conventions:**
- Use `T::Struct` for immutable data classes (replaces Crystal `struct`)
- Use `sig` on all public methods
- Use `T.nilable(X)` instead of Crystal's `X?`
- Use `T::Array[X]` and `T::Hash[K, V]` for collection types
- Use `T::Enum` for Crystal `enum` types
- Extend `T::Sig` in all classes

### Key Porting Decisions

| Crystal Feature | Ruby + Sorbet Equivalent |
|---|---|
| `@[Link]` / `lib` FFI | `ffi` gem (`FFI::Library`, `attach_function`) |
| `OptionParser` | Ruby stdlib `optparse` |
| `Channel` / `spawn` concurrency | Sequential (or `Parallel` gem later) |
| `String.build { \|s\| s << }` | `StringIO` or `String` concatenation / `Array#join` |
| Crystal `property` | `attr_accessor` + Sorbet `sig` |
| Crystal `struct` | `T::Struct` (Sorbet) |
| `enum` | `T::Enum` (Sorbet) |
| Crystal macros (`{% begin %}`) | Not needed |
| Crystal `Lexbor` shard | Direct Lexbor C FFI via `ffi` gem |
| `Digest::MD5` | Ruby stdlib `digest/md5` |
| `HTTP::Server` | `webrick` (stdlib) or `rackup` gem |
| `JSON.parse` | Ruby stdlib `json` |
| Crystal `Time.measure` | `Process.clock_gettime(Process::CLOCK_MONOTONIC)` |
| Crystal `record` | `T::Struct` (Sorbet) |
| Crystal `abstract class` | `abstract!` + `sig(:abstract)` (Sorbet) |
| Crystal `Nil` union types | `T.nilable(X)` (Sorbet) |

### Regression Strategy

At every epic boundary:

1. Build `devground/components` with **both** the Crystal compiler and the new
   Ruby compiler.
2. `diff` the output `bundle.js` and `runtime.js` files. They must be identical.
3. Run `task e2e` (Playwright tests) against the Ruby-produced output.
4. Run ported unit specs via Minitest.
5. Run `srb tc` -- zero Sorbet errors.

A `Taskfile.yml` entry `run-ruby` will be added so both compilers can be
invoked easily.

---

## Dependency Graph (Port Order)

```
Epic 0: Scaffolding
  |
  v
Epic 1: Data Models  (no deps)
  |
  v
Epic 2: HTML Text Processors  (no C deps, pure string/regex)
  |
  v
Epic 3: Ruby Code Generators  (depends on 1, 2)
  |             |
  |             v
  |    Epic 4: Tree-Sitter FFI + AST Extractors
  |             |
  |             v
  |    Epic 5: Lexbor FFI + BindExtractor
  |             |
  v             v
Epic 6: QuickJS FFI + Opal Compilation
  |
  v
Epic 7: Caching (WarthogDB FFI)
  |
  v
Epic 8: Component Generator  (depends on 5, 1)
  |
  v
Epic 9: Build Pipeline  (depends on 3, 4, 5, 6, 7, 8)
  |
  v
Epic 10: CLI & Tooling  (depends on 9)
  |
  v
Epic 11: E2E Verification & Cutover
```

---

## Epic 0: Project Scaffolding & Ruby/Sorbet Setup

**Goal:** Set up the project structure, Bundler, Sorbet, and regression test
harness so all subsequent epics have a stable foundation.

### Story 0.1: Initialize Bundler and Gemfile

**Details:**
Create `compiler_rb/Gemfile` with:
```ruby
source "https://rubygems.org"

gem "sorbet-runtime"
gem "ffi"

group :development do
  gem "sorbet"
  gem "tapioca"
  gem "minitest"
  gem "rake"
end
```

Run `bundle install` to generate `Gemfile.lock`.

**Acceptance Criteria:**
- `cd compiler_rb && bundle install` succeeds
- `Gemfile.lock` committed to repo

### Story 0.2: Initialize Sorbet

**Details:**
Run `cd compiler_rb && bundle exec srb init` to generate the `sorbet/` directory
with `config` file and initial RBI files. Configure `sorbet/config` to point at
`src/`:
```
--dir
src/
```

Run `bundle exec tapioca init` to generate RBI files for gems.

**Acceptance Criteria:**
- `sorbet/config` exists and targets `src/`
- `bundle exec srb tc` runs without crash (errors OK at this stage)
- `sorbet/rbi/gems/` contains generated RBIs for `ffi` and `sorbet-runtime`

### Story 0.3: Create compiler_rb Directory Structure

**Details:**
Create the full `compiler_rb/src/` directory tree as specified in the layout
above. Add a minimal `compiler_rb/src/mochi.rb`:
```ruby
# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Mochi
  extend T::Sig

  sig { void }
  def self.main
    puts "Mochi Ruby v0.1"
  end
end

Mochi.main
```

Add a Taskfile entry `run-ruby` that runs the Ruby-based Mochi compiler.

**Acceptance Criteria:**
- All directories listed in the layout exist (even if empty)
- `task run-ruby` runs `bundle exec ruby compiler_rb/src/mochi.rb`
- Output: "Mochi Ruby v0.1"
- `bundle exec srb tc` passes on `mochi.rb`

### Story 0.4: Set Up Regression Test Harness

**Details:**
Create a script `scripts/regression_test.sh` that:
1. Builds `devground/components` with the Crystal compiler (`task run`)
2. Copies `devground/public/bundle.js` to `/tmp/crystal_bundle.js`
3. Builds `devground/components` with the Ruby compiler (`task run-ruby`)
4. Copies `devground/public/bundle.js` to `/tmp/ruby_bundle.js`
5. Runs `diff` between the two outputs
6. Reports pass/fail

Add a Taskfile entry `regression` for this.

**Acceptance Criteria:**
- `task regression` runs both compilers and diffs output
- Currently fails (Ruby compiler not implemented yet) -- this is expected
- Script clearly reports which outputs differ

### Story 0.5: Set Up Minitest Test Runner

**Details:**
Create `compiler_rb/spec/test_helper.rb`:
```ruby
# typed: false
require "minitest/autorun"
require "sorbet-runtime"
```

Create `compiler_rb/Rakefile`:
```ruby
require "rake/testtask"

Rake::TestTask.new(:spec) do |t|
  t.libs << "src" << "spec"
  t.pattern = "spec/**/*_spec.rb"
end

task default: :spec
```

Add a Taskfile entry `specs-ruby`: `cd compiler_rb && bundle exec rake spec`.

**Acceptance Criteria:**
- `compiler_rb/spec/test_helper.rb` exists
- A sample spec `compiler_rb/spec/smoke_spec.rb` passes
- `task specs-ruby` runs all specs

---

## Epic 1: Data Model & Utility Classes

**Goal:** Port all plain data classes that have zero C library dependencies. These
are the building blocks used by every other module. All files `typed: strict`.

### Story 1.1: Port RubyDef

**Details:**
Port `compiler/src/ruby/ruby_def.cr` to `compiler_rb/src/data_models/ruby_def.rb`.

Use `T::Struct`:
```ruby
# typed: strict
class RubyDef < T::Struct
  const :name, T.nilable(String)
  const :file_name, String
  const :class_name, String
  const :body, T::Array[String]
  const :parameters, T::Array[String]
end
```

**Acceptance Criteria:**
- `RubyDef.new(name: "foo", file_name: "bar.rb", class_name: "Bar", body: ["line1"], parameters: ["a", "b"])` creates instance
- All fields readable
- `srb tc` passes
- Spec covers construction and field access

### Story 1.2: Port RubyVariable

**Details:**
Port `compiler/src/ruby/ruby_var.cr` to `compiler_rb/src/data_models/ruby_var.rb`.

```ruby
# typed: strict
class RubyVariable < T::Struct
  const :value, String
  const :exported, T::Boolean
end
```

**Acceptance Criteria:**
- `RubyVariable.new(value: "hello", exported: true)` works
- Spec covers construction

### Story 1.3: Port RubyEndableStatement

**Details:**
Port `compiler/src/ruby/ruby_endable_statement.cr` to
`compiler_rb/src/data_models/ruby_endable_statement.rb`.

Use `T::Enum`:
```ruby
# typed: strict
class RubyEndableStatement < T::Enum
  enums do
    CLASS = new("class")
    MODULE = new("module")
    DEF = new("def")
    # ... etc
  end

  sig { params(input: String).returns(T.nilable(RubyEndableStatement)) }
  def self.get_endable(input)
    # check starts_with? for each
  end
end
```

**Acceptance Criteria:**
- `RubyEndableStatement.get_endable("class Foo")` returns `RubyEndableStatement::CLASS`
- `RubyEndableStatement.get_endable("xyz")` returns `nil`
- Spec covers all statement types
- `srb tc` passes

### Story 1.4: Port WebComponent

**Details:**
Port `compiler/src/webcomponents/web_component.cr` to
`compiler_rb/src/data_models/web_component.rb`.

```ruby
# typed: strict
class WebComponent < T::Struct
  const :name, String
  const :js_code, String
end
```

**Acceptance Criteria:**
- `WebComponent.new(name: "FooWebComp", js_code: "class Foo {}")` works
- Spec covers construction

### Story 1.5: Port MochiComponent

**Details:**
Port `compiler/src/mochi_cmp.cr` to
`compiler_rb/src/data_models/mochi_component.rb`.

```ruby
# typed: strict
class MochiComponent < T::Struct
  const :absolute_path, String
  const :name, String
  const :imports, T::Array[String]
  const :ruby_code, String
  const :web_component, WebComponent
  const :html, String
  const :css, String
end
```

**Acceptance Criteria:**
- Constructor accepts all 7 fields
- All fields readable
- Spec covers construction

### Story 1.6: Port InjectUtils

**Details:**
Port `compiler/src/ruby/inject_utils.cr` to `compiler_rb/src/ruby/inject_utils.rb`.

Class methods: `find_insertion_point`, `find_second_last_end`,
`calculate_insertion_point`, `insert_code`. All pure string manipulation.

All methods get `sig` annotations. File is `typed: strict`.

**Acceptance Criteria:**
- `InjectUtils.find_second_last_end("class Foo\nend\nend", "end")` returns the
  correct index
- `InjectUtils.insert_code("abcdef", 3, "XYZ")` returns `"abcXYZdef"`
- Spec ports the Crystal spec assertions
- `srb tc` passes

---

## Epic 2: HTML Text Processors

**Goal:** Port the five HTML processing classes that use only string manipulation
and regex -- no C library dependencies. All files `typed: strict`.

### Story 2.1: Port ConditionalProcessor

**Details:**
Port `compiler/src/html/conditional_processor.cr` to
`compiler_rb/src/html/conditional_processor.rb`.

This includes four classes:
- `ConditionalResult` (`T::Struct`: html + conditionals array)
- `ConditionalMatch` (`T::Struct`: condition + content_start)
- `ConditionalBlock` (`T::Struct`: condition, content, start_pos, end_pos, content_start_pos, id)
- `ConditionalProcessor` (class methods: `process`, `extract_conditionals`,
  `try_match_if_token`, `try_match_end_token`, `replace_blocks_with_elements`, etc.)

The Crystal `StackFrame` is a private struct -- implement as a `T::Struct`.

Key logic: stack-based parsing of `{if condition}...{end}` blocks in HTML strings.
Replaces blocks with `<!--if-anchor-N-->` comment markers.

**Acceptance Criteria:**
- `ConditionalProcessor.process("{if @show}hello{end}")` returns
  `ConditionalResult` with html containing `<!--if-anchor-0-->`
- Nested conditionals are handled correctly
- Spec ports all Crystal `conditional_processor_spec.cr` test cases
- `srb tc` passes

### Story 2.2: Port EachProcessor

**Details:**
Port `compiler/src/html/each_processor.cr` to
`compiler_rb/src/html/each_processor.rb`.

Includes: `EachResult`, `EachMatch`, `EachBlock`, `EachLoopDef`, `EachProcessor`
-- all as `T::Struct` where applicable.

Key logic: stack-based parsing of `{each @items as item}...{end}` blocks.
Supports optional index: `{each @items as item, idx}`.
Replaces blocks with `<!--each-anchor-N-->`.

**Acceptance Criteria:**
- `EachProcessor.process("{each @items as item}<li>{item.name}</li>{end}")`
  returns `EachResult` with correct `each_blocks` and anchor HTML
- `extract_loop_definition("@items as item, idx")` parses index_name correctly
- Spec ports all Crystal `each_processor_spec.cr` test cases

### Story 2.3: Port AttributeConditionalExtractor

**Details:**
Port `compiler/src/html/attribute_conditional_extractor.cr` to
`compiler_rb/src/html/attribute_conditional_extractor.rb`.

Includes: `ExtractedAttributeConditional`, `AttributeConditionalResult`,
`AttributeConditionalExtractor` -- data classes as `T::Struct`.

Uses regex to find attributes like `class="{if @active}danger{end}"` and
replaces them with `class="{__mochi_attr_cond_0}"` placeholders.

Regex pattern:
```
/([a-zA-Z0-9_\-\:]+)\s*=\s*(["'])((?:(?!\2).)*(?:\{if |\{unless )(?:(?!\2).)*)\2/m
```

**Acceptance Criteria:**
- Extracts attribute conditionals with correct id, original_string, attribute_name
- Replaces with `{__mochi_attr_cond_N}` placeholder
- Spec ports Crystal `attribute_conditional_extractor_spec.cr` test cases

### Story 2.4: Port AttributeHashExtractor

**Details:**
Port `compiler/src/html/attribute_hash_extractor.cr` to
`compiler_rb/src/html/attribute_hash_extractor.rb`.

Includes: `ExtractedAttributeHash`, `AttributeHashResult`,
`AttributeHashExtractor`.

Handles `attr={{...}}` and `attr="{{...}}"` patterns. Replaces with
`attr="{__mochi_attr_hash_N}"`.

**Acceptance Criteria:**
- Both quoted and unquoted `{{...}}` patterns are extracted
- Replacement values are correct
- Spec ports Crystal `attribute_hash_extractor_spec.cr` test cases

### Story 2.5: Port EventArgumentExtractor

**Details:**
Port `compiler/src/html/event_argument_extractor.cr` to
`compiler_rb/src/html/event_argument_extractor.rb`.

Converts `onclick="{method(arg1, arg2)}"` into
`onclick="{method}" data-mochi-arg-0="{arg1}" data-mochi-arg-1="{arg2}"`.

Special values `$event` and `$element` are NOT wrapped in `{}`.

**Acceptance Criteria:**
- Arguments are extracted and converted to `data-mochi-arg-N` attributes
- `$event` and `$element` are handled as special literal values
- Empty parens `method()` produce clean output without data attributes
- Spec ports Crystal `event_argument_extractor_spec.cr` test cases

---

## Epic 3: Ruby Code Generators

**Goal:** Port the four method generator classes and their supporting battery/
fragment infrastructure. These inject computed methods into Ruby component source
code.

### Story 3.1: Port ConditionalMethodGenerator

**Details:**
Port `compiler/src/ruby/conditional_method_generator.cr` to
`compiler_rb/src/ruby/conditional_method_generator.rb`.

Class methods: `inject_methods_into_class`, `generate_all_methods`, `generate_method`.

For each `ConditionalBlock`, generates a method like:
```ruby
def __mochi_cond_0
  @show
end
```

Uses `InjectUtils` to find insertion point before the class-closing `end`.

**Acceptance Criteria:**
- Generated method names match `__mochi_cond_N` pattern
- Methods are injected at the correct position in the Ruby source
- Spec ports Crystal `conditional_method_generator_spec.cr` test cases

### Story 3.2: Port EachMethodGenerator

**Details:**
Port `compiler/src/ruby/each_method_generator.cr` to
`compiler_rb/src/ruby/each_method_generator.rb`.

For each `EachBlock`, generates two methods:
1. `__mochi_each_N_items` -- returns the array
2. `__mochi_each_N_key(item, index)` -- returns the key for keyed diffing
   (contains inline JavaScript via Opal backtick syntax)

**Acceptance Criteria:**
- Both `_items` and `_key` methods generated correctly
- The JavaScript backtick block in `_key` is preserved exactly
- Spec ports Crystal `each_method_generator_spec.cr` test cases

### Story 3.3: Port AttributeMethodGenerator

**Details:**
Port `compiler/src/ruby/attribute_method_generator.cr` to
`compiler_rb/src/ruby/attribute_method_generator.rb`.

Generates `__mochi_attr_cond_N` methods that evaluate attribute conditional
expressions. Uses `ConditionalProcessor.extract_conditionals` internally to
parse the attribute value, then builds Ruby code that concatenates string parts
with conditional blocks.

The `escape_and_interpolate` private method converts `{var}` to `#{var}` for
Ruby string interpolation.

**Acceptance Criteria:**
- Generated methods return the correct interpolated string
- Double quotes in content are escaped
- `{var}` and `{@var}` patterns both converted to Ruby interpolation
- Spec validates generated method output

### Story 3.4: Port AttributeHashGenerator

**Details:**
Port `compiler/src/ruby/attribute_hash_generator.cr` to
`compiler_rb/src/ruby/attribute_hash_generator.rb`.

Generates `__mochi_attr_hash_N` methods that evaluate `{{...}}` hash expressions:
```ruby
def __mochi_attr_hash_0
  _hash = { "danger" => @active, "hidden" => !@visible }
  _hash.select { |k, v| v }.keys.join(" ")
end
```

**Acceptance Criteria:**
- Inner hash is correctly extracted from `{{...}}` delimiters
- Generated method selects truthy keys and joins them
- Spec ports Crystal `attribute_hash_generator_spec.cr` test cases

### Story 3.5: Port Generated Fragment Embedding

**Details:**
The Crystal codebase has `compiler/src/generated/*.cr` files -- auto-generated
modules that embed Ruby source code as string constants. These are generated by
`scripts/fragments_generator.rb` from files in `fragments/batteries/`.

For the Ruby port, create a `FragmentLoader` class at
`compiler_rb/src/batteries/fragment_loader.rb` that reads `.rb` fragment files
at runtime via `File.read`. Map each Crystal fragment module to its corresponding
source file path.

```ruby
# typed: strict
class FragmentLoader
  extend T::Sig

  FRAGMENTS = T.let({
    "mochi_rb" => "fragments/batteries/mochi.rb",
    "app_router_rb" => "fragments/batteries/app_router.rb",
    # ...
  }.freeze, T::Hash[String, String])

  sig { params(name: String).returns(String) }
  def self.load(name)
    path = resolve_path(T.must(FRAGMENTS[name]))
    File.read(path)
  end
end
```

**Acceptance Criteria:**
- `FragmentLoader.load("mochi_rb")` returns the Ruby source code string
- All fragment names from the Crystal `generated/` directory are mapped
- Path resolution works relative to the executable location (same candidate
  search as the Crystal code)

### Story 3.6: Port CoreBattery and SorbetTypesBat

**Details:**
Port `compiler/src/batteries/core_battery.cr` and
`compiler/src/batteries/sorbet_types_battery.cr` to use `FragmentLoader`
instead of the Crystal generated modules.

`CoreBattery.generate(ruby_src_dir)` assembles all fragment strings and writes
`mochi.rb` to the output lib dir.

**Acceptance Criteria:**
- `CoreBattery.generate("/tmp/src")` writes `/tmp/src/lib/mochi.rb`
- The generated file content matches the Crystal compiler's output byte-for-byte
- `SorbetTypesBat.generate("/tmp/src")` writes sorbet type stubs

### Story 3.7: Port RubyRewriter

**Details:**
Port `compiler/src/ruby/ruby_rewriter.cr` to `compiler_rb/src/ruby/ruby_rewriter.rb`.

Methods:
- `extract_lib_path(path)` -- extracts path from `lib/` onwards
- `format_require_path(path)` -- strips `lib/` prefix and `.rb` suffix
- `gen_mochi_ruby_root(components)` -- generates `Root.rb`
- `gen_builtin_component_feather_icon` -- returns fragment via FragmentLoader
- `gen_builtin_mochi_router` -- returns fragment via FragmentLoader
- `gen_builtin_route_component` -- returns fragment via FragmentLoader
- `comment_out_sorbet_signatures(ruby_code)` -- comments out `sig {` lines
- `comment_out_all_sorbet_signatures_in_dir(path)` -- recursive directory walk

**Acceptance Criteria:**
- `gen_mochi_ruby_root` output matches Crystal output for the same components
- `extract_lib_path` and `format_require_path` handle all edge cases
- Sorbet signature commenting produces identical output
- Spec validates each method

### Story 3.8: Port JsLoggerGenerator

**Details:**
Port `compiler/src/js/js_logger.cr` to `compiler_rb/src/js/js_logger.rb`.

Generates JavaScript `il` (internal logger) class with configurable log levels.
Pure string generation.

**Acceptance Criteria:**
- `JsLoggerGenerator.generate` output matches Crystal output byte-for-byte
- Spec validates output

### Story 3.9: Port OpalRuntimeGenerator

**Details:**
Port `compiler/src/opal/opal_runtime_generator.cr` to
`compiler_rb/src/opal/opal_runtime_generator.rb`.

Reads `runtime.js`, `mochi_component.js`, and `signal.js` from the vendor/runtime
directories and concatenates them.

**Acceptance Criteria:**
- `OpalRuntimeGenerator.new.generate(build_dir)` writes `runtime.js`
- Output matches Crystal compiler output byte-for-byte
- Path resolution handles both development and installed locations

---

## Epic 4: Tree-Sitter FFI Bindings & Ruby AST Analysis

**Goal:** Port the tree-sitter C library bindings and all six AST extractor classes.
This is one of the most critical epics because the extractors determine how Mochi
understands component Ruby code.

### Story 4.1: Port Tree-Sitter C FFI Bindings

**Details:**
Port `compiler/src/tree-sitter/bindings.cr` to
`compiler_rb/src/tree_sitter/bindings.rb`.

Use the `ffi` gem to bind against `libtree-sitter` and `libtree-sitter-ruby`:

```ruby
# typed: true
require "ffi"

module TreeSitterBindings
  extend FFI::Library
  ffi_lib "tree-sitter"
  ffi_lib "tree-sitter-ruby"

  # TSPoint struct
  class TSPoint < FFI::Struct
    layout :row, :uint32, :column, :uint32
  end

  # TSNode struct (32 bytes, passed by value)
  class TSNode < FFI::Struct
    layout :context, [:uint32, 4],
           :id, :pointer,
           :tree, :pointer
  end

  attach_function :ts_parser_new, [], :pointer
  attach_function :ts_parser_delete, [:pointer], :void
  attach_function :ts_parser_set_language, [:pointer, :pointer], :bool
  attach_function :ts_parser_parse_string, [:pointer, :pointer, :string, :uint32], :pointer
  attach_function :ts_tree_root_node, [:pointer], TSNode.by_value
  attach_function :ts_tree_delete, [:pointer], :void
  attach_function :ts_node_type, [TSNode.by_value], :string
  attach_function :ts_node_is_null, [TSNode.by_value], :bool
  attach_function :ts_node_child_count, [TSNode.by_value], :uint32
  attach_function :ts_node_named_child_count, [TSNode.by_value], :uint32
  attach_function :ts_node_child, [TSNode.by_value, :uint32], TSNode.by_value
  attach_function :ts_node_named_child, [TSNode.by_value, :uint32], TSNode.by_value
  attach_function :ts_node_child_by_field_name, [TSNode.by_value, :string, :uint32], TSNode.by_value
  attach_function :ts_node_start_byte, [TSNode.by_value], :uint32
  attach_function :ts_node_end_byte, [TSNode.by_value], :uint32
  attach_function :ts_node_start_point, [TSNode.by_value], TSPoint.by_value
  attach_function :ts_node_end_point, [TSNode.by_value], TSPoint.by_value
  attach_function :ts_node_string, [TSNode.by_value], :pointer
  attach_function :tree_sitter_ruby, [], :pointer
end
```

The `ffi` gem handles struct-by-value passing natively -- no C shim needed
(unlike Spinel).

**Acceptance Criteria:**
- Can create a parser, set Ruby language, parse a string, get root node
- `ts_node_type` returns correct node type strings
- `ts_node_child` traversal works
- `ts_node_start_byte` / `ts_node_end_byte` return correct byte offsets
- Test: parse `"class Foo; end"` and verify root node has type `"program"`

### Story 4.2: Port TreeSitter::Node, RubyParser, Tree Wrappers

**Details:**
Port `compiler/src/tree-sitter/ruby_parser.cr` to
`compiler_rb/src/tree_sitter/ruby_parser.rb`.

Three classes:
- `TreeSitter::Node` -- wraps TSNode, provides `type`, `null?`, `child_count`,
  `named_child_count`, `child(i)`, `named_child(i)`, `child_by_field_name(name)`,
  `text` (via source + byte offsets), `each_child`, `each_named_child`
- `TreeSitter::RubyParser` -- creates parser, sets Ruby language, provides `parse(source)`
- `TreeSitter::Tree` -- wraps tree pointer, provides `root_node`

All with `sig` annotations on public methods.

**Acceptance Criteria:**
- `TreeSitter::RubyParser.new.parse("class Foo; end").root_node.type` == `"program"`
- `node.text` returns correct source substring via byte offsets
- `child_by_field_name("name")` returns the correct child
- `each_named_child` iterates correctly
- Spec covers all Node methods

### Story 4.3: Port ClassExtractor

**Details:**
Port `compiler/src/tree-sitter/class_extractor.cr` to
`compiler_rb/src/tree_sitter/class_extractor.rb`.

Methods: `extract_class_names(source)`, `class_name(source)`,
`extract_superclass(source)`.

Traverses AST looking for `"class"` nodes, extracts name (handles simple constants
and `A::B::C` scope resolution).

**Acceptance Criteria:**
- `ClassExtractor.class_name("class MyCounter < MochiBase; end")` returns `"MyCounter"`
- `ClassExtractor.extract_superclass(...)` returns `"MochiBase"`
- Scope resolution `A::B::C` handled correctly
- Spec ports Crystal `class_extractor_spec.cr` test cases

### Story 4.4: Port MethodBodyExtractor

**Details:**
Port `compiler/src/tree-sitter/method_body_extractor.cr` to
`compiler_rb/src/tree_sitter/method_body_extractor.rb`.

`extract_method_bodies(source, class_name)` returns a `Hash` of method name to
`RubyDef`. Finds the class node, visits all `"method"` children, extracts name,
parameters, and body lines using `ts_node_start_point` / `ts_node_end_point`.

**Acceptance Criteria:**
- Extracts `html`, `css`, `initialize`, and user methods correctly
- Body lines match source lines exactly
- Parameters extracted correctly (positional, optional, splat, block, keyword)
- Spec ports Crystal `method_body_extractor_spec.cr` test cases

### Story 4.5: Port PropertyExtractor

**Details:**
Port `compiler/src/tree-sitter/property_extractor.cr` to
`compiler_rb/src/tree_sitter/property_extractor.rb`.

Finds instance variable assignments (`@tag_name = "my-counter"`) and extracts
name/value pairs. Used to extract `@tag_name` from components.

**Acceptance Criteria:**
- `PropertyExtractor.extract_property(source, "@tag_name")` returns the string value
- Handles string, integer, symbol, and constant values
- String content extracted without surrounding quotes
- Spec ports Crystal `property_extractor_spec.cr` test cases

### Story 4.6: Port ImportsExtractor

**Details:**
Port `compiler/src/tree-sitter/imports_extractor.cr` to
`compiler_rb/src/tree_sitter/imports_extractor.rb`.

Finds `require("...")` calls and extracts the path strings.

**Acceptance Criteria:**
- `ImportsExtractor.extract_imports('require "foo"')` returns `["foo"]`
- Handles both single and double quoted strings
- Spec ports Crystal `imports_extractor_spec.cr` test cases

### Story 4.7: Port StringExtractor

**Details:**
Port `compiler/src/tree-sitter/string_extractor.cr` to
`compiler_rb/src/tree_sitter/string_extractor.rb`.

`extract_raw_string_from_def_body(body_lines, name)` extracts the raw string
content from a method body. Handles regular strings, `%Q{...}`, `%q{...}`,
heredocs, and arrays. Falls back to stripping first/last lines and unquoting.

**Acceptance Criteria:**
- Extracts content from `def html; "..."; end`
- Handles `%Q{...}` percent strings
- Handles heredoc syntax
- Fallback extraction works when AST parsing fails
- Spec ports Crystal `string_extractor_spec.cr` test cases

### Story 4.8: Port InstanceVarAnalyzer

**Details:**
Port `compiler/src/tree-sitter/instance_var_analyzer.cr` to
`compiler_rb/src/tree_sitter/instance_var_analyzer.rb`.

This is the most complex extractor. It:
1. Visits all nodes in a class
2. Tracks `attr_accessor` / `attr_writer` / `attr_reader` declarations
3. Tracks instance variable reads/writes and which method they occur in
4. Detects variables bound in HTML (`{@var}` or `{var}` inside `html` method)
5. Classifies each variable as State/Constant/Derived

Includes nested class `VariableInfo` as `T::Struct`:
```ruby
class VariableInfo < T::Struct
  const :name, String
  prop :writes, Integer, default: 0
  prop :reads, Integer, default: 0
  prop :is_bound, T::Boolean, default: false
  prop :attr_mutated, T::Boolean, default: false
  prop :initialized_in_constructor, T::Boolean, default: false
  prop :written_outside_constructor, T::Boolean, default: false
end
```

**Acceptance Criteria:**
- `attr_accessor :count` -> `@count` has `attr_mutated = true`
- `@count` written in `initialize` -> `initialized_in_constructor = true`
- `@count` written in `increment` -> `written_outside_constructor = true`
- `{count}` in html method -> `@count` has `is_bound = true`
- The `category` method returns correct classification
- Spec ports Crystal `instance_var_analyzer_spec.cr` test cases

### Story 4.9: Port RubyUnderstander Facade

**Details:**
Port `compiler/src/ruby/ruby_understander.cr` to
`compiler_rb/src/ruby/ruby_understander.rb`.

Facade that delegates to TreeSitter extractors:
- `class_name(code)` -> `ClassExtractor.class_name(code)`
- `get_imports(rb_file)` -> `ImportsExtractor.extract_imports(rb_file)`
- `extract_method_bodies(rb_file, cls_name)` -> `MethodBodyExtractor.extract_method_bodies(rb_file, cls_name)`
- `get_cmp_name(rb_file, cls_name)` -> `PropertyExtractor.extract_property(rb_file, "@tag_name")`
- `extract_raw_string_from_def_body(body, name)` -> `StringExtractor.extract_raw_string_from_def_body(body, name)`

**Acceptance Criteria:**
- All delegation methods return identical results to the Crystal version
- Spec validates each method with a sample component file

---

## Epic 5: Lexbor FFI & HTML Parsing

**Goal:** Port the Lexbor C library bindings and the classes that depend on HTML
DOM parsing (BindExtractor and the `traverse` method of ComponentGenerator).

### Story 5.1: Port Lexbor C FFI Bindings

**Details:**
Create `compiler_rb/src/lexbor/bindings.rb` with `ffi` gem bindings to the
Lexbor C library (`liblexbor.dylib` / `liblexbor.so`).

```ruby
# typed: true
require "ffi"

module LexborBindings
  extend FFI::Library
  ffi_lib "lexbor"

  attach_function :lxb_html_document_create, [], :pointer
  attach_function :lxb_html_document_parse, [:pointer, :string, :size_t], :int
  attach_function :lxb_html_document_destroy, [:pointer], :pointer
  attach_function :lxb_html_document_body_element, [:pointer], :pointer
  attach_function :lxb_dom_node_first_child, [:pointer], :pointer
  attach_function :lxb_dom_node_next, [:pointer], :pointer
  attach_function :lxb_dom_element_local_name, [:pointer, :pointer], :string
  attach_function :lxb_dom_node_text_content, [:pointer, :pointer], :string
  attach_function :lxb_dom_element_first_attribute, [:pointer], :pointer
  attach_function :lxb_dom_attr_local_name, [:pointer, :pointer], :string
  attach_function :lxb_dom_element_get_attribute, [:pointer, :string, :size_t, :pointer], :string
  attach_function :lxb_dom_element_set_attribute, [:pointer, :string, :size_t, :string, :size_t], :pointer
  attach_function :lxb_dom_element_remove_attribute, [:pointer, :string, :size_t], :int
  # Serialization
  attach_function :lxb_html_serialize_tree_str, [:pointer, :pointer], :int
end
```

Create a thin wrapper class `Lexbor::Document` that provides:
- `parse(html)` -- parse HTML string
- `body` -- get body element
- `inner_html(node)` -- serialize a node's children to HTML string

And `Lexbor::Node` that provides:
- `tag_name` -- element tag name (or `"_text"` / `"_em_comment"`)
- `tag_text` -- text content for text/comment nodes
- `children` -- array of child nodes (ALL children including text/comment)
- `attributes` -- hash of attribute name to value
- `attribute_remove(name)` -- remove an attribute

**IMPORTANT:** The Crystal Lexbor shard's `node.children` includes text and
comment nodes (not just elements). This is critical for path generation. The
Ruby wrapper must replicate this behavior using `lxb_dom_node_first_child` +
`lxb_dom_node_next` traversal.

**Acceptance Criteria:**
- `Lexbor::Document.new.parse("<div>hello</div>").body` returns a node
- `node.children` includes text nodes with `tag_name == "_text"`
- Comment nodes have `tag_name == "_em_comment"` (Lexbor quirk)
- `node.attributes` returns correct key-value pairs
- `attribute_remove` removes the specified attribute
- `inner_html` serialization matches Crystal Lexbor shard output

### Story 5.2: Port BindExtractor

**Details:**
Port `compiler/src/bind_extractor.cr` to `compiler_rb/src/lexbor/bind_extractor.rb`.

Uses Lexbor to:
1. Parse HTML
2. Find all elements (recursive walk collecting all element nodes)
3. Find `bind:` prefixed attributes
4. Remove `bind:` prefix, track bindings
5. Return cleaned HTML (body inner_html)

**Acceptance Criteria:**
- `BindExtractor.extract('<div bind:class="{active}">hi</div>')` returns
  `BindResult` with `bindings == {"active" => "class"}`
- `bind:` prefix removed from output HTML
- Non-bind attributes preserved
- Output HTML body content matches Crystal output
- Spec ports Crystal `bind_extractor_spec.cr` test cases

---

## Epic 6: QuickJS FFI & Opal Compilation

**Goal:** Port the QuickJS JavaScript engine bindings and the Opal compiler
integration. This is what converts Ruby code to JavaScript.

### Story 6.1: Port QuickJS C FFI Bindings

**Details:**
Port `compiler/src/js/qjs_bindings.cr` to `compiler_rb/src/quickjs/bindings.rb`.

Use `ffi` gem to bind QuickJS C functions.

**CRITICAL:** JSValue in QuickJS is a 16-byte struct (tag + value union). The
`ffi` gem supports struct-by-value:

```ruby
class JSValue < FFI::Struct
  layout :u, [:uint8, 8],   # union (int32, float64, pointer)
         :tag, :int64
end
```

Use `JSValue.by_value` for pass/return by value in `attach_function`.

**Acceptance Criteria:**
- Can create runtime + context
- `JS_Eval` executes JavaScript and returns result
- Can read/write global properties
- String conversion works correctly
- Exception handling works
- Memory cleanup doesn't leak

### Story 6.2: Port QuickJS::Value and QuickJS::Error

**Details:**
Port `compiler/src/quickjs/value.cr` and `compiler/src/quickjs/error.cr` to
`compiler_rb/src/quickjs/value.rb` and `compiler_rb/src/quickjs/error.rb`.

`Value` wraps a JSValue, provides: `to_s`, `to_i`, `to_f`, `object?`, `promise?`.

`Error` hierarchy: `Error`, `SyntaxError`, `ReferenceError`, `TypeError`,
`RangeError`, `InternalError`, `EvalError`.

**Acceptance Criteria:**
- `Value#to_s` returns the JavaScript string representation
- `Value#object?` correctly identifies object values
- Error classes exist with correct hierarchy
- Spec covers value conversion and error types

### Story 6.3: Port QuickJS::Runtime

**Details:**
Port `compiler/src/quickjs/runtime.cr` to `compiler_rb/src/quickjs/runtime.rb`.

Key methods: `eval(code)`, `eval_file(path)`, `[](key)` (get global),
`[]=(key, value)` (set global), `set_memory_limit`, `set_gc_threshold`,
`set_max_stack_size`, `run_jobs`, `finalize`.

The `to_js_value` overloads handle String, Int, Float, Bool, Nil, Array, Hash.
In Ruby, use `case value` with `when String`, `when Integer`, etc.

**Acceptance Criteria:**
- `runtime.eval("1 + 2").to_s` returns `"3"`
- `runtime["x"] = "hello"; runtime.eval("x")` returns `"hello"`
- `runtime.eval_file("path/to/file.js")` works
- Memory limits can be set without error
- `finalize` cleans up without crash
- Spec ports Crystal `quickjs_spec.cr` test cases

### Story 6.4: Port QuickJS::Opal::Compiler

**Details:**
Port `compiler/src/quickjs/opal.cr` to `compiler_rb/src/quickjs/opal.rb`.

Loads Opal runtime and parser into QuickJS, then provides `compile(ruby_code,
filename, requirable)` which calls `Opal.compile(...)` inside the JS engine.

Path resolution searches multiple candidate directories for `opal.js` and
`opal-parser.js`.

**Acceptance Criteria:**
- `compiler.compile("puts 'hello'", "test.rb", true)` returns JavaScript code
- Compiled output matches Crystal Opal compiler output exactly
- Path resolution finds vendor files from both development and installed locations
- Spec ports Crystal `opal_spec.cr` test cases

### Story 6.5: Port QuickJS::Opal::Builder

**Details:**
Port `compiler/src/quickjs/opal_builder.cr` to
`compiler_rb/src/quickjs/opal_builder.rb`.

Methods: `add_raw_js(content)`, `add_stdlib(name)`, `compile(code, path)`,
`compile_with_cache(code, path, cache)`, `build(entry_point)`, `finalize`.

The builder accumulates compiled parts in an array and joins them for final
output.

`compile_with_cache` uses MD5 digest of `"path::code"` as cache key. In Ruby,
use stdlib `Digest::MD5.hexdigest(...)`.

**Acceptance Criteria:**
- `builder.add_stdlib("await")` loads the await.js file
- `builder.compile(code, path)` compiles and stores result
- `builder.compile_with_cache` uses cache on repeated calls
- `builder.build(nil)` joins all parts
- Spec ports Crystal `opal_spec.cr` test cases (builder section)

---

## Epic 7: Caching Layer

**Goal:** Port the WarthogDB-backed build cache.

### Story 7.1: Port WarthogDB FFI Bindings

**Details:**
Port `compiler/src/caching/warthog_bindings.cr` and
`compiler/src/caching/warthogdb.cr` using the `ffi` gem:

```ruby
# typed: true
require "ffi"

module WarthogBindings
  extend FFI::Library
  ffi_lib "warthogdb"

  attach_function :warthog_open, [:string], :pointer
  attach_function :warthog_close, [:pointer], :void
  attach_function :warthog_get, [:pointer, :string, :size_t, :pointer], :pointer
  attach_function :warthog_put, [:pointer, :string, :size_t, :string, :size_t], :int
  attach_function :warthog_has, [:pointer, :string, :size_t], :bool
end
```

**Acceptance Criteria:**
- Can open, put, get, has, close a WarthogDB database
- String values round-trip correctly
- Spec tests CRUD operations

### Story 7.2: Port Cache Class

**Details:**
Port `compiler/src/caching/cache.cr` to `compiler_rb/src/caching/cache.rb`.

Creates cache directory at `~/.cache/mochi`, wraps WarthogDB with `has(key)`,
`get(key)`, `put(key, value)`, `close` methods.

**Acceptance Criteria:**
- Cache directory created at `~/.cache/mochi` if missing
- `put("k", "v")` followed by `has("k")` returns true
- `get("k")` returns `"v"`
- `close` doesn't crash
- Spec ports Crystal `warthogdb_spec.cr` test cases

---

## Epic 8: Component Generator

**Goal:** Port the `ComponentGenerator` class -- the heart of Mochi's code
generation. This class takes parsed component metadata and produces the JavaScript
Web Component class definition.

### Story 8.1: Port ComponentGenerator::Binding

**Details:**
Port the `Binding` inner class from `compiler/src/webcomponents/component_generator.cr`.

Use `T::Struct`:
```ruby
# typed: strict
class ComponentGenerator
  class Binding < T::Struct
    const :path, T::Array[Integer]
    const :type, Symbol  # :text, :html, :attr, :anchor
    const :value, String
    const :name, T.nilable(String)  # attribute name for :attr type
  end
end
```

**Acceptance Criteria:**
- `Binding.new(path: [0, 1, 0], type: :text, value: "{count}", name: nil)` works
- All fields accessible
- Spec covers construction

### Story 8.2: Port ComponentGenerator#traverse

**Details:**
Port the `traverse` method that walks the Lexbor DOM tree and builds a list of
`Binding` objects.

Key logic:
- Text nodes (`"_text"`): scan for `{var}` patterns. If the trimmed text is
  exactly `{var}`, use `:html` type (for innerHTML); otherwise `:text` (for
  textContent template replace).
- Comment nodes (`"_em_comment"`): if contains `"if-anchor"` or `"each-anchor"`,
  create `:anchor` binding.
- Element nodes: check attributes for `bind:` (create `:attr` binding, remove
  attribute), skip `on*` attributes, check other attrs for `{var}` patterns.
- Recurse into `node.children` using `each_with_index` to build path arrays.

**CRITICAL:** Path indices are based on `children` which includes ALL child types
(text, comment, element) -- NOT just element children.

**Acceptance Criteria:**
- Text binding detected for `<span>{count}</span>`
- HTML binding detected for pure variable nodes
- Anchor bindings detected for `<!--if-anchor-0-->`
- Attribute bindings detected for `class="{active}"`
- `bind:` attributes handled and removed
- `onclick` attributes skipped
- Path arrays correctly reflect childNodes indices
- Spec validates binding extraction for various HTML inputs

### Story 8.3: Port ComponentGenerator#generate

**Details:**
Port the main `generate` method that produces the full JavaScript Web Component.

Output structure (in order):
1. Template registration block (BEFORE `customElements.define`)
   - Main template + conditional templates (`tifN`) + each templates (`teachN`)
2. Class definition extending `MochiComponent`
   - Constructor: `super()`, `this.element = this`, `this.rubyComp = Opal.ClassName.$new()`
   - `mount(target)`: calls `$__mochi_mounted(this)`, clones template, sets up
     event delegation (click + change), walks bindings to create DOM refs, appends
     CSS, appends to target, calls `$mounted()`, calls `updateAll()`
   - `update_VAR(val)` methods for each reactive variable
   - `syncAttributes()` alias
   - `updateAll()` method
   - `observedAttributes` + `attributeChangedCallback` for public reactive vars
   - `updateDerived()` for conditionals and each blocks
3. `customElements.define('tag-name', ClassWebComp)`

All JavaScript is generated via string concatenation (no template engine).

**IMPORTANT:** Backtick characters in CSS/HTML must be escaped (`\``). `${`
must be escaped to `\${` to prevent template literal interpolation.

**Acceptance Criteria:**
- Generated JS for a sample component matches Crystal output byte-for-byte
- Template registration comes BEFORE `customElements.define`
- Event delegation handles click and change events
- Data-mochi-arg attributes processed correctly
- `$event` and `$element` special values handled
- Reactive update methods generated for each reactive var
- Internal `__mochi_attr_cond_*` and `__mochi_attr_hash_*` vars excluded from
  `observedAttributes`
- Spec ports Crystal `component_generator_spec.cr` test cases

---

## Epic 9: Build Pipeline

**Goal:** Port the three build orchestration classes that tie everything together:
`BuilderMan`, `Compiler`, and `BuildMain`.

### Story 9.1: Port BuilderMan

**Details:**
Port `compiler/src/entrypoints/building/builder_man.cr` to
`compiler_rb/src/entrypoints/builder_man.rb`.

Manages build directories:
- `build_dir` -> `"#{Dir.pwd}/build"`
- `ruby_src_dir` -> `"#{build_dir}/src"`
- `pre_tp_dir` -> `"#{build_dir}/pre_tp"`

Constructor: creates mochi dir if missing, cleans build dir (preserving
`runtime.js`), generates `build_id`.

Methods: `copy_ruby_code_to_pre_tp`, `copy_ruby_code_base` (use
`FileUtils.mkdir_p` and `FileUtils.cp_r` from stdlib instead of shelling out).

**Acceptance Criteria:**
- Constructor creates build directory structure
- Old build artifacts cleaned except `runtime.js`
- `copy_ruby_code_to_pre_tp` copies from input dir to pre_tp
- `copy_ruby_code_base` copies from pre_tp to src
- `build_id` is unique per instantiation
- Spec validates directory creation and file copying

### Story 9.2: Port Compiler (Transpiler)

**Details:**
Port `compiler/src/entrypoints/building/transpiler.cr` to
`compiler_rb/src/entrypoints/transpiler.rb`.

This is the core class that ties together all processing steps.

**`transpile_directory(input_dir, output_dir, builder_man)`:**
1. Glob `input_dir/**/*.rb` files
2. For each file: `transpile_component(rb_file, i, absolute_path)`
3. Write transformed Ruby code back to `builder_man.ruby_src_dir`
4. Comment out Sorbet signatures
5. Generate Root.rb
6. Compile all Ruby to JS via QuickJS::Opal::Builder
7. Assemble bundle.js

**`transpile_component(rb_file, i, absolute_path)`:**
1. Extract class name via RubyUnderstander
2. Extract method bodies (css, html, etc.)
3. Process HTML pipeline:
   a. AttributeHashExtractor -> inject AttributeHashGenerator methods
   b. AttributeConditionalExtractor -> inject AttributeMethodGenerator methods
   c. EventArgumentExtractor
   d. InstanceVarAnalyzer -> determine reactables
   e. ConditionalProcessor -> inject ConditionalMethodGenerator methods
   f. EachProcessor -> inject EachMethodGenerator methods
   g. BindExtractor
4. Inject getter/setter/lifecycle methods
5. Generate WebComponent via ComponentGenerator
6. Return MochiComponent

**NOTE:** Crystal uses `spawn` + `Channel` for parallel file processing. In
Ruby, process files sequentially initially. Parallel processing can be added
later via `Parallel` gem or `Ractor` if needed.

**Acceptance Criteria:**
- `transpile_component` produces identical Ruby code transformations as Crystal
- `transpile_directory` produces identical `bundle.js` as Crystal
- All HTML processing steps applied in correct order
- Getter/setter/lifecycle method injection matches Crystal output
- Spec validates a full component transpilation against expected output

### Story 9.3: Port BuildMain

**Details:**
Port `compiler/src/entrypoints/building/build_main.cr` to
`compiler_rb/src/entrypoints/build_main.rb`.

Orchestrates the 8-step build:
1. Validate input/output directories
2. Copy Ruby code to pre_tp
3. Generate built-in components (feather icon, router, route)
4. Copy pre_tp to src
5. Pack batteries (SorbetTypesBat, CoreBattery)
6. Transpile components
7. Generate Opal runtime
8. Bundle (copy runtime.js + bundle.js to output, append JsLogger)
9. Optional minification (swc)
10. Clean build artifacts

**NOTE:** The Crystal version uses Pftrace for build tracing. For the initial
Ruby port, omit tracing (use `Process.clock_gettime(Process::CLOCK_MONOTONIC)`
for timing). Pftrace integration can be added later.

**Acceptance Criteria:**
- `BuildMain.new.build(input_dir, output_dir, ...)` produces identical output
  to the Crystal compiler
- All 8 build steps execute in order
- Build artifacts cleaned after successful build
- Timing information printed for each step
- Error handling matches Crystal behavior (descriptive error messages)

---

## Epic 10: CLI, Initializer & Dev Server

**Goal:** Port the CLI argument parser, project initializer, and dev server.

### Story 10.1: Port CLI Argument Parser

**Details:**
Port the CLI section of `compiler/src/mochi.cr` to
`compiler_rb/src/mochi.rb`.

Use Ruby stdlib `optparse` (full-featured, unlike Spinel's minimal subset):

```ruby
# typed: strict
require "optparse"

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: mochi [options]"
  opts.on("-i", "--input DIR", "Input directory") { |v| options[:input] = v }
  opts.on("-o", "--output DIR", "Output directory") { |v| options[:output] = v }
  opts.on("--init NAME", "Initialize project") { |v| options[:init] = v }
  opts.on("--minimize", "Minify output") { options[:minimize] = true }
  opts.on("--typecheck", "Run Sorbet typecheck") { options[:typecheck] = true }
  opts.on("--dev", "Start dev server") { options[:dev] = true }
  opts.on("--root DIR", "Root directory") { |v| options[:root] = v }
  opts.on("--config FILE", "Config file") { |v| options[:config] = v }
  opts.on("--keep_granular_build_artifacts", "Keep build artifacts") { options[:keep_artifacts] = true }
end.parse!
```

Also port the top-level helper functions: `find_second_last_index`,
`js_to_cr_array`, `generate_build_id`, `print_cmp_start_separator`,
`print_cmp_end_seperator`, `print_separator`.

**NOTE:** `js_to_cr_array` uses `JSON.parse`. Ruby has `json` in stdlib --
just `require "json"` and call `JSON.parse(str)`.

**Acceptance Criteria:**
- `mochi -i ./src -o ./build` triggers build
- `mochi --init MyProject` triggers initializer
- `mochi -h` prints help
- All flags parsed correctly
- Unknown flags produce error message
- Missing required arguments produce error message

### Story 10.2: Port Initializer

**Details:**
Port `compiler/src/initializer.cr` to `compiler_rb/src/initializer.rb`.

Generates scaffold files: Taskfile.yml, Gemfile, index.html,
dev_server_config.json, README.md, MyCounter.rb.

All content is inline strings (heredocs). Uses FragmentLoader for MyCounter.rb.

**Acceptance Criteria:**
- `Initializer.new("my_project")` creates directory with all scaffold files
- Existing directory triggers abort message
- File contents match Crystal output
- Spec validates generated file contents

### Story 10.3: Port DevServer

**Details:**
Port `compiler/src/tooling/dev_server.cr` to
`compiler_rb/src/tooling/dev_server.rb`.

The Crystal version uses `HTTP::Server` from the stdlib. Ruby has `WEBrick` in
stdlib (or `webrick` gem in Ruby 3.x+):

```ruby
# typed: true
require "webrick"

server = WEBrick::HTTPServer.new(Port: 27490, DocumentRoot: root_dir)
# Add route handling from config
```

This is straightforward since Ruby has a full HTTP server in its ecosystem --
no FFI or external process needed (unlike Spinel).

**Acceptance Criteria:**
- `mochi dev --config=config.json --root=./public` starts server on port 27490
- Routes from config are served
- Static files served with correct content types
- Falls back to index.html for root

---

## Epic 11: End-to-End Verification & Cutover

**Goal:** Run the full test suite, fix any discrepancies, benchmark performance,
and prepare for production cutover.

### Story 11.1: Run Full E2E Test Suite

**Details:**
Execute `task e2e` (which internally runs the build followed by Playwright tests)
using the Ruby compiler instead of Crystal.

Ensure all 32 Playwright tests pass:
- Counter components
- Item list (keyed diffing)
- Router
- Feather icons
- Charts
- Slots
- Browser utils
- Ruby imports

**Acceptance Criteria:**
- All 32 E2E tests pass with Ruby-compiled output
- No visual or behavioral differences from Crystal-compiled output

### Story 11.2: Byte-for-Byte Output Comparison

**Details:**
Run both compilers against the same `devground/components` input and diff:
- `bundle.js` -- should be identical
- `runtime.js` -- should be identical

If there are whitespace or ordering differences (due to sequential vs parallel
processing), document them and verify they are semantically equivalent.

**Acceptance Criteria:**
- `diff crystal_bundle.js ruby_bundle.js` reports no differences, OR
- All differences are documented and verified as semantically identical
- E2E tests pass with both outputs

### Story 11.3: Port Crystal Unit Specs to Minitest

**Details:**
Port all 44 Crystal spec files to Ruby Minitest specs.

Each spec file follows the pattern:
```ruby
# typed: false
require_relative "../test_helper"
require_relative "../../src/html/conditional_processor"

class ConditionalProcessorTest < Minitest::Test
  def test_simple_conditional
    result = ConditionalProcessor.process("{if @show}hello{end}")
    assert_includes result.html, "<!--if-anchor-0-->"
  end
end
```

Spec files to port (grouped by module):
- `bind_extractor_spec`
- `conditional_processor_spec`, `conditional_method_generator_spec`
- `html/attribute_conditional_extractor_spec`, `attribute_hash_extractor_spec`
- `html/each_processor_spec`, `event_argument_extractor_spec`
- `ruby/attribute_hash_generator_spec`, `each_method_generator_spec`
- `ruby/ruby_understander_spec`
- `tree-sitter/class_extractor_spec`, `method_body_extractor_spec`,
  `property_extractor_spec`, `imports_extractor_spec`, `string_extractor_spec`,
  `instance_var_analyzer_spec`
- `quickjs/quickjs_spec`, `opal_spec`
- `webcomponents/component_generator_spec`
- `warthogdb_spec`
- Integration specs

**Acceptance Criteria:**
- All ported specs pass
- Test coverage matches Crystal spec coverage
- `task specs-ruby` runs all specs and reports results

### Story 11.4: Sorbet Type Coverage Report

**Details:**
Run `srb tc --metrics-file=sorbet_metrics.json` and document type coverage:
- Number of files at each sigil level (`false`, `true`, `strict`)
- Number of `T.untyped` usages remaining
- Any `T.unsafe` escape hatches and why they exist

Target: all files at minimum `typed: true`, data models and processors at
`typed: strict`.

**Acceptance Criteria:**
- `srb tc` passes with zero errors
- Metrics documented in `notes/RUBY_SORBET_COVERAGE.md`
- No files at `typed: ignore`
- FFI binding files justified if at `typed: true` instead of `strict`

### Story 11.5: Performance Benchmarking

**Details:**
Compare build times between Crystal and Ruby compilers:
1. Cold build (no cache) of `devground/components`
2. Warm build (with cache)
3. Single component transpilation time

Record metrics:
- Total build time (ms)
- Component processing time (ms)
- Opal compilation time (ms)

**NOTE:** Ruby (MRI) will be slower than Crystal's compiled native code. The
bottleneck is QuickJS Opal compilation (same C library, same speed). Measure
to confirm the overhead is acceptable.

**Acceptance Criteria:**
- Benchmark results documented in `notes/RUBY_BENCHMARKS.md`
- Opal compilation time roughly equal (same C backend)
- Total build time overhead quantified (acceptable if < 3x Crystal)

### Story 11.6: Update Taskfile and Documentation

**Details:**
Update `Taskfile.yml`:
- `run-ruby` entry to build with Ruby compiler
- `specs-ruby` entry to run Ruby specs
- `e2e-ruby` entry to build + E2E with Ruby
- `regression` entry to compare outputs

Update `README.md` with Ruby build instructions.

**Acceptance Criteria:**
- All new Taskfile entries work correctly
- README documents how to build with Ruby
- `task run-ruby` is a drop-in replacement for `task run`

### Story 11.7: Cutover Plan

**Details:**
Document the cutover process in `notes/RUBY_CUTOVER.md`:
1. Ensure all E2E tests pass with Ruby compiler
2. Replace `task run` default to use Ruby
3. Keep Crystal compiler available as `task run-crystal` for fallback
4. After N releases with Ruby, remove Crystal compiler code
5. Update CI/CD pipelines
6. Add `srb tc` to CI

**Acceptance Criteria:**
- Cutover plan documented with clear steps
- Rollback procedure documented
- Timeline for Crystal code removal proposed

---

## Appendix A: Class-by-Class Mapping

| Crystal File | Ruby File | Epic | Sorbet Level |
|---|---|---|---|
| `ruby/ruby_def.cr` | `data_models/ruby_def.rb` | 1 | `strict` |
| `ruby/ruby_var.cr` | `data_models/ruby_var.rb` | 1 | `strict` |
| `ruby/ruby_endable_statement.cr` | `data_models/ruby_endable_statement.rb` | 1 | `strict` |
| `webcomponents/web_component.cr` | `data_models/web_component.rb` | 1 | `strict` |
| `mochi_cmp.cr` | `data_models/mochi_component.rb` | 1 | `strict` |
| `ruby/inject_utils.cr` | `ruby/inject_utils.rb` | 1 | `strict` |
| `html/conditional_processor.cr` | `html/conditional_processor.rb` | 2 | `strict` |
| `html/each_processor.cr` | `html/each_processor.rb` | 2 | `strict` |
| `html/attribute_conditional_extractor.cr` | `html/attribute_conditional_extractor.rb` | 2 | `strict` |
| `html/attribute_hash_extractor.cr` | `html/attribute_hash_extractor.rb` | 2 | `strict` |
| `html/event_argument_extractor.cr` | `html/event_argument_extractor.rb` | 2 | `strict` |
| `ruby/conditional_method_generator.cr` | `ruby/conditional_method_generator.rb` | 3 | `strict` |
| `ruby/each_method_generator.cr` | `ruby/each_method_generator.rb` | 3 | `strict` |
| `ruby/attribute_method_generator.cr` | `ruby/attribute_method_generator.rb` | 3 | `strict` |
| `ruby/attribute_hash_generator.cr` | `ruby/attribute_hash_generator.rb` | 3 | `strict` |
| `generated/*.cr` | `batteries/fragment_loader.rb` | 3 | `strict` |
| `batteries/core_battery.cr` | `batteries/core_battery.rb` | 3 | `strict` |
| `batteries/sorbet_types_battery.cr` | `batteries/sorbet_types_battery.rb` | 3 | `strict` |
| `ruby/ruby_rewriter.cr` | `ruby/ruby_rewriter.rb` | 3 | `strict` |
| `js/js_logger.cr` | `js/js_logger.rb` | 3 | `strict` |
| `opal/opal_runtime_generator.cr` | `opal/opal_runtime_generator.rb` | 3 | `strict` |
| `tree-sitter/bindings.cr` | `tree_sitter/bindings.rb` | 4 | `true` |
| `tree-sitter/ruby_parser.cr` | `tree_sitter/ruby_parser.rb` | 4 | `true` |
| `tree-sitter/class_extractor.cr` | `tree_sitter/class_extractor.rb` | 4 | `strict` |
| `tree-sitter/method_body_extractor.cr` | `tree_sitter/method_body_extractor.rb` | 4 | `strict` |
| `tree-sitter/property_extractor.cr` | `tree_sitter/property_extractor.rb` | 4 | `strict` |
| `tree-sitter/imports_extractor.cr` | `tree_sitter/imports_extractor.rb` | 4 | `strict` |
| `tree-sitter/string_extractor.cr` | `tree_sitter/string_extractor.rb` | 4 | `strict` |
| `tree-sitter/instance_var_analyzer.cr` | `tree_sitter/instance_var_analyzer.rb` | 4 | `strict` |
| `ruby/ruby_understander.cr` | `ruby/ruby_understander.rb` | 4 | `strict` |
| `bind_extractor.cr` | `lexbor/bind_extractor.rb` | 5 | `strict` |
| `js/qjs_bindings.cr` | `quickjs/bindings.rb` | 6 | `true` |
| `quickjs/value.cr` | `quickjs/value.rb` | 6 | `true` |
| `quickjs/error.cr` | `quickjs/error.rb` | 6 | `strict` |
| `quickjs/runtime.cr` | `quickjs/runtime.rb` | 6 | `true` |
| `quickjs/opal.cr` | `quickjs/opal.rb` | 6 | `true` |
| `quickjs/opal_builder.cr` | `quickjs/opal_builder.rb` | 6 | `true` |
| `caching/warthog_bindings.cr` | `caching/warthog_bindings.rb` | 7 | `true` |
| `caching/warthogdb.cr` | `caching/warthogdb.rb` | 7 | `true` |
| `caching/cache.cr` | `caching/cache.rb` | 7 | `strict` |
| `webcomponents/component_generator.cr` | `webcomponents/component_generator.rb` | 8 | `strict` |
| `entrypoints/building/builder_man.cr` | `entrypoints/builder_man.rb` | 9 | `strict` |
| `entrypoints/building/transpiler.cr` | `entrypoints/transpiler.rb` | 9 | `strict` |
| `entrypoints/building/build_main.cr` | `entrypoints/build_main.rb` | 9 | `strict` |
| `mochi.cr` | `mochi.rb` | 10 | `strict` |
| `initializer.cr` | `initializer.rb` | 10 | `strict` |
| `tooling/dev_server.cr` | `tooling/dev_server.rb` | 10 | `true` |

## Appendix B: Ruby FFI Notes

### Struct-by-Value Passing
Unlike Spinel, the `ffi` gem handles struct-by-value natively. No C shim layer
is needed for tree-sitter's `TSNode` (32 bytes) or QuickJS's `JSValue` (16
bytes). Use `StructClass.by_value` in `attach_function` declarations.

### Lexbor API
The `ffi` gem's pointer traversal (`lxb_dom_node_first_child` +
`lxb_dom_node_next`) works well for walking all child nodes including text and
comment nodes. The Crystal `lexbor` shard's `_em_comment` quirk for comment
node tag names must be replicated.

### QuickJS Memory Management
QuickJS requires careful `JS_FreeValue` calls. Use Ruby's `ObjectSpace.define_finalizer`
or explicit `close`/`finalize` methods with `ensure` blocks. Consider wrapping
in a class that implements `#close` and works with block form (`QuickJS::Runtime.open do |rt| ... end`).

### RBI Shims for FFI
Sorbet doesn't understand `ffi` gem's `attach_function` DSL natively. Create
hand-written RBI files in `sorbet/rbi/shims/` for each FFI module:

```ruby
# sorbet/rbi/shims/tree_sitter_bindings.rbi
# typed: true
module TreeSitterBindings
  sig { returns(FFI::Pointer) }
  def self.ts_parser_new; end

  sig { params(parser: FFI::Pointer).void }
  def self.ts_parser_delete(parser); end
  # ...
end
```

Use `tapioca` to generate base RBIs for the `ffi` gem itself.

## Appendix C: Advantages Over Spinel Port

| Concern | Spinel | Ruby + Sorbet |
|---|---|---|
| Struct-by-value FFI | Needs C shim layer | Native `ffi` gem support |
| JSON parsing | Hand-rolled (no stdlib) | `require "json"` |
| HTTP server | FFI to C lib or external process | `WEBrick` (stdlib) |
| MD5 hashing | FFI to OpenSSL | `Digest::MD5` (stdlib) |
| Test framework | Custom `assert`/`describe` | Minitest (stdlib) |
| Option parsing | Minimal `optparse` | Full `OptionParser` (stdlib) |
| Type safety | None | Sorbet (`typed: strict`) |
| Debugging | Limited | `debug` gem, `pry`, full Ruby tooling |
| Dependencies | Manual C compilation | Bundler + Gemfile |
| Community | Tiny (experimental compiler) | Large Ruby ecosystem |
| Distribution | Native binary (no runtime needed) | Requires Ruby runtime |

**Trade-off:** The Ruby port requires a Ruby runtime on the user's machine,
unlike Spinel's native binary. This is acceptable because Mochi users already
have Ruby installed (they write components in Ruby). A future optimization
could use `ruby-packer` or `Traveling Ruby` for single-binary distribution.

## Appendix D: Files NOT Ported

These Crystal files are intentionally excluded from the port:

| File | Reason |
|---|---|
| `entrypoints/building/trace_helper.cr` | Pftrace integration deferred |
| `entrypoints/typechecker.cr` | Sorbet integration deferred (ironic, but this is the *component* typechecker, not the compiler's own types) |
| `sorbet/sorbet.cr` | Sorbet integration for component code deferred |
| `ruby/ruby_script_engine.cr` | Legacy, not used in main build path |
| `html/html_binding_extractor.cr` | Legacy, superseded by bind_extractor.cr |
| `js/conditional_block_generator.cr` | Legacy, part of old engine |
| `js/dom_walker_generator.cr` | Legacy, part of old engine |
| `js/reactive_setter_generator.cr` | Legacy, part of old engine |
| `js/runtime_kernel.cr` | Legacy, part of old engine |
| `js/template_generator.cr` | Legacy, part of old engine |
| `tree-sitter/dependency_graph_generator.cr` | Unused in build path |
| `quickjs/builder.cr` | Unused (opal_builder.cr is the active one) |
| `quickjs/callback_registry.cr` | Unused in build path |
| `quickjs/sandbox.cr` | Unused in build path |
