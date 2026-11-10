# Fixing Multi-Byte Character Handling in Tree-Sitter AST Wrapper

## Architecture Context
The Mochi compiler relies on a Tree-Sitter wrapper (`compiler/src/tree-sitter/ruby_parser.cr`) to parse Ruby source code and extract components like HTML, CSS, and methods. Tree-Sitter natively operates on **byte offsets** (`ts_node_start_byte`, `ts_node_end_byte`). However, Crystal's standard string indexing (`String#[]`) operates on **character offsets**. 

When source files contain multi-byte Unicode characters (e.g., emojis, box-drawing characters like `│`, arrows like `←`), the byte offset diverges from the character offset. This discrepancy causes Crystal to attempt to slice the string using byte values as character indices, leading to an `Index out of bounds` exception during compilation. The compiler's exception handling swallows the trace, resulting in silent failures where components are dropped without clear warnings.

---

## Execution Plan: Epics & Stories

### Epic 1: The Core Fix (Tree-Sitter Wrapper)
*Address the fundamental discrepancy between Tree-Sitter's byte-based offsets and Crystal's character-based string handling.*

#### Story 1.1: Fix String Extraction in AST Node
**Goal:** Modify the `TreeSitter::Node#text` method to correctly slice the source string using byte boundaries instead of character boundaries.
**Details:**
- Locate `compiler/src/tree-sitter/ruby_parser.cr`.
- Identify the `text` method in the `TreeSitter::Node` class.
- The current implementation reads: `@source[start_byte...end_byte]`.
- Change this to use Crystal's `String#byte_slice(start, count)` method, which safely extracts a substring based on raw byte offsets.
- The new logic should calculate the byte length (`end_byte - start_byte`) and extract exactly that slice.
**Acceptance Criteria:**
- [ ] `TreeSitter::Node#text` uses `byte_slice` instead of range indexing.
- [ ] Multi-byte strings extracted from the AST maintain exact byte fidelity without corruption or truncation.

### Epic 2: Compiler Error Visibility
*Ensure that if the compiler encounters structural or parsing failures in the future, it provides actionable developer feedback rather than failing silently.*

#### Story 2.1: Enhance Exception Logging in Transpiler
**Goal:** Upgrade the generic `rescue` block in the transpiler to print full stack traces, making file-level crashes immediately debuggable.
**Details:**
- Locate `compiler/src/entrypoints/building/transpiler.cr`.
- Find the `rescue ex` block inside the `spawn` block of the `transpile_directory` method.
- Currently, it only prints `ex.message` (e.g., "Error reading file... Index out of bounds"), which strips away the location of the failure.
- Update the log statement to utilize `ex.inspect_with_backtrace` to dump the full Crystal stack trace to standard error.
**Acceptance Criteria:**
- [ ] Exceptions thrown during individual file compilation emit a complete stack trace to the console.
- [ ] The error message clearly identifies the specific file that triggered the failure.

### Epic 3: Verification and Prevention
*Create automated tests to ensure multi-byte character support never regressions.*

#### Story 3.1: Add Multi-byte Character Test Suite
**Goal:** Introduce unit tests that explicitly challenge the `TreeSitter::StringExtractor` and `TreeSitter::InstanceVarAnalyzer` with complex Unicode payloads.
**Details:**
- Create a new dummy Ruby file in `compiler/spec_data/ruby/` containing a component with emojis, box-drawing characters (`┌─┐`), and multi-byte arrows (`←, →`) in its `html` and `css` methods.
- Create a corresponding spec in `compiler/spec/tree-sitter/string_extractor_spec.cr` that attempts to parse and extract strings from this file.
- Add a test in `compiler/spec/ruby/ruby_understander_spec.cr` verifying that the overall component builds without throwing an exception.
**Acceptance Criteria:**
- [ ] A test exists containing known failure-inducing characters (e.g., `←`, `│`).
- [ ] The test runner successfully compiles the spec without throwing an `Index out of bounds` exception.
- [ ] The extracted HTML/CSS string perfectly matches the multi-byte string defined in the test file.