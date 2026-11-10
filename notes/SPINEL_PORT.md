# Mochi Crystal-to-Spinel Ruby Port Plan

## Overview

This document describes the full migration of the Mochi compiler from Crystal to
[Spinel Ruby](https://github.com/matz/spinel) -- Matz's AOT Ruby compiler that
produces standalone native binaries via C code generation.

**Goal:** Replace every Crystal source file under `compiler/src/` with equivalent
Spinel Ruby code that produces *byte-identical* build output, ensuring zero
regressions as validated by the existing E2E test suite (32 Playwright tests).

**Why Spinel?** Spinel compiles a Ruby subset to native binaries (~11.6x faster
than MRI). It supports classes, inheritance, modules, FFI, regex, File I/O,
`require_relative`, and `optparse` -- everything needed to build a CLI compiler.

---

## Architectural Decisions

### Directory Layout

```
mochi/
  compiler/              # existing Crystal implementation (kept as reference)
  compiler_rb/           # NEW -- Spinel Ruby port
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
    spec/                # Ported unit tests
  runtime/
    spinel/              # git submodule -> https://github.com/matz/spinel
```

### Key Porting Decisions

| Crystal Feature | Spinel Equivalent |
|---|---|
| `@[Link]` / `lib` FFI | Spinel `ffi_*` functions (scalar, string, pointer) |
| `OptionParser` | Spinel `optparse.rb` (in stdlib) |
| `Channel` / `spawn` concurrency | Sequential processing (native speed makes this fine) |
| `String.build { \|s\| s << }` | String concatenation or Array#join |
| Crystal `property` | `attr_accessor` |
| `enum` | Module with constants + methods |
| Crystal macros (`{% begin %}`) | Not needed; FFI paths resolved at runtime |
| Crystal `Lexbor` shard | Direct Lexbor C FFI via Spinel |
| `Digest::MD5` | FFI to OpenSSL or hand-rolled MD5 |
| `HTTP::Server` | FFI to a C HTTP library or external process |
| Crystal `struct` | Ruby class (value semantics enforced by convention) |
| `JSON.parse` | Minimal JSON parser (Spinel has no JSON stdlib) |
| Crystal `Time.measure` | `Process.clock_gettime(Process::CLOCK_MONOTONIC)` |

### Regression Strategy

At every epic boundary:

1. Build `devground/components` with **both** the Crystal compiler and the new
   Spinel compiler.
2. `diff` the output `bundle.js` and `runtime.js` files. They must be identical.
3. Run `task e2e` (Playwright tests) against the Spinel-produced output.
4. Run ported unit specs via Spinel.

A `Taskfile.yml` entry `run-spinel` will be added so both compilers can be
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

## Epic 0: Project Scaffolding & Spinel Integration

**Goal:** Set up the project structure, git submodule, build tooling, and regression
test harness so all subsequent epics have a stable foundation.

### Story 0.1: Add Spinel as Git Submodule

**Details:**
Add `https://github.com/matz/spinel` as a git submodule at `runtime/spinel/`.
Pin to a specific commit (the latest stable tag or commit on `main` at port
start). Update `.gitmodules` accordingly.

**Acceptance Criteria:**
- `git submodule update --init` clones Spinel into `runtime/spinel/`
- `.gitmodules` contains the Spinel entry with the pinned ref
- `runtime/spinel/Makefile` exists and is the upstream file

### Story 0.2: Build Spinel from Source

**Details:**
Add a Taskfile entry `build-spinel` that runs `make deps && make` inside
`runtime/spinel/`. Verify the resulting `spinel` binary can compile a trivial
`hello.rb` to a native executable.

**Acceptance Criteria:**
- `task build-spinel` produces `runtime/spinel/spinel` binary
- `echo 'puts "hello"' > /tmp/hello.rb && runtime/spinel/spinel /tmp/hello.rb && /tmp/hello` prints "hello"

### Story 0.3: Create compiler_rb Directory Structure

**Details:**
Create the full `compiler_rb/src/` directory tree as specified in the layout
above. Add a minimal `compiler_rb/src/mochi.rb` that just prints "Mochi Spinel
v0.1" and exits. Add a Taskfile entry `run-spinel` that compiles and runs the
Spinel-based Mochi compiler.

**Acceptance Criteria:**
- All directories listed in the layout exist (even if empty)
- `task run-spinel` compiles `compiler_rb/src/mochi.rb` with Spinel and runs it
- The binary prints "Mochi Spinel v0.1"

### Story 0.4: Set Up Regression Test Harness

**Details:**
Create a script `scripts/regression_test.sh` that:
1. Builds `devground/components` with the Crystal compiler (`task run`)
2. Copies `devground/public/bundle.js` to `/tmp/crystal_bundle.js`
3. Builds `devground/components` with the Spinel compiler (`task run-spinel`)
4. Copies `devground/public/bundle.js` to `/tmp/spinel_bundle.js`
5. Runs `diff` between the two outputs
6. Reports pass/fail

Add a Taskfile entry `regression` for this.

**Acceptance Criteria:**
- `task regression` runs both compilers and diffs output
- Currently fails (Spinel compiler not implemented yet) -- this is expected
- Script clearly reports which outputs differ

### Story 0.5: Set Up Spinel Unit Test Runner

**Details:**
Establish a test pattern for Spinel specs. Since Spinel doesn't have a built-in
test framework, create a minimal `compiler_rb/spec/test_helper.rb` with `assert`,
`assert_equal`, `assert_nil`, `assert_match`, and `describe`/`it` macros using
simple puts-based reporting. Add a Taskfile entry `specs-spinel` to compile and
run all specs.

**Acceptance Criteria:**
- `compiler_rb/spec/test_helper.rb` exists with assertion helpers
- A sample spec `compiler_rb/spec/smoke_spec.rb` passes
- `task specs-spinel` compiles and runs all `*_spec.rb` files

---

## Epic 1: Data Model & Utility Classes

**Goal:** Port all plain data classes that have zero C library dependencies. These
are the building blocks used by every other module.

### Story 1.1: Port RubyDef

**Details:**
Port `compiler/src/ruby/ruby_def.cr` to `compiler_rb/src/data_models/ruby_def.rb`.

Crystal class has properties: `name : String?`, `file_name : String`,
`class_name : String`, `body : Array(String)`, `parameters : Array(String)`.

In Spinel: use `attr_accessor` for all fields, define `initialize` with the same
arguments.

**Acceptance Criteria:**
- `RubyDef.new("foo", "bar.rb", "Bar", ["line1"], ["a", "b"])` creates instance
- All fields readable and writable
- Spec covers construction and field access

### Story 1.2: Port RubyVariable

**Details:**
Port `compiler/src/ruby/ruby_var.cr` to `compiler_rb/src/data_models/ruby_var.rb`.

Properties: `value : String`, `exported : Bool`.

**Acceptance Criteria:**
- `RubyVariable.new("hello", true)` works
- `to_s` returns a debug representation
- Spec covers construction

### Story 1.3: Port RubyEndableStatement

**Details:**
Port `compiler/src/ruby/ruby_endable_statement.cr` to
`compiler_rb/src/data_models/ruby_endable_statement.rb`.

Crystal uses an `enum`. In Spinel, implement as a module with constants and
class methods:
```ruby
module RubyEndableStatement
  CLASS = "class"
  MODULE = "module"
  DEF = "def"
  # ... etc
  def self.get_endable(input)
    # check starts_with? for each
  end
end
```

**Acceptance Criteria:**
- `RubyEndableStatement.get_endable("class Foo")` returns `"class"`
- `RubyEndableStatement.get_endable("xyz")` returns `nil`
- Spec covers all statement types

### Story 1.4: Port WebComponent

**Details:**
Port `compiler/src/webcomponents/web_component.cr` to
`compiler_rb/src/data_models/web_component.rb`.

Properties: `name : String`, `js_code : String`.

**Acceptance Criteria:**
- `WebComponent.new("FooWebComp", "class Foo {}")` works
- Fields accessible
- Spec covers construction

### Story 1.5: Port MochiComponent

**Details:**
Port `compiler/src/mochi_cmp.cr` to
`compiler_rb/src/data_models/mochi_component.rb`.

Properties: `absolute_path`, `name`, `imports` (Array), `ruby_code`, `web_component`,
`html`, `css`.

**Acceptance Criteria:**
- Constructor accepts all 7 fields
- All fields readable
- Spec covers construction

### Story 1.6: Port InjectUtils

**Details:**
Port `compiler/src/ruby/inject_utils.cr` to `compiler_rb/src/ruby/inject_utils.rb`.

Class methods: `find_insertion_point`, `find_second_last_end`,
`calculate_insertion_point`, `insert_code`. All pure string manipulation.

**Acceptance Criteria:**
- `InjectUtils.find_second_last_end("class Foo\nend\nend", "end")` returns the
  correct index
- `InjectUtils.insert_code("abcdef", 3, "XYZ")` returns `"abcXYZdef"`
- Spec ports the Crystal spec assertions

---

## Epic 2: HTML Text Processors

**Goal:** Port the five HTML processing classes that use only string manipulation
and regex -- no C library dependencies.

### Story 2.1: Port ConditionalProcessor

**Details:**
Port `compiler/src/html/conditional_processor.cr` to
`compiler_rb/src/html/conditional_processor.rb`.

This includes four classes:
- `ConditionalResult` (html + conditionals array)
- `ConditionalMatch` (condition + content_start)
- `ConditionalBlock` (condition, content, start_pos, end_pos, content_start_pos, id)
- `ConditionalProcessor` (class methods: `process`, `extract_conditionals`,
  `try_match_if_token`, `try_match_end_token`, `replace_blocks_with_elements`, etc.)

The Crystal `StackFrame` is a private struct -- implement as a simple class.

Key logic: stack-based parsing of `{if condition}...{end}` blocks in HTML strings.
Replaces blocks with `<!--if-anchor-N-->` comment markers.

**Acceptance Criteria:**
- `ConditionalProcessor.process("{if @show}hello{end}")` returns
  `ConditionalResult` with html containing `<!--if-anchor-0-->`
- Nested conditionals are handled correctly
- Spec ports all Crystal `conditional_processor_spec.cr` test cases

### Story 2.2: Port EachProcessor

**Details:**
Port `compiler/src/html/each_processor.cr` to
`compiler_rb/src/html/each_processor.rb`.

Includes: `EachResult`, `EachMatch`, `EachBlock`, `EachLoopDef`, `EachProcessor`.

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
`AttributeConditionalExtractor`.

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

For the Spinel port, instead of code-generating Crystal wrappers, create a
`FragmentLoader` class at `compiler_rb/src/batteries/fragment_loader.rb` that
reads `.rb` fragment files at runtime via `File.read`. Map each Crystal fragment
module to its corresponding source file path.

Provide a hash of fragment name to file path:
```ruby
class FragmentLoader
  FRAGMENTS = {
    "mochi_rb" => "fragments/batteries/mochi.rb",
    "app_router_rb" => "fragments/batteries/app_router.rb",
    # ...
  }

  def self.load(name)
    path = resolve_path(FRAGMENTS[name])
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
- Path resolution handles both development and installed binary locations

---

## Epic 4: Tree-Sitter FFI Bindings & Ruby AST Analysis

**Goal:** Port the tree-sitter C library bindings and all six AST extractor classes.
This is one of the most critical epics because the extractors determine how Mochi
understands component Ruby code.

### Story 4.1: Port Tree-Sitter C FFI Bindings

**Details:**
Port `compiler/src/tree-sitter/bindings.cr` to
`compiler_rb/src/tree_sitter/bindings.rb`.

The Crystal code uses `@[Link]` to link against `libtree-sitter` and
`libtree-sitter-ruby`. In Spinel, use the FFI system to declare external
functions.

Functions to bind:
```
# Parser
ts_parser_new() -> pointer
ts_parser_delete(parser)
ts_parser_set_language(parser, language) -> bool
ts_parser_parse_string(parser, old_tree, string, length) -> pointer

# Tree
ts_tree_root_node(tree) -> TSNode (struct)
ts_tree_delete(tree)

# Node
ts_node_type(node) -> string
ts_node_is_null(node) -> bool
ts_node_child_count(node) -> uint32
ts_node_named_child_count(node) -> uint32
ts_node_child(node, index) -> TSNode
ts_node_named_child(node, index) -> TSNode
ts_node_child_by_field_name(node, name, name_length) -> TSNode
ts_node_start_byte(node) -> uint32
ts_node_end_byte(node) -> uint32
ts_node_start_point(node) -> TSPoint
ts_node_end_point(node) -> TSPoint
ts_node_string(node) -> string

# Language
tree_sitter_ruby() -> pointer
```

**CRITICAL:** TSNode is a 32-byte struct (4x uint32 context + pointer id +
pointer tree). Spinel FFI must handle passing/returning structs by value. If
Spinel FFI doesn't support struct-by-value, use a C shim layer that wraps
tree-sitter functions to work with opaque pointers instead.

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

Includes nested class `VariableInfo` with properties: `name`, `writes`, `reads`,
`is_bound`, `attr_mutated`, `initialized_in_constructor`, `written_outside_constructor`.

**Acceptance Criteria:**
- `attr_accessor :count` → `@count` has `attr_mutated = true`
- `@count` written in `initialize` → `initialized_in_constructor = true`
- `@count` written in `increment` → `written_outside_constructor = true`
- `{count}` in html method → `@count` has `is_bound = true`
- The `category` method returns correct classification
- Spec ports Crystal `instance_var_analyzer_spec.cr` test cases

### Story 4.9: Port RubyUnderstander Facade

**Details:**
Port `compiler/src/ruby/ruby_understander.cr` to
`compiler_rb/src/ruby/ruby_understander.rb`.

Facade that delegates to TreeSitter extractors:
- `class_name(code)` → `ClassExtractor.class_name(code)`
- `get_imports(rb_file)` → `ImportsExtractor.extract_imports(rb_file)`
- `extract_method_bodies(rb_file, cls_name)` → `MethodBodyExtractor.extract_method_bodies(rb_file, cls_name)`
- `get_cmp_name(rb_file, cls_name)` → `PropertyExtractor.extract_property(rb_file, "@tag_name")`
- `extract_raw_string_from_def_body(body, name)` → `StringExtractor.extract_raw_string_from_def_body(body, name)`

**Acceptance Criteria:**
- All delegation methods return identical results to the Crystal version
- Spec validates each method with a sample component file

---

## Epic 5: Lexbor FFI & HTML Parsing

**Goal:** Port the Lexbor C library bindings and the classes that depend on HTML
DOM parsing (BindExtractor and the `traverse` method of ComponentGenerator).

### Story 5.1: Port Lexbor C FFI Bindings

**Details:**
Create `compiler_rb/src/lexbor/bindings.rb` with Spinel FFI bindings to the
Lexbor C library (`liblexbor.dylib` / `liblexbor.so`).

The Crystal `lexbor` shard provides a high-level API. For the Spinel port, bind
to the Lexbor C API directly. Required functions:

```
# Document
lxb_html_document_create() -> pointer
lxb_html_document_parse(doc, html, html_len) -> status
lxb_html_document_destroy(doc)

# Body
lxb_html_document_body_element(doc) -> pointer

# Node traversal
lxb_dom_node_first_child(node) -> pointer
lxb_dom_node_next(node) -> pointer
lxb_dom_node_tag_id(node) -> int
lxb_dom_element_local_name(element, len) -> string
lxb_dom_node_text_content(node, len) -> string

# Attributes
lxb_dom_element_first_attribute(element) -> pointer
lxb_dom_attr_local_name(attr, len) -> string
lxb_dom_element_get_attribute(element, name, name_len, value_len) -> string
lxb_dom_element_set_attribute(element, name, name_len, value, value_len) -> pointer
lxb_dom_element_remove_attribute(element, name, name_len) -> status

# Serialization
lxb_html_serialize_tree_str(node, str) -> status
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
Spinel wrapper must replicate this behavior using `lxb_dom_node_first_child` +
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
2. Find all elements (`css("*")` equivalent → walk all descendants)
3. Find `bind:` prefixed attributes
4. Remove `bind:` prefix, track bindings
5. Return cleaned HTML (body inner_html)

The Crystal code uses `doc.css("*")` which returns all elements. In Spinel,
implement a recursive walk that collects all element nodes.

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

Required QuickJS C functions:
```
JS_NewRuntime() -> pointer
JS_FreeRuntime(rt)
JS_NewContext(rt) -> pointer
JS_FreeContext(ctx)
JS_Eval(ctx, input, input_len, filename, eval_flags) -> JSValue
JS_GetGlobalObject(ctx) -> JSValue
JS_GetPropertyStr(ctx, obj, prop) -> JSValue
JS_SetPropertyStr(ctx, obj, prop, val) -> int
JS_NewString(ctx, str) -> JSValue
JS_NewStringLen(ctx, str, len) -> JSValue
JS_ToCStringLen2(ctx, plen, val, cesu8) -> pointer
JS_FreeCString(ctx, ptr)
JS_FreeValue(ctx, val)
JS_DupValue(ctx, val)
JS_IsException(val) -> bool
JS_GetException(ctx) -> JSValue
JS_IsFunction(ctx, val) -> int
JS_IsObject(val) -> bool
JS_Call(ctx, func, this, argc, argv) -> JSValue
JS_NewInt32(ctx, val) -> JSValue
JS_NewFloat64(ctx, val) -> JSValue
JS_NewBool(ctx, val) -> JSValue
JS_NewArray(ctx) -> JSValue
JS_NewObject(ctx) -> JSValue
JS_SetPropertyUint32(ctx, obj, idx, val) -> int
JS_RunGC(rt)
JS_SetMemoryLimit(rt, limit)
JS_SetGCThreshold(rt, threshold)
JS_SetMaxStackSize(rt, size)
JS_ExecutePendingJob(rt, pctx) -> int
JS_ToString(ctx, val) -> JSValue
```

**CRITICAL:** JSValue in QuickJS is a 16-byte struct (tag + value union). Spinel
FFI may need a C shim if struct-by-value passing is not supported. Create
`compiler_rb/src/quickjs/shim.c` if needed.

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
In Spinel, use `case` on the value's class.

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

`compile_with_cache` uses MD5 digest of `"path::code"` as cache key. For Spinel,
implement MD5 via FFI to OpenSSL (`CC_MD5` on macOS, or `MD5()` from libcrypto),
or implement a pure-Ruby MD5 if FFI is problematic.

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
`compiler/src/caching/warthogdb.cr` to Spinel equivalents.

WarthogDB is a simple key-value store (C library). Bind the C functions:
```
warthog_open(path) -> pointer
warthog_close(db)
warthog_get(db, key, key_len, value_len) -> pointer
warthog_put(db, key, key_len, value, value_len) -> status
warthog_has(db, key, key_len) -> bool
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

Properties: `path` (Array of Int), `type` (Symbol: `:text`, `:html`, `:attr`,
`:anchor`), `name` (String, optional -- attribute name), `value` (String).

In Spinel, symbols are supported. Use `attr_accessor` for all fields.

**Acceptance Criteria:**
- `Binding.new([0, 1, 0], :text, "{count}", nil)` works
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
- `build_dir` → `"#{Dir.pwd}/build"`
- `ruby_src_dir` → `"#{build_dir}/src"`
- `pre_tp_dir` → `"#{build_dir}/pre_tp"`

Constructor: creates mochi dir if missing, cleans build dir (preserving
`runtime.js`), generates `build_id`.

Methods: `copy_ruby_code_to_pre_tp`, `copy_ruby_code_base` (both use shell
`mkdir -p && cp -r`).

In Spinel, use `system("mkdir -p ...")` for shell commands (Spinel supports
`system()` and backtick execution).

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
   a. AttributeHashExtractor → inject AttributeHashGenerator methods
   b. AttributeConditionalExtractor → inject AttributeMethodGenerator methods
   c. EventArgumentExtractor
   d. InstanceVarAnalyzer → determine reactables
   e. ConditionalProcessor → inject ConditionalMethodGenerator methods
   f. EachProcessor → inject EachMethodGenerator methods
   g. BindExtractor
4. Inject getter/setter/lifecycle methods
5. Generate WebComponent via ComponentGenerator
6. Return MochiComponent

**NOTE:** Crystal uses `spawn` + `Channel` for parallel file processing. In
Spinel, process files sequentially. This is acceptable because Spinel-compiled
native code is fast enough, and the main bottleneck is the QuickJS Opal
compilation (which is sequential anyway).

**Acceptance Criteria:**
- `transpile_component` produces identical Ruby code transformations as Crystal
- `transpile_directory` produces identical `bundle.js` as Crystal
- All HTML processing steps applied in correct order
- Getter/setter/lifecycle method injection matches Crystal output
- Sequential processing completes without error
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
Spinel port, omit tracing (add timing with `Time.now` / `Process.clock_gettime`
instead). Pftrace integration can be added later.

**Acceptance Criteria:**
- `BuildMain.new.build(input_dir, output_dir, ...)` produces identical output
  to the Crystal compiler
- All 8 build steps execute in order
- Build artifacts cleaned after successful build
- Timing information printed for each step
- Error handling matches Crystal behavior (descriptive error messages)

---

## Epic 10: CLI, Initializer & Dev Server

**Goal:** Port the CLI argument parser, project initializer, and (optionally) the
dev server.

### Story 10.1: Port CLI Argument Parser

**Details:**
Port the CLI section of `compiler/src/mochi.cr` to
`compiler_rb/src/mochi.rb`.

Use Spinel's `optparse.rb` stdlib (note: Spinel's optparse is a minimal subset).
If Spinel's optparse is insufficient, implement a simple argument parser manually
(the CLI is straightforward: `-i`, `-o`, `--init`, `--minimize`, `--typecheck`,
`--dev`, `--root`, `--config`, `--keep_granular_build_artifacts`, `-h`).

Also port the top-level helper functions: `find_second_last_index`,
`js_to_cr_array`, `generate_build_id`, `print_cmp_start_separator`,
`print_cmp_end_seperator`, `print_separator`.

**NOTE:** `js_to_cr_array` uses `JSON.parse`. Since Spinel lacks a JSON stdlib,
implement a minimal JSON array parser (only needs to handle `["str1", "str2"]`
format) or use regex extraction.

**Acceptance Criteria:**
- `mochi -i ./src -o ./build` triggers build
- `mochi --initialize=MyProject` triggers initializer
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

### Story 10.3: Port DevServer (Deferred / Optional)

**Details:**
Port `compiler/src/tooling/dev_server.cr` to
`compiler_rb/src/tooling/dev_server.rb`.

The Crystal version uses `HTTP::Server` from the stdlib. Spinel does not have an
HTTP server in its stdlib.

**Options (choose one during implementation):**
1. **FFI to a C HTTP library** (e.g., mongoose, microhttpd)
2. **Socket-based minimal HTTP server** (Spinel may support raw sockets)
3. **Delegate to external tool** (e.g., invoke `python3 -m http.server` or a
   compiled C binary)
4. **Defer entirely** -- the dev server is optional; users can use any static
   file server

**Recommendation:** Defer the dev server to a follow-up epic. Focus the port on
the build pipeline which is the core value.

**Acceptance Criteria (if implemented):**
- `mochi dev --config=config.json --root=./public` starts server on port 27490
- Routes from config are served
- Static files served with correct content types
- Falls back to index.html for root

**Acceptance Criteria (if deferred):**
- `mochi dev` prints message: "Dev server not yet ported to Spinel. Use any
  static file server (e.g., python3 -m http.server) pointed at your output dir."

---

## Epic 11: End-to-End Verification & Cutover

**Goal:** Run the full test suite, fix any discrepancies, benchmark performance,
and prepare for production cutover.

### Story 11.1: Run Full E2E Test Suite

**Details:**
Execute `task e2e` (which internally runs the build followed by Playwright tests)
using the Spinel compiler instead of Crystal.

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
- All 32 E2E tests pass with Spinel-compiled output
- No visual or behavioral differences from Crystal-compiled output

### Story 11.2: Byte-for-Byte Output Comparison

**Details:**
Run both compilers against the same `devground/components` input and diff:
- `bundle.js` -- should be identical
- `runtime.js` -- should be identical

If there are whitespace or ordering differences (due to sequential vs parallel
processing), document them and verify they are semantically equivalent.

**Acceptance Criteria:**
- `diff crystal_bundle.js spinel_bundle.js` reports no differences, OR
- All differences are documented and verified as semantically identical
- E2E tests pass with both outputs

### Story 11.3: Port Crystal Unit Specs to Spinel

**Details:**
Port all 44 Crystal spec files to Spinel Ruby specs using the test helper from
Story 0.5.

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
- `task specs-spinel` runs all specs and reports results

### Story 11.4: Performance Benchmarking

**Details:**
Compare build times between Crystal and Spinel compilers:
1. Cold build (no cache) of `devground/components`
2. Warm build (with cache)
3. Single component transpilation time

Record metrics:
- Total build time (ms)
- Component processing time (ms)
- Opal compilation time (ms)
- Binary size (bytes)

**Acceptance Criteria:**
- Benchmark results documented in `notes/SPINEL_BENCHMARKS.md`
- Spinel build time within 2x of Crystal build time (acceptable given AOT
  compilation advantage for distribution)
- Binary size documented

### Story 11.5: Update Taskfile and Documentation

**Details:**
Update `Taskfile.yml`:
- `run-spinel` entry to build with Spinel compiler
- `specs-spinel` entry to run Spinel specs
- `e2e-spinel` entry to build + E2E with Spinel
- `build-spinel` entry to compile the Spinel binary
- `regression` entry to compare outputs

Update `README.md` with Spinel build instructions.

**Acceptance Criteria:**
- All new Taskfile entries work correctly
- README documents how to build with Spinel
- `task run-spinel` is a drop-in replacement for `task run`

### Story 11.6: Cutover Plan

**Details:**
Document the cutover process in `notes/SPINEL_CUTOVER.md`:
1. Ensure all E2E tests pass with Spinel compiler
2. Replace `task run` default to use Spinel
3. Keep Crystal compiler available as `task run-crystal` for fallback
4. After N releases with Spinel, remove Crystal compiler code
5. Update CI/CD pipelines

**Acceptance Criteria:**
- Cutover plan documented with clear steps
- Rollback procedure documented
- Timeline for Crystal code removal proposed

---

## Appendix A: Class-by-Class Mapping

| Crystal File | Spinel File | Epic |
|---|---|---|
| `ruby/ruby_def.cr` | `data_models/ruby_def.rb` | 1 |
| `ruby/ruby_var.cr` | `data_models/ruby_var.rb` | 1 |
| `ruby/ruby_endable_statement.cr` | `data_models/ruby_endable_statement.rb` | 1 |
| `webcomponents/web_component.cr` | `data_models/web_component.rb` | 1 |
| `mochi_cmp.cr` | `data_models/mochi_component.rb` | 1 |
| `ruby/inject_utils.cr` | `ruby/inject_utils.rb` | 1 |
| `html/conditional_processor.cr` | `html/conditional_processor.rb` | 2 |
| `html/each_processor.cr` | `html/each_processor.rb` | 2 |
| `html/attribute_conditional_extractor.cr` | `html/attribute_conditional_extractor.rb` | 2 |
| `html/attribute_hash_extractor.cr` | `html/attribute_hash_extractor.rb` | 2 |
| `html/event_argument_extractor.cr` | `html/event_argument_extractor.rb` | 2 |
| `ruby/conditional_method_generator.cr` | `ruby/conditional_method_generator.rb` | 3 |
| `ruby/each_method_generator.cr` | `ruby/each_method_generator.rb` | 3 |
| `ruby/attribute_method_generator.cr` | `ruby/attribute_method_generator.rb` | 3 |
| `ruby/attribute_hash_generator.cr` | `ruby/attribute_hash_generator.rb` | 3 |
| `generated/*.cr` | `batteries/fragment_loader.rb` | 3 |
| `batteries/core_battery.cr` | `batteries/core_battery.rb` | 3 |
| `batteries/sorbet_types_battery.cr` | `batteries/sorbet_types_battery.rb` | 3 |
| `ruby/ruby_rewriter.cr` | `ruby/ruby_rewriter.rb` | 3 |
| `js/js_logger.cr` | `js/js_logger.rb` | 3 |
| `opal/opal_runtime_generator.cr` | `opal/opal_runtime_generator.rb` | 3 |
| `tree-sitter/bindings.cr` | `tree_sitter/bindings.rb` | 4 |
| `tree-sitter/ruby_parser.cr` | `tree_sitter/ruby_parser.rb` | 4 |
| `tree-sitter/class_extractor.cr` | `tree_sitter/class_extractor.rb` | 4 |
| `tree-sitter/method_body_extractor.cr` | `tree_sitter/method_body_extractor.rb` | 4 |
| `tree-sitter/property_extractor.cr` | `tree_sitter/property_extractor.rb` | 4 |
| `tree-sitter/imports_extractor.cr` | `tree_sitter/imports_extractor.rb` | 4 |
| `tree-sitter/string_extractor.cr` | `tree_sitter/string_extractor.rb` | 4 |
| `tree-sitter/instance_var_analyzer.cr` | `tree_sitter/instance_var_analyzer.rb` | 4 |
| `ruby/ruby_understander.cr` | `ruby/ruby_understander.rb` | 4 |
| `bind_extractor.cr` | `lexbor/bind_extractor.rb` | 5 |
| `js/qjs_bindings.cr` | `quickjs/bindings.rb` | 6 |
| `quickjs/value.cr` | `quickjs/value.rb` | 6 |
| `quickjs/error.cr` | `quickjs/error.rb` | 6 |
| `quickjs/runtime.cr` | `quickjs/runtime.rb` | 6 |
| `quickjs/opal.cr` | `quickjs/opal.rb` | 6 |
| `quickjs/opal_builder.cr` | `quickjs/opal_builder.rb` | 6 |
| `caching/warthog_bindings.cr` | `caching/warthog_bindings.rb` | 7 |
| `caching/warthogdb.cr` | `caching/warthogdb.rb` | 7 |
| `caching/cache.cr` | `caching/cache.rb` | 7 |
| `webcomponents/component_generator.cr` | `webcomponents/component_generator.rb` | 8 |
| `entrypoints/building/builder_man.cr` | `entrypoints/builder_man.rb` | 9 |
| `entrypoints/building/transpiler.cr` | `entrypoints/transpiler.rb` | 9 |
| `entrypoints/building/build_main.cr` | `entrypoints/build_main.rb` | 9 |
| `mochi.cr` | `mochi.rb` | 10 |
| `initializer.cr` | `initializer.rb` | 10 |
| `tooling/dev_server.cr` | `tooling/dev_server.rb` | 10 |

## Appendix B: Spinel FFI Risk Areas

### Struct-by-Value Passing
Tree-sitter's `TSNode` (32 bytes) and QuickJS's `JSValue` (16 bytes) are passed
by value in their C APIs. Spinel FFI may not support this. **Mitigation:** Create
thin C shim libraries that wrap these types behind opaque pointers:

```c
// tree_sitter_shim.c
typedef struct { TSNode node; } TSNodeHandle;
TSNodeHandle* ts_shim_root_node(TSTree *tree);
const char* ts_shim_node_type(TSNodeHandle *h);
// ... etc
```

Compile shims to `.so`/`.dylib` and link via Spinel FFI.

### Lexbor API Complexity
Lexbor's C API uses callback-based serialization and tagged node types. The
Crystal `lexbor` shard abstracts this heavily. The Spinel port needs a faithful
re-implementation of node traversal that includes text and comment children (not
just element children).

### QuickJS Memory Management
QuickJS requires careful `JS_FreeValue` calls. The Crystal code uses Crystal's GC
finalizers. In Spinel, ensure explicit cleanup in `finalize` methods or use
`ensure` blocks.

## Appendix C: Files NOT Ported

These Crystal files are intentionally excluded from the port:

| File | Reason |
|---|---|
| `entrypoints/building/trace_helper.cr` | Pftrace integration deferred |
| `entrypoints/typechecker.cr` | Sorbet integration deferred |
| `sorbet/sorbet.cr` | Sorbet integration deferred |
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
