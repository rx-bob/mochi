# Mochi Crystal-to-Zig Port Plan

## Overview

This document describes the full rewrite of the Mochi compiler from Crystal to
[Zig 0.16.0](https://ziglang.org/) -- a systems programming language focused on
safety, performance, and direct C interop.

**Goal:** Replace every Crystal source file under `compiler/src/` with equivalent
Zig code that produces *byte-identical* build output, ensuring zero regressions
as validated by the existing E2E test suite (32 Playwright tests).

**Why Zig?**
- **Native C interop:** Zig can `@cImport` C headers directly -- no FFI shims
  needed for tree-sitter, Lexbor, QuickJS, or WarthogDB. This eliminates the
  entire class of struct-by-value FFI problems that plague higher-level languages.
- **Performance:** Compiles to optimized native binaries via LLVM. Expected to
  match or exceed Crystal build speeds.
- **Cross-compilation:** Single-command cross-compilation to Linux, macOS, Windows
  from any host. Simplifies distribution.
- **Small binaries:** No runtime or GC overhead. Expect significantly smaller
  binaries than Crystal.
- **Explicit memory management:** Allocator-based model gives full control without
  GC pauses. Arena allocators are ideal for compiler passes.
- **Built-in test framework:** `zig test` with inline test blocks -- no external
  test library needed.
- **Comptime:** Compile-time code execution replaces Crystal macros and code
  generation.

---

## Architectural Decisions

### Directory Layout

```
mochi/
  compiler/              # existing Crystal implementation (kept as reference)
  compiler_zig/          # NEW -- Zig rewrite
    build.zig            # Zig build script
    build.zig.zon        # Package manifest (dependencies)
    src/
      main.zig           # CLI entry point
      data_models/
        ruby_def.zig
        ruby_var.zig
        ruby_endable_statement.zig
        web_component.zig
        mochi_component.zig
      html/
        conditional_processor.zig
        each_processor.zig
        attribute_conditional_extractor.zig
        attribute_hash_extractor.zig
        event_argument_extractor.zig
      ruby/
        inject_utils.zig
        conditional_method_generator.zig
        each_method_generator.zig
        attribute_method_generator.zig
        attribute_hash_generator.zig
        ruby_rewriter.zig
        ruby_understander.zig
      tree_sitter/
        bindings.zig      # @cImport of tree-sitter + tree-sitter-ruby headers
        ruby_parser.zig
        class_extractor.zig
        method_body_extractor.zig
        property_extractor.zig
        imports_extractor.zig
        string_extractor.zig
        instance_var_analyzer.zig
      lexbor/
        bindings.zig      # @cImport of lexbor headers
        document.zig
        bind_extractor.zig
      quickjs/
        bindings.zig      # @cImport of quickjs headers
        value.zig
        runtime.zig
        opal.zig
        opal_builder.zig
      caching/
        warthog_bindings.zig  # @cImport of warthogdb headers
        cache.zig
      webcomponents/
        component_generator.zig
      entrypoints/
        builder_man.zig
        transpiler.zig
        build_main.zig
      batteries/
        fragment_loader.zig
        core_battery.zig
        sorbet_types_battery.zig
      js/
        js_logger.zig
      opal/
        opal_runtime_generator.zig
      tooling/
        dev_server.zig
      initializer.zig
      utils/
        strings.zig       # String helper functions (join, replace, etc.)
        fs.zig             # File system helpers
        md5.zig            # MD5 (use std.crypto.hash.Md5)
    test/                  # Integration tests (unit tests are inline)
      regression_test.zig
  vendor/
    tree-sitter/           # tree-sitter C source (or system lib)
    tree-sitter-ruby/      # tree-sitter-ruby C source
    lexbor/                # Lexbor C source (or system lib)
    quickjs/               # QuickJS C source
    warthogdb/             # WarthogDB C source
```

### Key Porting Decisions

| Crystal Feature | Zig Equivalent |
|---|---|
| `@[Link]` / `lib` FFI | `@cImport` + `build.zig` linkage -- direct C interop, no shims |
| `OptionParser` | `std.process.ArgIterator` + custom arg parser |
| `Channel` / `spawn` concurrency | `std.Thread` or sequential (evaluate need) |
| `String.build { \|s\| s << }` | `std.ArrayList(u8)` writer or `std.fmt.bufPrint` |
| Crystal `property` | Zig struct fields (public by default) |
| `enum` | Zig `enum` (first-class, with methods) |
| Crystal macros (`{% begin %}`) | `comptime` blocks |
| Crystal `Lexbor` shard | Direct `@cImport("lexbor/...")` -- no wrapper needed |
| `Digest::MD5` | `std.crypto.hash.Md5` (in stdlib) |
| `HTTP::Server` | `std.http.Server` (in stdlib) |
| Crystal `struct` | Zig `struct` (value semantics by default) |
| `JSON.parse` | `std.json.parseFromSlice` (in stdlib) |
| Crystal `Time.measure` | `std.time.Timer` / `std.time.nanoTimestamp` |
| Crystal `Array(T)` | `std.ArrayList(T)` |
| Crystal `Hash(K, V)` | `std.StringHashMap(V)` or `std.AutoHashMap(K, V)` |
| Crystal `String` | `[]const u8` (slices) -- no GC, explicit allocation |
| Crystal `Regex` | `std.mem.indexOf` / manual parsing, or PCRE via `@cImport` |
| Crystal `File.read` | `std.fs.cwd().readFileAlloc(allocator, path, max)` |
| Crystal `Dir.glob` | `std.fs.Dir.walk` or recursive `openDir` + `iterate` |
| Crystal exceptions | Zig error unions (`!T`) + `try`/`catch` |
| Crystal `nil` / `T?` | Zig `?T` (optionals) |
| Crystal `Tuple` | Zig anonymous structs or tuples |

### Regex Strategy

Crystal's codebase uses regex extensively for HTML processing (conditional
extraction, attribute parsing, event argument extraction). Zig has no built-in
regex engine. Options:

1. **Port regex patterns to manual parsers** -- preferred for simple patterns.
   Most patterns are bracket/delimiter matching that can be done with state
   machines. This is more performant and has zero dependencies.
2. **Use PCRE2 via `@cImport`** -- for complex patterns like the attribute
   conditional regex. Link against system PCRE2 or vendor it.
3. **Hybrid approach** -- manual parsers for simple cases, PCRE2 for the complex
   multi-line patterns.

**Recommendation:** Start with manual parsers. Fall back to PCRE2 only if a
pattern is too complex to hand-code reliably. Most of the regex usage is
straightforward delimiter matching.

### Memory Management Strategy

Zig requires explicit memory management. The compiler's workload is well-suited
to arena allocators:

- **Per-build arena:** Allocate an arena at the start of a build, free everything
  at the end. Most compiler data (parsed components, generated strings) lives for
  the entire build.
- **Per-component arena:** For `transpile_component`, use a child arena that gets
  freed after the component is fully processed. This bounds memory usage for large
  projects.
- **General purpose allocator:** For long-lived state (CLI args, config). Use
  `std.heap.GeneralPurposeAllocator` in debug, `std.heap.c_allocator` in release.

Pattern:
```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();
// all allocations freed automatically at scope exit
```

### String Building

Crystal's `String.build` pattern maps to `std.ArrayList(u8)`:

```zig
var buf = std.ArrayList(u8).init(allocator);
defer buf.deinit();
try buf.appendSlice("class ");
try buf.appendSlice(class_name);
try buf.appendSlice(" extends MochiComponent {\n");
const result = try buf.toOwnedSlice();
```

For formatted output, use `std.fmt.allocPrint`:
```zig
const line = try std.fmt.allocPrint(allocator, "  update_{s}(val) {{\n", .{var_name});
```

### Regression Strategy

At every epic boundary:

1. Build `devground/components` with **both** the Crystal compiler and the new
   Zig compiler.
2. `diff` the output `bundle.js` and `runtime.js` files. They must be identical.
3. Run `task e2e` (Playwright tests) against the Zig-produced output.
4. Run `zig test` for all unit tests.

A `Taskfile.yml` entry `run-zig` will be added so both compilers can be
invoked easily.

---

## Dependency Graph (Port Order)

```
Epic 0: Scaffolding + C Library Integration
  |
  v
Epic 1: Data Models  (no C deps, pure Zig)
  |
  v
Epic 2: HTML Text Processors  (no C deps, string/parsing)
  |
  v
Epic 3: Ruby Code Generators  (depends on 1, 2)
  |             |
  |             v
  |    Epic 4: Tree-Sitter Integration + AST Extractors
  |             |
  |             v
  |    Epic 5: Lexbor Integration + BindExtractor
  |             |
  v             v
Epic 6: QuickJS Integration + Opal Compilation
  |
  v
Epic 7: Caching (WarthogDB Integration)
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

## Epic 0: Project Scaffolding & C Library Integration

**Goal:** Set up the Zig project structure, integrate all C dependencies via
`build.zig`, and establish the test harness.

### Story 0.1: Initialize Zig Project

**Details:**
Create `compiler_zig/` with `build.zig`, `build.zig.zon`, and `src/main.zig`.
The initial `main.zig` prints "Mochi Zig v0.1" and exits.

`build.zig` should:
- Define an executable target `mochi`
- Set optimization mode (debug by default, ReleaseFast for production)
- Add a `test` step that runs all tests

**Acceptance Criteria:**
- `cd compiler_zig && zig build` produces `zig-out/bin/mochi`
- Running the binary prints "Mochi Zig v0.1"
- `zig build test` runs and passes (trivial test)

### Story 0.2: Integrate Tree-Sitter C Libraries

**Details:**
Add tree-sitter and tree-sitter-ruby C sources (or system libraries) to
`build.zig`. Create `src/tree_sitter/bindings.zig` with `@cImport` of the
tree-sitter headers.

In `build.zig`:
```zig
exe.linkLibC();
exe.addIncludePath(.{ .cwd_relative = "vendor/tree-sitter/lib/include" });
exe.addCSourceFile(.{
    .file = .{ .cwd_relative = "vendor/tree-sitter/lib/src/lib.c" },
    .flags = &.{"-std=c11"},
});
// Similar for tree-sitter-ruby
```

Zig's `@cImport` will automatically handle `TSNode` (32-byte struct) passed by
value -- no shim needed, unlike Spinel/Ruby FFI.

**Acceptance Criteria:**
- `@cImport(@cInclude("tree_sitter/api.h"))` compiles without errors
- Can call `ts_parser_new()`, `ts_parser_set_language()`, `ts_parser_parse_string()`
- Parse `"class Foo; end"` and verify root node type is `"program"`
- `zig build test` passes tree-sitter smoke test

### Story 0.3: Integrate Lexbor C Library

**Details:**
Add Lexbor C source (or system library) to `build.zig`. Create
`src/lexbor/bindings.zig` with `@cImport` of Lexbor headers.

**IMPORTANT:** Lexbor uses callback-based serialization. The `@cImport` will
import these correctly. Zig can pass function pointers to C callbacks natively.

**Acceptance Criteria:**
- Can create document, parse HTML, traverse nodes
- Text nodes return `"_text"`, comment nodes return `"_em_comment"` (Lexbor quirk)
- `node.children` traversal (first_child + next sibling) includes text/comment nodes
- Smoke test passes

### Story 0.4: Integrate QuickJS C Library

**Details:**
Add QuickJS C source to `build.zig`. Create `src/quickjs/bindings.zig` with
`@cImport`.

QuickJS's `JSValue` (16-byte struct, tag + union) is handled natively by Zig's C
interop -- no shim needed.

**Acceptance Criteria:**
- Can create runtime + context
- `JS_Eval` executes `"1 + 2"` and returns `3`
- String round-trip works (Zig string -> JS -> back)
- Memory cleanup (FreeValue, FreeContext, FreeRuntime) works without leaks

### Story 0.5: Integrate WarthogDB C Library

**Details:**
Add WarthogDB C source to `build.zig`. Create `src/caching/warthog_bindings.zig`
with `@cImport`.

**Acceptance Criteria:**
- Can open, put, get, has, close a WarthogDB database
- String values round-trip correctly
- Smoke test passes

### Story 0.6: Create Directory Structure and Taskfile Entries

**Details:**
Create all subdirectories under `compiler_zig/src/` as specified in the layout.
Add Taskfile entries:
- `build-zig` -- `cd compiler_zig && zig build -Doptimize=ReleaseFast`
- `run-zig` -- build + run the Zig compiler against devground
- `test-zig` -- `cd compiler_zig && zig build test`

**Acceptance Criteria:**
- All directories exist
- `task build-zig` produces the binary
- `task run-zig` runs it (currently just prints version)
- `task test-zig` runs all tests

### Story 0.7: Set Up Regression Test Harness

**Details:**
Create `scripts/regression_test.sh` that:
1. Builds `devground/components` with the Crystal compiler (`task run`)
2. Copies `devground/public/bundle.js` to `/tmp/crystal_bundle.js`
3. Builds `devground/components` with the Zig compiler (`task run-zig`)
4. Copies `devground/public/bundle.js` to `/tmp/zig_bundle.js`
5. Runs `diff` between the two outputs
6. Reports pass/fail

**Acceptance Criteria:**
- `task regression` runs both compilers and diffs output
- Currently fails (Zig compiler not implemented yet) -- expected
- Script clearly reports which outputs differ

---

## Epic 1: Data Model & Utility Types

**Goal:** Port all plain data types that have zero C library dependencies. These
are the building blocks used by every other module.

### Story 1.1: Port RubyDef

**Details:**
Port `compiler/src/ruby/ruby_def.cr` to `compiler_zig/src/data_models/ruby_def.zig`.

Crystal properties: `name : String?`, `file_name : String`, `class_name : String`,
`body : Array(String)`, `parameters : Array(String)`.

Zig equivalent:
```zig
const RubyDef = struct {
    name: ?[]const u8,
    file_name: []const u8,
    class_name: []const u8,
    body: std.ArrayList([]const u8),
    parameters: std.ArrayList([]const u8),
};
```

**Acceptance Criteria:**
- Struct compiles and all fields accessible
- Inline test covers construction and field access

### Story 1.2: Port RubyVariable

**Details:**
Port `compiler/src/ruby/ruby_var.cr` to `compiler_zig/src/data_models/ruby_var.zig`.

```zig
const RubyVariable = struct {
    value: []const u8,
    exported: bool,
};
```

**Acceptance Criteria:**
- Construction works
- Inline test covers fields

### Story 1.3: Port RubyEndableStatement

**Details:**
Port `compiler/src/ruby/ruby_endable_statement.cr` to
`compiler_zig/src/data_models/ruby_endable_statement.zig`.

Crystal uses an `enum`. Zig equivalent:
```zig
const RubyEndableStatement = enum {
    class,
    module,
    def,
    do_block,
    if_stmt,
    unless,
    while_loop,
    case_stmt,
    begin_block,

    pub fn getEndable(input: []const u8) ?RubyEndableStatement {
        if (std.mem.startsWith(u8, input, "class ")) return .class;
        if (std.mem.startsWith(u8, input, "module ")) return .module;
        // ...
        return null;
    }
};
```

**Acceptance Criteria:**
- `getEndable("class Foo")` returns `.class`
- `getEndable("xyz")` returns `null`
- Inline test covers all statement types

### Story 1.4: Port WebComponent

**Details:**
Port `compiler/src/webcomponents/web_component.cr` to
`compiler_zig/src/data_models/web_component.zig`.

```zig
const WebComponent = struct {
    name: []const u8,
    js_code: []const u8,
};
```

**Acceptance Criteria:**
- Construction and field access work
- Inline test covers construction

### Story 1.5: Port MochiComponent

**Details:**
Port `compiler/src/mochi_cmp.cr` to
`compiler_zig/src/data_models/mochi_component.zig`.

```zig
const MochiComponent = struct {
    absolute_path: []const u8,
    name: []const u8,
    imports: std.ArrayList([]const u8),
    ruby_code: []const u8,
    web_component: WebComponent,
    html: []const u8,
    css: []const u8,
};
```

**Acceptance Criteria:**
- Constructor accepts all 7 fields
- All fields readable
- Inline test covers construction

### Story 1.6: Port InjectUtils

**Details:**
Port `compiler/src/ruby/inject_utils.cr` to `compiler_zig/src/ruby/inject_utils.zig`.

Functions: `findInsertionPoint`, `findSecondLastEnd`, `calculateInsertionPoint`,
`insertCode`. All pure string manipulation using `std.mem` functions.

```zig
pub fn insertCode(allocator: Allocator, source: []const u8, position: usize, code: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, source.len + code.len);
    try result.appendSlice(source[0..position]);
    try result.appendSlice(code);
    try result.appendSlice(source[position..]);
    return result.toOwnedSlice();
}
```

**Acceptance Criteria:**
- `findSecondLastEnd` returns correct index
- `insertCode("abcdef", 3, "XYZ")` returns `"abcXYZdef"`
- Inline tests port Crystal spec assertions

### Story 1.7: String Utility Module

**Details:**
Create `compiler_zig/src/utils/strings.zig` with common string operations needed
throughout the codebase:
- `join(allocator, slices, separator)` -- join string slices
- `replace(allocator, haystack, needle, replacement)` -- string replace
- `startsWith`, `endsWith`, `trim`, `split` -- wrappers or re-exports from `std.mem`
- `contains(haystack, needle)` -- substring check
- `indexOf(haystack, needle)` -- find first occurrence

Many of these exist in `std.mem` but a convenience wrapper helps keep the port
readable.

**Acceptance Criteria:**
- All utility functions work correctly
- Inline tests cover edge cases (empty strings, not found, etc.)

---

## Epic 2: HTML Text Processors

**Goal:** Port the five HTML processing modules that use only string manipulation
and parsing -- no C library dependencies.

### Story 2.1: Port ConditionalProcessor

**Details:**
Port `compiler/src/html/conditional_processor.cr` to
`compiler_zig/src/html/conditional_processor.zig`.

Types:
```zig
const ConditionalResult = struct {
    html: []const u8,
    conditionals: std.ArrayList(ConditionalBlock),
};

const ConditionalBlock = struct {
    condition: []const u8,
    content: []const u8,
    start_pos: usize,
    end_pos: usize,
    content_start_pos: usize,
    id: usize,
};
```

Key logic: stack-based parsing of `{if condition}...{end}` blocks. Replace the
Crystal regex-based token matching with manual `std.mem.indexOf` scanning for
`{if `, `{unless `, `{else}`, `{end}` tokens.

**Acceptance Criteria:**
- `process("{if @show}hello{end}")` returns result with `<!--if-anchor-0-->`
- Nested conditionals handled correctly
- Tests port all Crystal `conditional_processor_spec.cr` cases

### Story 2.2: Port EachProcessor

**Details:**
Port `compiler/src/html/each_processor.cr` to
`compiler_zig/src/html/each_processor.zig`.

Types: `EachResult`, `EachBlock`, `EachLoopDef`, etc.

Parse `{each @items as item}...{end}` blocks. Replace with `<!--each-anchor-N-->`.

**Acceptance Criteria:**
- Process `{each @items as item}<li>{item.name}</li>{end}` correctly
- Parse loop definitions with optional index: `@items as item, idx`
- Tests port all Crystal `each_processor_spec.cr` cases

### Story 2.3: Port AttributeConditionalExtractor

**Details:**
Port `compiler/src/html/attribute_conditional_extractor.cr` to
`compiler_zig/src/html/attribute_conditional_extractor.zig`.

The Crystal version uses a complex multi-line regex:
```
/([a-zA-Z0-9_\-\:]+)\s*=\s*(["'])((?:(?!\2).)*(?:\{if |\{unless )(?:(?!\2).)*)\2/m
```

For Zig, implement this as a hand-written parser that:
1. Scans for `attribute="` or `attribute='` patterns
2. Within the quoted value, checks for `{if ` or `{unless ` tokens
3. Extracts the full attribute name, quote character, and value

This is a good candidate for PCRE2 fallback if the hand-written parser proves
too complex. Evaluate during implementation.

**Acceptance Criteria:**
- Extracts attribute conditionals with correct id, original_string, attribute_name
- Replaces with `{__mochi_attr_cond_N}` placeholder
- Tests port Crystal `attribute_conditional_extractor_spec.cr` cases

### Story 2.4: Port AttributeHashExtractor

**Details:**
Port `compiler/src/html/attribute_hash_extractor.cr` to
`compiler_zig/src/html/attribute_hash_extractor.zig`.

Handles `attr={{...}}` and `attr="{{...}}"` patterns. Scan for `{{` and `}}`
delimiters within attribute values.

**Acceptance Criteria:**
- Both quoted and unquoted `{{...}}` patterns extracted
- Replacement values correct
- Tests port Crystal `attribute_hash_extractor_spec.cr` cases

### Story 2.5: Port EventArgumentExtractor

**Details:**
Port `compiler/src/html/event_argument_extractor.cr` to
`compiler_zig/src/html/event_argument_extractor.zig`.

Converts `onclick="{method(arg1, arg2)}"` into
`onclick="{method}" data-mochi-arg-0="{arg1}" data-mochi-arg-1="{arg2}"`.

Parse parenthesized argument lists, split on commas, handle `$event` and
`$element` as special literal values.

**Acceptance Criteria:**
- Arguments extracted and converted to `data-mochi-arg-N` attributes
- `$event` and `$element` handled as special literals
- Empty parens `method()` produce clean output
- Tests port Crystal `event_argument_extractor_spec.cr` cases

---

## Epic 3: Ruby Code Generators

**Goal:** Port the method generator modules and their supporting battery/fragment
infrastructure. These inject computed methods into Ruby component source code.

### Story 3.1: Port ConditionalMethodGenerator

**Details:**
Port `compiler/src/ruby/conditional_method_generator.cr` to
`compiler_zig/src/ruby/conditional_method_generator.zig`.

For each `ConditionalBlock`, generates a Ruby method string like:
```ruby
def __mochi_cond_0
  @show
end
```

Uses `InjectUtils` to insert at the correct position.

**Acceptance Criteria:**
- Generated method names match `__mochi_cond_N` pattern
- Methods injected at correct position in Ruby source
- Tests port Crystal `conditional_method_generator_spec.cr` cases

### Story 3.2: Port EachMethodGenerator

**Details:**
Port `compiler/src/ruby/each_method_generator.cr` to
`compiler_zig/src/ruby/each_method_generator.zig`.

Generates `__mochi_each_N_items` and `__mochi_each_N_key` methods.

**Acceptance Criteria:**
- Both `_items` and `_key` methods generated correctly
- JavaScript backtick block in `_key` preserved exactly
- Tests port Crystal cases

### Story 3.3: Port AttributeMethodGenerator

**Details:**
Port `compiler/src/ruby/attribute_method_generator.cr` to
`compiler_zig/src/ruby/attribute_method_generator.zig`.

Generates `__mochi_attr_cond_N` methods. The `escape_and_interpolate` function
converts `{var}` to `#{var}` for Ruby string interpolation.

**Acceptance Criteria:**
- Generated methods return correct interpolated strings
- Double quotes in content escaped
- `{var}` and `{@var}` patterns converted to Ruby interpolation
- Tests validate generated output

### Story 3.4: Port AttributeHashGenerator

**Details:**
Port `compiler/src/ruby/attribute_hash_generator.cr` to
`compiler_zig/src/ruby/attribute_hash_generator.zig`.

Generates `__mochi_attr_hash_N` methods with hash selection logic.

**Acceptance Criteria:**
- Inner hash correctly extracted from `{{...}}` delimiters
- Generated method selects truthy keys and joins
- Tests port Crystal cases

### Story 3.5: Port Fragment Loading

**Details:**
The Crystal codebase has `compiler/src/generated/*.cr` files -- auto-generated
modules that embed Ruby source as string constants.

For the Zig port, use `@embedFile` at compile time:
```zig
const mochi_rb = @embedFile("../../fragments/batteries/mochi.rb");
const app_router_rb = @embedFile("../../fragments/batteries/app_router.rb");
```

This is superior to both Crystal's code generation and Spinel's runtime
`File.read` -- the fragments are baked into the binary at compile time with zero
runtime cost.

Create `compiler_zig/src/batteries/fragment_loader.zig` with a function that
maps fragment names to embedded content:
```zig
pub fn load(name: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "mochi_rb", mochi_rb },
        .{ "app_router_rb", app_router_rb },
        // ...
    });
    return map.get(name);
}
```

**Acceptance Criteria:**
- `FragmentLoader.load("mochi_rb")` returns the Ruby source string
- All fragment names from Crystal `generated/` directory mapped
- Fragments embedded at compile time (no runtime file I/O)

### Story 3.6: Port CoreBattery and SorbetTypesBat

**Details:**
Port battery generators to use `FragmentLoader` embedded strings.

`CoreBattery.generate(ruby_src_dir)` assembles fragments and writes `mochi.rb`.

**Acceptance Criteria:**
- `CoreBattery.generate("/tmp/src")` writes `/tmp/src/lib/mochi.rb`
- Output matches Crystal compiler output byte-for-byte
- `SorbetTypesBat.generate("/tmp/src")` writes sorbet type stubs

### Story 3.7: Port RubyRewriter

**Details:**
Port `compiler/src/ruby/ruby_rewriter.cr` to
`compiler_zig/src/ruby/ruby_rewriter.zig`.

Methods: `extractLibPath`, `formatRequirePath`, `genMochiRubyRoot`,
`genBuiltinComponentFeatherIcon`, `genBuiltinMochiRouter`,
`genBuiltinRouteComponent`, `commentOutSorbetSignatures`,
`commentOutAllSorbetSignaturesInDir`.

For directory walking, use `std.fs.Dir.walk` or recursive `openDir` + `iterate`.

**Acceptance Criteria:**
- `genMochiRubyRoot` output matches Crystal output
- Path extraction handles all edge cases
- Sorbet signature commenting produces identical output
- Tests validate each function

### Story 3.8: Port JsLoggerGenerator

**Details:**
Port `compiler/src/js/js_logger.cr` to `compiler_zig/src/js/js_logger.zig`.

Pure string generation of JavaScript logger class.

**Acceptance Criteria:**
- Output matches Crystal output byte-for-byte
- Test validates output

### Story 3.9: Port OpalRuntimeGenerator

**Details:**
Port `compiler/src/opal/opal_runtime_generator.cr` to
`compiler_zig/src/opal/opal_runtime_generator.zig`.

Reads and concatenates `runtime.js`, `mochi_component.js`, `signal.js`.

Consider using `@embedFile` for the JS runtime files too, eliminating runtime
file I/O for these as well.

**Acceptance Criteria:**
- `generate(build_dir)` writes `runtime.js`
- Output matches Crystal compiler output byte-for-byte
- Path resolution handles both dev and installed locations

---

## Epic 4: Tree-Sitter Integration & Ruby AST Analysis

**Goal:** Port the tree-sitter wrapper types and all six AST extractor modules.
This is one of the most critical epics because the extractors determine how Mochi
understands component Ruby code.

### Story 4.1: Port TreeSitter Node, RubyParser, Tree Wrappers

**Details:**
Port `compiler/src/tree-sitter/ruby_parser.cr` to
`compiler_zig/src/tree_sitter/ruby_parser.zig`.

Since Zig can use tree-sitter's C API directly via `@cImport`, the wrappers are
thin:

```zig
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

const Node = struct {
    raw: c.TSNode,
    source: []const u8,

    pub fn nodeType(self: Node) []const u8 {
        return std.mem.span(c.ts_node_type(self.raw));
    }

    pub fn text(self: Node) []const u8 {
        const start = c.ts_node_start_byte(self.raw);
        const end = c.ts_node_end_byte(self.raw);
        return self.source[start..end];
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn child(self: Node, index: u32) ?Node {
        const n = c.ts_node_child(self.raw, index);
        if (c.ts_node_is_null(n)) return null;
        return Node{ .raw = n, .source = self.source };
    }

    pub fn namedChild(self: Node, index: u32) ?Node {
        const n = c.ts_node_named_child(self.raw, index);
        if (c.ts_node_is_null(n)) return null;
        return Node{ .raw = n, .source = self.source };
    }

    pub fn childByFieldName(self: Node, name: []const u8) ?Node {
        const n = c.ts_node_child_by_field_name(self.raw, name.ptr, @intCast(name.len));
        if (c.ts_node_is_null(n)) return null;
        return Node{ .raw = n, .source = self.source };
    }
};

const RubyParser = struct {
    parser: *c.TSParser,

    pub fn init() RubyParser {
        const parser = c.ts_parser_new();
        _ = c.ts_parser_set_language(parser, c.tree_sitter_ruby());
        return .{ .parser = parser };
    }

    pub fn parse(self: *RubyParser, source: []const u8) Tree {
        const tree = c.ts_parser_parse_string(self.parser, null, source.ptr, @intCast(source.len));
        return Tree{ .tree = tree, .source = source };
    }

    pub fn deinit(self: *RubyParser) void {
        c.ts_parser_delete(self.parser);
    }
};
```

**NOTE:** `TSNode` is passed by value -- Zig handles this natively via `@cImport`.
No shim layer needed (unlike Spinel).

**Acceptance Criteria:**
- `RubyParser.init().parse("class Foo; end").rootNode().nodeType()` == `"program"`
- `node.text()` returns correct source substring
- `childByFieldName("name")` returns correct child
- Iterator helpers work (eachChild, eachNamedChild)
- Tests cover all Node methods

### Story 4.2: Port ClassExtractor

**Details:**
Port `compiler/src/tree-sitter/class_extractor.cr` to
`compiler_zig/src/tree_sitter/class_extractor.zig`.

Functions: `extractClassNames`, `className`, `extractSuperclass`.

Traverses AST for `"class"` nodes, extracts name (handles `A::B::C` scope
resolution).

**Acceptance Criteria:**
- `className("class MyCounter < MochiBase; end")` returns `"MyCounter"`
- `extractSuperclass(...)` returns `"MochiBase"`
- Scope resolution handled correctly
- Tests port Crystal `class_extractor_spec.cr` cases

### Story 4.3: Port MethodBodyExtractor

**Details:**
Port `compiler/src/tree-sitter/method_body_extractor.cr` to
`compiler_zig/src/tree_sitter/method_body_extractor.zig`.

Returns a `StringHashMap(RubyDef)` of method name to body. Uses start/end
points to extract body lines from source.

**Acceptance Criteria:**
- Extracts `html`, `css`, `initialize`, and user methods correctly
- Body lines match source lines exactly
- Parameters extracted correctly
- Tests port Crystal cases

### Story 4.4: Port PropertyExtractor

**Details:**
Port `compiler/src/tree-sitter/property_extractor.cr` to
`compiler_zig/src/tree_sitter/property_extractor.zig`.

Finds `@tag_name = "my-counter"` assignments and extracts values.

**Acceptance Criteria:**
- `extractProperty(source, "@tag_name")` returns the string value
- Handles string, integer, symbol, constant values
- Tests port Crystal cases

### Story 4.5: Port ImportsExtractor

**Details:**
Port `compiler/src/tree-sitter/imports_extractor.cr` to
`compiler_zig/src/tree_sitter/imports_extractor.zig`.

Finds `require("...")` calls and extracts paths.

**Acceptance Criteria:**
- `extractImports('require "foo"')` returns `["foo"]`
- Handles single and double quotes
- Tests port Crystal cases

### Story 4.6: Port StringExtractor

**Details:**
Port `compiler/src/tree-sitter/string_extractor.cr` to
`compiler_zig/src/tree_sitter/string_extractor.zig`.

Extracts raw string content from method bodies. Handles regular strings,
`%Q{...}`, `%q{...}`, heredocs, arrays.

**Acceptance Criteria:**
- Extracts from `def html; "..."; end`
- Handles `%Q{...}` percent strings
- Handles heredoc syntax
- Fallback extraction works
- Tests port Crystal cases

### Story 4.7: Port InstanceVarAnalyzer

**Details:**
Port `compiler/src/tree-sitter/instance_var_analyzer.cr` to
`compiler_zig/src/tree_sitter/instance_var_analyzer.zig`.

The most complex extractor. Tracks `attr_accessor`/`attr_writer`/`attr_reader`
declarations, instance variable reads/writes per method, HTML bindings, and
classifies variables.

```zig
const VariableInfo = struct {
    name: []const u8,
    writes: u32,
    reads: u32,
    is_bound: bool,
    attr_mutated: bool,
    initialized_in_constructor: bool,
    written_outside_constructor: bool,

    pub fn category(self: VariableInfo) Category {
        // classification logic
    }
};
```

**Acceptance Criteria:**
- `attr_accessor :count` -> `attr_mutated = true`
- Constructor writes -> `initialized_in_constructor = true`
- Method writes -> `written_outside_constructor = true`
- HTML bindings -> `is_bound = true`
- `category()` returns correct classification
- Tests port Crystal `instance_var_analyzer_spec.cr` cases

### Story 4.8: Port RubyUnderstander Facade

**Details:**
Port `compiler/src/ruby/ruby_understander.cr` to
`compiler_zig/src/ruby/ruby_understander.zig`.

Facade that delegates to tree-sitter extractors.

**Acceptance Criteria:**
- All delegation functions return identical results to Crystal
- Tests validate each function

---

## Epic 5: Lexbor Integration & HTML Parsing

**Goal:** Port the Lexbor wrapper types and classes that depend on HTML DOM parsing
(BindExtractor and ComponentGenerator's `traverse`).

### Story 5.1: Port Lexbor Document and Node Wrappers

**Details:**
Create `compiler_zig/src/lexbor/document.zig` wrapping the Lexbor C API via
`@cImport`.

```zig
const c = @cImport({
    @cInclude("lexbor/html/html.h");
    @cInclude("lexbor/dom/dom.h");
});

const Document = struct {
    doc: *c.lxb_html_document_t,

    pub fn parse(html: []const u8) !Document {
        const doc = c.lxb_html_document_create() orelse return error.DocumentCreateFailed;
        const status = c.lxb_html_document_parse(doc, html.ptr, html.len);
        if (status != c.LXB_STATUS_OK) return error.ParseFailed;
        return .{ .doc = doc };
    }

    pub fn body(self: Document) ?Node {
        const b = c.lxb_html_document_body_element(self.doc) orelse return null;
        return Node{ .raw = @ptrCast(b) };
    }

    pub fn deinit(self: *Document) void {
        c.lxb_html_document_destroy(self.doc);
    }
};

const Node = struct {
    raw: *c.lxb_dom_node_t,

    pub fn tagName(self: Node) []const u8 {
        // Returns "_text", "_em_comment", or element tag name
        var len: usize = 0;
        const name = c.lxb_dom_element_local_name(@ptrCast(self.raw), &len);
        return name[0..len];
    }

    pub fn children(self: Node, allocator: Allocator) !std.ArrayList(Node) {
        var result = std.ArrayList(Node).init(allocator);
        var child = c.lxb_dom_node_first_child(self.raw);
        while (child) |ch| {
            try result.append(Node{ .raw = ch });
            child = c.lxb_dom_node_next(ch);
        }
        return result;
    }

    // IMPORTANT: children() includes ALL child types (text, comment, element)
    // This is critical for path generation in ComponentGenerator
};
```

**Acceptance Criteria:**
- Can parse HTML, get body, traverse children
- Text nodes: `tagName()` returns `"_text"`
- Comment nodes: `tagName()` returns `"_em_comment"` (Lexbor quirk)
- `children()` includes text/comment/element nodes (not just elements)
- Attribute access/removal works
- Serialization matches Crystal Lexbor shard output

### Story 5.2: Port BindExtractor

**Details:**
Port `compiler/src/bind_extractor.cr` to
`compiler_zig/src/lexbor/bind_extractor.zig`.

Walk all elements, find `bind:` prefixed attributes, strip prefix, track
bindings, return cleaned HTML.

**Acceptance Criteria:**
- `extract('<div bind:class="{active}">hi</div>')` returns bindings map
- `bind:` prefix removed from output HTML
- Non-bind attributes preserved
- Tests port Crystal `bind_extractor_spec.cr` cases

---

## Epic 6: QuickJS Integration & Opal Compilation

**Goal:** Port the QuickJS engine wrappers and Opal compiler integration. This is
what converts Ruby code to JavaScript.

### Story 6.1: Port QuickJS Value and Error Types

**Details:**
Port value wrapper and error types to
`compiler_zig/src/quickjs/value.zig`.

```zig
const Value = struct {
    ctx: *c.JSContext,
    val: c.JSValue,

    pub fn toString(self: Value, allocator: Allocator) ![]u8 {
        const str_val = c.JS_ToString(self.ctx, self.val);
        defer c.JS_FreeValue(self.ctx, str_val);
        var len: usize = 0;
        const ptr = c.JS_ToCStringLen2(self.ctx, &len, str_val, 0);
        defer c.JS_FreeCString(self.ctx, ptr);
        return try allocator.dupe(u8, ptr[0..len]);
    }

    pub fn deinit(self: *Value) void {
        c.JS_FreeValue(self.ctx, self.val);
    }
};

const QuickJSError = error{
    SyntaxError,
    ReferenceError,
    TypeError,
    RangeError,
    InternalError,
    EvalError,
    GenericError,
};
```

**Acceptance Criteria:**
- `Value.toString()` returns JavaScript string representation
- Error types exist
- Tests cover value conversion

### Story 6.2: Port QuickJS Runtime

**Details:**
Port `compiler/src/quickjs/runtime.cr` to
`compiler_zig/src/quickjs/runtime.zig`.

```zig
const Runtime = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,

    pub fn init() Runtime {
        const rt = c.JS_NewRuntime();
        const ctx = c.JS_NewContext(rt);
        return .{ .rt = rt, .ctx = ctx };
    }

    pub fn eval(self: *Runtime, code: []const u8) !Value {
        const result = c.JS_Eval(self.ctx, code.ptr, code.len, "<eval>", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(result)) return self.getError();
        return Value{ .ctx = self.ctx, .val = result };
    }

    pub fn deinit(self: *Runtime) void {
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
    }
};
```

**Acceptance Criteria:**
- `runtime.eval("1 + 2").toString()` returns `"3"`
- Global property get/set works
- `evalFile` works
- Memory limits settable
- Cleanup works without leaks
- Tests port Crystal `quickjs_spec.cr` cases

### Story 6.3: Port QuickJS Opal Compiler

**Details:**
Port `compiler/src/quickjs/opal.cr` to `compiler_zig/src/quickjs/opal.zig`.

Loads Opal runtime and parser into QuickJS, provides `compile(ruby_code,
filename, requirable)`.

Consider using `@embedFile` for `opal.js` and `opal-parser.js` to eliminate
runtime file I/O for these large files.

**Acceptance Criteria:**
- `compiler.compile("puts 'hello'", "test.rb", true)` returns JavaScript
- Output matches Crystal Opal compiler output exactly
- Tests port Crystal `opal_spec.cr` cases

### Story 6.4: Port QuickJS Opal Builder

**Details:**
Port `compiler/src/quickjs/opal_builder.cr` to
`compiler_zig/src/quickjs/opal_builder.zig`.

Methods: `addRawJs`, `addStdlib`, `compile`, `compileWithCache`, `build`.

For MD5 caching, use `std.crypto.hash.Md5` (in Zig stdlib).

**Acceptance Criteria:**
- `addStdlib("await")` loads await.js
- `compile(code, path)` compiles and stores result
- `compileWithCache` uses cache on repeated calls
- `build(null)` joins all parts
- Tests port Crystal opal_spec.cr builder cases

---

## Epic 7: Caching Layer

**Goal:** Port the WarthogDB-backed build cache.

### Story 7.1: Port Cache Module

**Details:**
Port `compiler/src/caching/cache.cr` to `compiler_zig/src/caching/cache.zig`.

Wraps WarthogDB C API (already imported in Epic 0) with `has`, `get`, `put`,
`close` methods.

Creates cache directory at `~/.cache/mochi` using `std.fs`.

```zig
const Cache = struct {
    db: *c.warthog_db_t,

    pub fn init(allocator: Allocator) !Cache {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.cache/mochi", .{home});
        try std.fs.cwd().makePath(cache_dir);
        const db_path = try std.fmt.allocPrint(allocator, "{s}/build.db", .{cache_dir});
        const db = c.warthog_open(db_path.ptr) orelse return error.DbOpenFailed;
        return .{ .db = db };
    }

    pub fn get(self: *Cache, key: []const u8) ?[]const u8 { ... }
    pub fn put(self: *Cache, key: []const u8, value: []const u8) !void { ... }
    pub fn has(self: *Cache, key: []const u8) bool { ... }

    pub fn deinit(self: *Cache) void {
        c.warthog_close(self.db);
    }
};
```

**Acceptance Criteria:**
- Cache directory created at `~/.cache/mochi` if missing
- `put("k", "v")` + `has("k")` returns true
- `get("k")` returns `"v"`
- `deinit` doesn't crash
- Tests port Crystal `warthogdb_spec.cr` cases

---

## Epic 8: Component Generator

**Goal:** Port the `ComponentGenerator` -- the heart of Mochi's code generation.
Takes parsed component metadata and produces the JavaScript Web Component class.

### Story 8.1: Port Binding Type and Traverse

**Details:**
Port the `Binding` type and `traverse` function from
`compiler/src/webcomponents/component_generator.cr`.

```zig
const BindingType = enum { text, html, attr, anchor };

const Binding = struct {
    path: std.ArrayList(usize),
    binding_type: BindingType,
    value: []const u8,
    name: ?[]const u8,  // attribute name, if applicable
};
```

`traverse` walks the Lexbor DOM tree and builds a list of `Binding` objects:
- Text nodes (`"_text"`): scan for `{var}`. Pure-variable = `:html`, mixed = `:text`
- Comment nodes (`"_em_comment"`): check for `if-anchor` / `each-anchor`
- Element nodes: check `bind:` attrs, `on:*` attrs (skip), `{var}` in attr values
- Recurse into `children` using index to build path arrays

**CRITICAL:** Path indices are based on `children` (ALL child types: text,
comment, element) -- NOT just element children.

**Acceptance Criteria:**
- Text binding detected for `<span>{count}</span>`
- HTML binding detected for pure variable nodes
- Anchor bindings detected for `<!--if-anchor-0-->`
- Attribute bindings detected for `class="{active}"`
- `bind:` attributes handled and removed
- `on:*` attributes skipped
- Path arrays correctly reflect childNodes indices
- Tests validate binding extraction

### Story 8.2: Port ComponentGenerator Generate

**Details:**
Port the main `generate` function that produces the full JavaScript Web Component.

Output structure:
1. Template registration (BEFORE `customElements.define`)
2. Class definition extending `MochiComponent`
3. `customElements.define('tag-name', ClassWebComp)`

All JavaScript generated via `std.ArrayList(u8)` string building.

**IMPORTANT:** Backtick characters in CSS/HTML must be escaped (`\``). `${` must
be escaped to `\${` to prevent template literal interpolation.

**Acceptance Criteria:**
- Generated JS matches Crystal output byte-for-byte for sample components
- Template registration before `customElements.define`
- Event delegation handles click and change
- Reactive update methods generated for each reactive var
- Internal `__mochi_attr_cond_*` / `__mochi_attr_hash_*` excluded from
  `observedAttributes`
- Tests port Crystal `component_generator_spec.cr` cases

---

## Epic 9: Build Pipeline

**Goal:** Port the three build orchestration modules that tie everything together.

### Story 9.1: Port BuilderMan

**Details:**
Port `compiler/src/entrypoints/building/builder_man.cr` to
`compiler_zig/src/entrypoints/builder_man.zig`.

Manages build directories. For shell commands like `mkdir -p` and `cp -r`, use
Zig's `std.fs` API directly:
```zig
try std.fs.cwd().makePath(path);
// For recursive copy, implement using std.fs.Dir.walk
```

**Acceptance Criteria:**
- Constructor creates build directory structure
- Old artifacts cleaned except `runtime.js`
- File copying works
- Build ID unique per instantiation

### Story 9.2: Port Compiler (Transpiler)

**Details:**
Port `compiler/src/entrypoints/building/transpiler.cr` to
`compiler_zig/src/entrypoints/transpiler.zig`.

Core class that orchestrates all processing steps.

**`transpileDirectory`:**
1. Walk `input_dir` for `*.rb` files using `std.fs.Dir.walk`
2. For each file: `transpileComponent`
3. Write transformed Ruby back to `builder_man.ruby_src_dir`
4. Comment out Sorbet signatures
5. Generate Root.rb
6. Compile all Ruby to JS via QuickJS Opal Builder
7. Assemble bundle.js

**Concurrency option:** Zig has `std.Thread` and thread pools. The Crystal
version uses `spawn` + `Channel`. Consider using Zig's thread pool for parallel
component processing if needed for performance, but start sequential.

**Acceptance Criteria:**
- `transpileComponent` produces identical Ruby transformations as Crystal
- `transpileDirectory` produces identical `bundle.js`
- All HTML processing steps applied in correct order
- Tests validate full component transpilation

### Story 9.3: Port BuildMain

**Details:**
Port `compiler/src/entrypoints/building/build_main.cr` to
`compiler_zig/src/entrypoints/build_main.zig`.

Orchestrates the full build pipeline. Use `std.time.Timer` for build timing.

**Acceptance Criteria:**
- `build(input_dir, output_dir, ...)` produces identical output
- All build steps execute in order
- Artifacts cleaned after success
- Timing printed per step

---

## Epic 10: CLI, Initializer & Dev Server

**Goal:** Port the CLI, project initializer, and optionally the dev server.

### Story 10.1: Port CLI Argument Parser

**Details:**
Port CLI from `compiler/src/mochi.cr` to `compiler_zig/src/main.zig`.

Use `std.process.ArgIterator` with a custom parser for the flags: `-i`, `-o`,
`--init`, `--minimize`, `--typecheck`, `--dev`, `--root`, `--config`,
`--keep_granular_build_artifacts`, `-h`.

For JSON parsing (`js_to_cr_array`), use `std.json.parseFromSlice` -- Zig has
JSON in stdlib.

**Acceptance Criteria:**
- `mochi -i ./src -o ./build` triggers build
- `mochi --initialize=MyProject` triggers initializer
- `mochi -h` prints help
- All flags parsed correctly
- Error messages for unknown/missing args

### Story 10.2: Port Initializer

**Details:**
Port `compiler/src/initializer.cr` to `compiler_zig/src/initializer.zig`.

Generates scaffold files. Use `@embedFile` for template content or inline string
literals.

**Acceptance Criteria:**
- `init("my_project")` creates directory with all scaffold files
- Existing directory triggers abort
- File contents match Crystal output

### Story 10.3: Port DevServer

**Details:**
Port `compiler/src/tooling/dev_server.cr` to
`compiler_zig/src/tooling/dev_server.zig`.

Zig has `std.http.Server` in its stdlib, making this straightforward (unlike the
Spinel port which had no HTTP support).

**Acceptance Criteria:**
- `mochi dev --config=config.json --root=./public` starts server on port 27490
- Routes from config served
- Static files served with correct content types
- Falls back to index.html for root

---

## Epic 11: End-to-End Verification & Cutover

**Goal:** Run the full test suite, fix discrepancies, benchmark, and prepare for
production cutover.

### Story 11.1: Run Full E2E Test Suite

**Details:**
Run `task e2e` using the Zig compiler. All 32 Playwright tests must pass.

**Acceptance Criteria:**
- All 32 E2E tests pass with Zig-compiled output
- No visual or behavioral differences

### Story 11.2: Byte-for-Byte Output Comparison

**Details:**
Diff Crystal vs Zig compiler outputs for `devground/components`:
- `bundle.js` should be identical
- `runtime.js` should be identical

**Acceptance Criteria:**
- `diff crystal_bundle.js zig_bundle.js` reports no differences, OR
- All differences documented and verified as semantically identical

### Story 11.3: Run Zig Unit Tests

**Details:**
All inline `test` blocks across the codebase should pass. Port Crystal spec
assertions to Zig inline tests in each module.

Test pattern:
```zig
test "ConditionalProcessor handles nested blocks" {
    const result = try ConditionalProcessor.process(
        testing.allocator,
        "{if @a}{if @b}inner{end}{end}",
    );
    defer result.deinit();
    try testing.expectEqualStrings("<!--if-anchor-0-->", result.html);
    try testing.expectEqual(@as(usize, 2), result.conditionals.items.len);
}
```

**Acceptance Criteria:**
- `zig build test` passes all tests
- Coverage matches Crystal spec coverage

### Story 11.4: Performance Benchmarking

**Details:**
Compare build times and binary sizes:
1. Cold build (no cache) of `devground/components`
2. Warm build (with cache)
3. Single component transpilation time
4. Binary size comparison

Expected improvements over Crystal:
- Faster startup (no Crystal runtime initialization)
- Smaller binary (no GC, no Crystal stdlib)
- Similar or better throughput (LLVM-optimized code)
- Cross-compilation capability (new)

**Acceptance Criteria:**
- Benchmark results documented in `notes/ZIG_BENCHMARKS.md`
- Build time competitive with Crystal (target: within 1.5x or faster)
- Binary size documented (expect significant reduction)

### Story 11.5: Update Taskfile and Documentation

**Details:**
Update `Taskfile.yml`:
- `build-zig` -- compile the Zig binary
- `run-zig` -- build + run against devground
- `test-zig` -- run all Zig tests
- `e2e-zig` -- build + E2E with Zig
- `regression` -- compare outputs

**Acceptance Criteria:**
- All Taskfile entries work
- README documents Zig build instructions
- `task run-zig` is a drop-in replacement for `task run`

### Story 11.6: Cutover Plan

**Details:**
Document cutover process in `notes/ZIG_CUTOVER.md`:
1. Ensure all E2E tests pass
2. Replace `task run` default to use Zig
3. Keep Crystal compiler as `task run-crystal` for fallback
4. After N releases with Zig, remove Crystal compiler code
5. Set up cross-compilation CI for Linux/macOS/Windows binaries

**Acceptance Criteria:**
- Cutover plan with clear steps
- Rollback procedure documented
- Timeline for Crystal code removal
- Cross-compilation targets listed

---

## Appendix A: Module-by-Module Mapping

| Crystal File | Zig File | Epic |
|---|---|---|
| `ruby/ruby_def.cr` | `data_models/ruby_def.zig` | 1 |
| `ruby/ruby_var.cr` | `data_models/ruby_var.zig` | 1 |
| `ruby/ruby_endable_statement.cr` | `data_models/ruby_endable_statement.zig` | 1 |
| `webcomponents/web_component.cr` | `data_models/web_component.zig` | 1 |
| `mochi_cmp.cr` | `data_models/mochi_component.zig` | 1 |
| `ruby/inject_utils.cr` | `ruby/inject_utils.zig` | 1 |
| `html/conditional_processor.cr` | `html/conditional_processor.zig` | 2 |
| `html/each_processor.cr` | `html/each_processor.zig` | 2 |
| `html/attribute_conditional_extractor.cr` | `html/attribute_conditional_extractor.zig` | 2 |
| `html/attribute_hash_extractor.cr` | `html/attribute_hash_extractor.zig` | 2 |
| `html/event_argument_extractor.cr` | `html/event_argument_extractor.zig` | 2 |
| `ruby/conditional_method_generator.cr` | `ruby/conditional_method_generator.zig` | 3 |
| `ruby/each_method_generator.cr` | `ruby/each_method_generator.zig` | 3 |
| `ruby/attribute_method_generator.cr` | `ruby/attribute_method_generator.zig` | 3 |
| `ruby/attribute_hash_generator.cr` | `ruby/attribute_hash_generator.zig` | 3 |
| `generated/*.cr` | `batteries/fragment_loader.zig` | 3 |
| `batteries/core_battery.cr` | `batteries/core_battery.zig` | 3 |
| `batteries/sorbet_types_battery.cr` | `batteries/sorbet_types_battery.zig` | 3 |
| `ruby/ruby_rewriter.cr` | `ruby/ruby_rewriter.zig` | 3 |
| `js/js_logger.cr` | `js/js_logger.zig` | 3 |
| `opal/opal_runtime_generator.cr` | `opal/opal_runtime_generator.zig` | 3 |
| `tree-sitter/bindings.cr` | `tree_sitter/bindings.zig` | 4 |
| `tree-sitter/ruby_parser.cr` | `tree_sitter/ruby_parser.zig` | 4 |
| `tree-sitter/class_extractor.cr` | `tree_sitter/class_extractor.zig` | 4 |
| `tree-sitter/method_body_extractor.cr` | `tree_sitter/method_body_extractor.zig` | 4 |
| `tree-sitter/property_extractor.cr` | `tree_sitter/property_extractor.zig` | 4 |
| `tree-sitter/imports_extractor.cr` | `tree_sitter/imports_extractor.zig` | 4 |
| `tree-sitter/string_extractor.cr` | `tree_sitter/string_extractor.zig` | 4 |
| `tree-sitter/instance_var_analyzer.cr` | `tree_sitter/instance_var_analyzer.zig` | 4 |
| `ruby/ruby_understander.cr` | `ruby/ruby_understander.zig` | 4 |
| `bind_extractor.cr` | `lexbor/bind_extractor.zig` | 5 |
| `js/qjs_bindings.cr` | `quickjs/bindings.zig` | 6 |
| `quickjs/value.cr` | `quickjs/value.zig` | 6 |
| `quickjs/error.cr` | `quickjs/value.zig` (merged) | 6 |
| `quickjs/runtime.cr` | `quickjs/runtime.zig` | 6 |
| `quickjs/opal.cr` | `quickjs/opal.zig` | 6 |
| `quickjs/opal_builder.cr` | `quickjs/opal_builder.zig` | 6 |
| `caching/warthog_bindings.cr` | `caching/warthog_bindings.zig` | 7 |
| `caching/warthogdb.cr` | `caching/warthog_bindings.zig` (merged) | 7 |
| `caching/cache.cr` | `caching/cache.zig` | 7 |
| `webcomponents/component_generator.cr` | `webcomponents/component_generator.zig` | 8 |
| `entrypoints/building/builder_man.cr` | `entrypoints/builder_man.zig` | 9 |
| `entrypoints/building/transpiler.cr` | `entrypoints/transpiler.zig` | 9 |
| `entrypoints/building/build_main.cr` | `entrypoints/build_main.zig` | 9 |
| `mochi.cr` | `main.zig` | 10 |
| `initializer.cr` | `initializer.zig` | 10 |
| `tooling/dev_server.cr` | `tooling/dev_server.zig` | 10 |

## Appendix B: Zig Advantages over Spinel Port

| Concern | Spinel Risk | Zig Solution |
|---|---|---|
| TSNode struct-by-value (32 bytes) | FFI can't pass structs; needs C shim | `@cImport` handles natively |
| JSValue struct-by-value (16 bytes) | FFI can't pass structs; needs C shim | `@cImport` handles natively |
| Lexbor callback-based API | Complex FFI for function pointers | Zig function pointers work with C |
| Regex support | Spinel has regex in stdlib | Manual parsers or PCRE2 via `@cImport` |
| JSON parsing | No JSON stdlib; hand-roll parser | `std.json` in stdlib |
| HTTP server | No HTTP stdlib; needs FFI or external tool | `std.http.Server` in stdlib |
| MD5 hashing | FFI to OpenSSL or hand-roll | `std.crypto.hash.Md5` in stdlib |
| Memory management | GC (Spinel uses Boehm GC) | Explicit allocators; arena for compiler passes |
| Cross-compilation | Compile on target platform | Single-command cross-compile from any host |
| Binary size | ~5-10MB (Ruby runtime + GC) | ~1-3MB expected (no runtime overhead) |
| String interpolation bugs | Spinel has known yield/interp bugs | Zig `std.fmt` is rock-solid |
| `puts` in yield blocks dropped | Spinel quirk, needs workarounds | No such issues |
| Global mutation in blocks broken | Spinel quirk, needs helper functions | Zig closures work correctly |
| `rindex` offset parameter broken | Spinel quirk, needs string slicing workaround | `std.mem.lastIndexOf` works correctly |

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

## Appendix D: Zig 0.16.0 Specifics

Key Zig 0.16.0 features relevant to this port:

- **`@cImport` / `@cInclude`**: Translate C headers to Zig types at compile time.
  This is the foundation for all C library integration.
- **`build.zig`**: Declarative build system. Replaces Makefiles, handles C
  compilation, linking, and cross-compilation.
- **`build.zig.zon`**: Package manifest for Zig package manager. Use for any Zig
  dependencies (likely none needed -- all deps are C libraries).
- **Arena allocators**: `std.heap.ArenaAllocator` -- ideal for compiler pass
  memory management.
- **`@embedFile`**: Embed file contents as compile-time constant. Perfect for
  fragment loading, JS runtime files.
- **Inline tests**: `test "name" { ... }` blocks in any `.zig` file, run with
  `zig build test`.
- **Error unions**: `!T` return type with `try`/`catch` -- replaces Crystal
  exceptions.
- **Optionals**: `?T` with `orelse` and `if (opt) |val|` -- replaces Crystal `nil`.
- **`std.json`**: Full JSON parser/serializer in stdlib.
- **`std.http.Server`**: HTTP server in stdlib.
- **`std.crypto.hash.Md5`**: MD5 in stdlib.
- **`std.fs`**: File system operations (read, write, walk, mkdir).
- **`std.process`**: Argument parsing, environment variables, child processes.

---

## Appendix E: Porting Issues Encountered

### `format()` Signature Changed Between Zig 0.14 and 0.15

**Description:**
The `format()` method signature for custom struct formatting changed between Zig versions. Older code and tutorials use `comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype`, but Zig 0.15.1 requires a `*std.io.Writer` parameter.

**Example (0.14 style - DOES NOT COMPILE in 0.15.1):**
```zig
pub fn format(
    self: Foo,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{s}", .{self.value});
}
```

**Example (0.15.1 style - WORKS):**
```zig
pub fn format(self: Foo, w: *std.io.Writer) std.io.Writer.Error!void {
    try w.writeAll(self.value);
}
```

**How it should behave:**
The old 4-argument `format()` signature should compile, or there should be clear migration documentation.

**How it behaves in reality:**
Zig 0.15.1 throws a compile error when using the old signature:
```
error: member function expected 3 argument(s), found 1
            'f' => return value.format(w),
```
To invoke the new `format()`, use the `{f}` format specifier instead of `{s}` or `{}`.

**Workaround:**
Use the new `*std.io.Writer` signature. Call with `std.fmt.allocPrint(allocator, "{f}", .{value})`.
