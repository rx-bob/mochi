# Spinel Porting Findings

This document catalogs bugs, limitations, and workarounds discovered while porting the Mochi compiler from Crystal to Ruby for the Spinel runtime.

## Issue 1: String#index returns 0 instead of nil for non-matching substrings

**Discovered in:** Story 2.2 (EachProcessor)  
**Severity:** High — silently produces wrong results  
**File affected:** `compiler_rb/src/html/each_processor.rb`

### Problem
`String#index(substr)` returns `0` instead of `nil` when the substring is not found, but only for certain substring values. This was observed when searching for a comma `","` in the string `"item"`.

### Impact
Code like this silently breaks:

```ruby
comma_idx = str.index(",")
if comma_idx  # truthy check — always passes with 0!
  # incorrectly enters branch
end
```

### Workaround
Use a manual character scan loop instead of `String#index` for existence checks:

```ruby
def manual_index(str, char, start_pos)
  i = start_pos
  while i < str.length
    return i if str[i, 1] == char
    i += 1
  end
  -1  # sentinel for "not found"
end

comma_idx = manual_index(item_str, ",", 0)
if comma_idx >= 0
  # found
else
  # not found
end
```

### Notes
- `String#index` with single-character search strings like `"}"` seems to work correctly for finding actual matches.
- The bug appears to be specific to `nil` return handling — Spinel may be converting `nil` to `0` in certain call paths.

---

## Issue 2: Manual array-index stack manipulation breaks type inference

**Discovered in:** Story 2.1 (ConditionalProcessor)  
**Severity:** High — compilation fails with cryptic errors  
**File affected:** `compiler_rb/src/html/conditional_processor.rb`

### Problem
Spinel cannot infer types through manual array indexing patterns used for stack simulation:

```ruby
# BROKEN in Spinel:
stack = Array(StackFrame).new
stack_size = 0
stack[stack_size] = StackFrame.new(...)
stack_size += 1
frame = stack[stack_size - 1]
```

This pattern works in Crystal but causes Spinel compilation errors related to unresolved types on array elements.

### Workaround
Use idiomatic `push` / `delete_at` / `pop` operations:

```ruby
# WORKS in Spinel:
stack = []
stack.push(StackFrame.new(...))
frame = stack[stack.length - 1]
stack.delete_at(stack.length - 1)
```

### Notes
- The Crystal source used manual indexing for performance; Spinel handles the `push`/`pop` pattern correctly.
- Related: `Array.new` with a type argument (`Array(StackFrame).new`) also caused issues; use `[]` literal instead.

---

## Issue 3: Block/proc parameters typed as int in cross-module calls

**Discovered in:** Story 2.1 (ConditionalProcessor)  
**Severity:** High — compilation fails  
**File affected:** `compiler_rb/src/html/conditional_processor.rb`

### Problem
Methods defined with a block parameter that receive proc/block values from other static methods get typed as `int` instead of pointer types in Spinel's C output:

```ruby
# BROKEN in Spinel:
def generate_element(tag_name, attributes, anchor_id, block)
  # block is typed as int here, not string pointer
end

generate_element("div", nil, "abc", "<!--if-anchor-0-->")
#                   ^^^ string passed where int expected
```

### Workaround
Inline the anchor generation or avoid block parameters in methods called across module boundaries:

```ruby
# WORKS in Spinel:
element = "<!--if-anchor-#{block.id}-->"
result = replace_range(result, block.start_pos, block.end_pos, element)
```

### Notes
- The Crystal source defined `generate_element` as a reusable helper; inlining was the simplest fix.
- This may be related to Spinel's inability to infer union types across method boundaries.

---

## Issue 4: nil assigned through method parameters produces garbage values

**Discovered in:** Story 2.2 (EachProcessor)  
**Severity:** Medium — causes test failures with confusing output  
**File affected:** `compiler_rb/src/html/each_processor.rb`

### Problem
When `nil` is passed through a chain of method parameters and assigned to an instance variable, Spinel sometimes produces garbage integer values instead of proper `nil`:

```ruby
# BROKEN in Spinel:
def make_match(loop_def, content_start = nil)
  EachMatch.new(loop_def, content_start)
end

make_match(nil, nil)
# Results in garbage data inside EachMatch instance
```

The `nil` value inside the object behaves unpredictably in comparisons and string conversions.

### Workaround
Avoid `nil` as a default parameter value when the parameter will be stored in an instance variable. Instead:

```ruby
# WORKS in Spinel:
def make_match(loop_def, content_start)
  EachMatch.new(loop_def, content_start)
end

# Pass explicit nil at call site:
make_match(nil, 0)  # use sentinel value instead
```

Or use a sentinel pattern (e.g., `0` or `""`) to represent "unset" state, and check for the sentinel rather than `nil`.

### Notes
- Direct `nil` assignment to local variables works fine: `a = nil; a == nil` → `true`
- The issue is specific to `nil` flowing through constructor parameters into instance variables.
- `nil` stored in instance variables via direct constructor call (e.g., `LoopDef.new("a", "b", nil)`) works correctly.

---

## Issue 5: assert_equal with nil vs empty string

**Discovered in:** Story 2.2 (EachProcessor)  
**Severity:** Low — test assertion style matters  
**File affected:** `compiler_rb/spec/html/each_processor_spec.rb`

### Problem
Using `assert_equal("", some_value)` where `some_value` is `nil` fails in Spinel with a confusing error. The assertion framework's error message generation (`inspect` on `nil`) produces garbage.

### Workaround
Split the assertion into two branches:

```ruby
# BROKEN in Spinel:
assert_equal("", loop_def.index_name) if expected_index_name == nil

# WORKS in Spinel:
assert_equal("", loop_def.index_name) if expected_index_name == nil
# Use separate assertion for non-nil case
assert_equal(expected_index_name, loop_def.index_name) unless expected_index_name == nil
```

Or avoid comparing `nil` against empty string entirely by normalizing the representation.

---

## Issue 6: String interpolation with nil instance variables

**Discovered in:** Story 2.2 (EachProcessor)  
**Severity:** Low — produces wrong output  
**File affected:** `compiler_rb/src/html/each_processor.rb`

### Problem
When `nil` is stored in an instance variable and used in string interpolation, Spinel outputs `"0"` instead of `""`:

```ruby
class Foo
  def initialize(val)
    @val = val
  end
  def to_s
    "val=#{@val}"  # outputs "val=0" when @val is nil
  end
end
```

### Workaround
Explicitly handle nil in to_s methods:

```ruby
def to_s
  val_str = @val ? @val.to_s : ""
  "val=#{val_str}"
end
```

Or avoid storing `nil` in instance variables that will be interpolated (use `""` sentinel instead).

---

## General Porting Guidelines

Based on these findings, the following patterns are recommended for all future Spinel ports:

1. **Use `push`/`pop`/`delete_at` on arrays** — never manual index juggling for stacks.
2. **Avoid `nil` as default parameter values** — especially when stored in instance variables.
3. **Use sentinel values** — `-1` for "not found", `""` for "no index name" instead of `nil`.
4. **Inline small helpers** — especially those with block/string parameters called across static methods.
5. **Prefer manual loops over `String#index`** — when the result is used for existence checks rather than position extraction.
6. **Test under Spinel early** — many issues only surface during Spinel compilation, not under MRI Ruby.

---

## Files Modified to Work Around Spinel Issues

| File | Story | Issue Workaround |
|---|---|---|
| `compiler_rb/src/html/conditional_processor.rb` | 2.1 | Array stack → push/delete_at; inlined generate_element |
| `compiler_rb/src/html/each_processor.rb` | 2.2 | String#index → manual scan; nil → "" sentinel for index_name; assert_equal split |
