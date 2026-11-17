# Mochi lint contract

`mochi lint` is a read-only static check for Mochi projects. It parses Ruby
sources with Tree-sitter, reuses the compiler's template and class extractors,
and reports diagnostics without building the application, running its Ruby
code, starting a VM, or requiring a browser or Node.js.

Linting is an explicit project check. Ordinary compilation, `mochi dev`, and
`mochi test` do not run it. Generated projects provide `task lint` and a
`task check` gate that runs lint before behavior tests. Repository CI must run
the command explicitly. Lint adds no files, adapters, or bytes to a shipped
application bundle.

## Command line

```text
mochi lint [options]
```

| Option | Behavior |
| --- | --- |
| no options | Lint the current directory as the project |
| `-i PROJECT`, `--input=PROJECT` | Use `PROJECT` as the project boundary |
| `--config=PATH` | Load exactly this configuration file |
| `--format=text` | Emit text diagnostics (default) |
| `--format=json` | Emit one JSON object with `schema_version: 1` |
| `-h`, `--help` | Print usage and exit 0 |

The command rejects unknown options, missing option arguments, unexpected
positional arguments, unsupported formats, and conflicting repeated values
with exit 2. It does not accept file lists on standard input, a fix mode, a
severity bypass or fail-on threshold, remote configuration, plugins, or
baseline generation.

The project path must exist and must not itself be a symlink.

## Configuration discovery and roots

Without `--config`, lint searches upward from the project directory for the
nearest `.mochi-lint.yml`. It checks each directory before stopping at the
first directory that contains a `.git` entry. It does not merge configurations
and does not continue above the repository boundary. A `.mochi-lint.yml` path
that exists but is not a regular file is a configuration error.

`--config=PATH` takes precedence. The path is resolved from the current working
directory and must name a regular file. An invalid explicit path never falls
back to discovery.

The project and config roots interact as follows:

- With `-i PROJECT`, `PROJECT` is the analysis boundary.
- Without `-i` and with a discovered or explicit config, the config directory
  becomes the project root.
- Without any config, built-in defaults are rooted at the selected project.
- Config `include` and `exclude` globs always resolve relative to the config
  directory.
- Source selection is the intersection of the project boundary and the config
  globs. An explicit project below a config root must therefore still be
  matched by the config's include globs.
- The project and config directories must contain one another. Unrelated
  directories are a configuration error.

## Configuration schema

The standard policy is:

```yaml mochi-lint-config
version: 1
include:
  - "lib/**/*.rb"
rules:
  correctness/unknown-handler: error
  correctness/timer-callback: error
  correctness/child-props: error
  correctness/event-payload: error
  components/prop-write: warning
  metrics/method-length:
    severity: warning
    max: 60
  metrics/line-length: off
  metrics/nesting-depth:
    severity: warning
    max: 4
  metrics/component-methods:
    severity: warning
    max: 40
  style/css-declaration-lines: warning
  accessibility/control-name: warning
  accessibility/keyboard-activation: warning
  templates/unstable-key: off
  migration/css-timer: off
  money/float-to-minor-units: off
```

A generated project uses this policy and additionally enables the opt-in
line-length rule:

```yaml
rules:
  metrics/line-length:
    severity: warning
    max: 120
```

The CSS declaration rule is already on in the standard policy.

The strict schema is:

- The file must contain exactly one YAML document and a top-level mapping.
- `version` is required, must be the plain integer `1`, and no other version is
  accepted.
- `include` and `exclude` are optional sequences of nonempty relative glob
  strings. Absolute paths and `..` escapes are rejected. The default include
  list is `["lib/**/*.rb"]`; the default exclude list is empty.
- `rules` is an optional mapping from rule ID to a severity string or to a
  mapping with a required `severity` plus that rule's documented options.
- Severities are exactly `error`, `warning`, and `off`.
- Rule-specific options must be positive integers. Unknown options are errors.
- Duplicate keys, unknown top-level keys, unknown rule IDs, malformed globs,
  and invalid value types are errors.
- `ruby/syntax`, `analysis/limitation`, and `lint/suppression` are always
  errors. They cannot be configured or suppressed.

## Source discovery

Ruby files are selected below the intersection of the project and config
roots. Discovery is deterministic and skips:

- `.git`, `node_modules`, `vendor`, `build`, `dist`, and `coverage`
- `public`, which is an asset directory rather than Ruby source
- directory and file symlinks
- files outside the project or config boundary after realpath resolution

An invocation that selects no Ruby files exits 2 with an actionable message
instead of passing silently.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | No unsuppressed diagnostics, or help was requested |
| `1` | At least one unsuppressed warning or error |
| `2` | Invocation, configuration, I/O, internal, or empty-selection failure |

Warnings and errors are both blocking. There is no severity bypass and no
option that turns a nonzero result into success. Fatal failures write to
stderr. They do not emit a partial diagnostics document on stdout.

## Output formats

Text output is one line per diagnostic:

```text
lib/Panel.rb:12:3: error correctness/unknown-handler: template handler 'open_panel' is not defined on 'Panel'
lib/Panel.rb:20:1: warning metrics/method-length: method 'render' has 64 body lines; maximum is 60
```

JSON output is a single object with no banner:

```json
{
  "schema_version": 1,
  "diagnostics": [
    {
      "path": "lib/Panel.rb",
      "line": 12,
      "column": 3,
      "end_line": 12,
      "end_column": 13,
      "start_byte": 214,
      "end_byte": 224,
      "severity": "error",
      "rule": "correctness/unknown-handler",
      "message": "template handler 'open_panel' is not defined on 'Panel'",
      "suggestion": "define 'open_panel' on 'Panel' or correct the handler name"
    }
  ]
}
```

Paths are project-relative. Lines and columns are one-based, columns count
Unicode characters, and byte offsets refer to the original source file. The
`suggestion` field is present only when the rule supplies one.

Diagnostics are sorted by project-relative path, start byte, rule ID, message,
end byte, severity, suggestion, and a stable input-position tie-breaker. The
same source produces the same relative diagnostics and order when the project
is moved to a different checkout root.

## Rules

| Rule | Default | Options | Checks |
| --- | --- | --- | --- |
| `ruby/syntax` | `error` | none, always on | Tree-sitter syntax and recovery errors |
| `analysis/limitation` | `error` | none, always on | Source lint cannot analyze exactly |
| `lint/suppression` | `error` | none, always on | Suppression directives are valid, narrow, and still used |
| `correctness/unknown-handler` | `error` | none | Template event handlers resolve to component methods |
| `correctness/timer-callback` | `error` | none | Literal `Mochi.after` and `Mochi.every` callbacks use valid methods and delays |
| `correctness/child-props` | `error` | none | Child component attributes match declared prop contracts |
| `correctness/event-payload` | `error` | none | Declared child event payloads and `on:` connections match schemas |
| `components/prop-write` | `warning` | none | Declared props remain read-only input snapshots |
| `metrics/method-length` | `warning` | `max: 60` | Ruby method bodies stay within the configured line limit |
| `metrics/line-length` | `off` | `max: 120` | Ruby method lines stay within the configured character width |
| `style/css-declaration-lines` | `warning` | none | Component CSS keeps one declaration per line |
| `metrics/nesting-depth` | `warning` | `max: 4` | Ruby method logic stays within the configured nesting limit |
| `metrics/component-methods` | `warning` | `max: 40` | Components stay within the configured authored method limit |
| `accessibility/control-name` | `warning` | none | Interactive controls have an accessible name |
| `accessibility/keyboard-activation` | `warning` | none | Custom button roles provide local keyboard activation |
| `templates/unstable-key` | `off` | none | Lists use stable row identity when reordering is visible |
| `migration/css-timer` | `off` | none | Hidden CSS animation timer loops migrate to Mochi timers |
| `money/float-to-minor-units` | `off` | none | Currency display uses exact minor-unit arithmetic |

### Syntax and analysis

`ruby/syntax` reports at most one source-located syntax diagnostic per file.
Independent files remain inspectable without a cascade of diagnostics.

`analysis/limitation` reports source or template text that lint cannot analyze
exactly. This includes source-mapping failures and component contract errors
such as an `html` method that does not return one literal template string, a
component that declares more than one `@tag_name`, a duplicate component tag,
and a prop or event declaration that cannot be extracted. A selected source
that cannot be analyzed is a visible blocking diagnostic, never a silently
skipped file.

Both rules are always errors and cannot be suppressed.

### Correctness

`correctness/unknown-handler` examines event attributes in target component
templates. A single-placeholder attribute whose expression is a bare method
name or `self.method` is resolved against the component's instance methods,
declared props, attribute readers, and known ancestors. The rule reports only
when that inventory is closed. Dynamic receivers, row-local names, event
argument placeholders, and unresolved ancestors or open classes remain
unknown.

`correctness/timer-callback` examines `Mochi.after` and `Mochi.every` calls in
selected instance methods. A literal String or Symbol callback must be
nonempty, must resolve to a component method or a method on a known ancestor,
and must not require positional arguments. A literal delay must be an Integer
from 0 through 2,147,483,647 milliseconds. Literal non-name callbacks and
literal non-Integer delays are errors. Dynamic callbacks and dynamic delays
remain unknown. A call with fewer than two literal arguments or with extra
arguments is not diagnosed; the rule evaluates one callback name and one delay
when both are present.

`correctness/child-props` checks known child component tags that declare props.
A required prop is reported missing only when the element has no dynamic
attribute or attribute-hash escape. Literal attribute text is checked against
the declaration: String accepts any text, Boolean accepts `true`, `false`, or
an empty attribute, Integer must fit the signed 64-bit range, Float accepts
decimal text plus `Infinity`, `-Infinity`, and `NaN`, and Array or Hash must be
JSON text of the declared container. Collection numbers must be finite and
inside JavaScript's exact integer range. Bindings and template expressions
remain unknown.

`correctness/event-payload` checks literal `emit` and `self.emit` calls in
components with declared events. The event name must be declared, every
declared payload field must be present unless a dynamic key or hash splat could
supply it, unknown fields are errors, literal values must match the declared
type, and Integer values must fit the signed 64-bit range. A Symbol literal
satisfies a String field because payload Symbols travel as JSON strings. The
rule also checks `on:<event>` connections to known child tags with declared
events. Dynamic event names and payloads remain unknown.

`components/prop-write` reports direct writes to a declared prop in an
instance method: assignment to `@prop`, an indexed target rooted at `@prop`,
`<<`, or a recognized collection or string mutator. It also reports
`bind:value` and `bind:checked` that target a declared prop. Aliases,
arbitrary mutation helpers, unrecognized bang methods, and other dynamic
targets are not chased.

### Complexity metrics

`metrics/method-length` counts the physical lines between a method header and
its matching `end`. The matching `end` line is excluded. The opening line of a
multiline literal is counted once; interior and closing literal lines are not
counted. Embedded HTML, CSS, and data therefore do not inflate Ruby logic. A
single-line method with a body counts as one. Instance and singleton methods in
selected source are inspected. A method is reported when that count is greater
than `max`.

`metrics/line-length` is an opt-in style rule, off by default. When enabled, it
checks every line of selected methods, including their signatures, comments, and
embedded template or data text. A line is reported when its Unicode character
count is greater than `max`; tabs count as one character and line endings are
excluded. The diagnostic covers the overlong line. Enable it in a project
policy with `severity: warning` and the desired `max`; the generated starter
project enables `max: 120`. A method directive suppresses every line-length
report inside that method.

`style/css-declaration-lines` is a style rule that reads the literal returned
by a component's `css` method and reports a line with more than one declaration.
It is on by default; set it to `off` when packed CSS is intentional. One
declaration on a line is allowed, including a complete single-declaration rule
such as `:host { display: block; }`. Semicolons inside strings, comments,
`url(...)`, brackets, and Ruby interpolation do not count. Top-level `@import`
statements do not count as declarations, and a final declaration without a
trailing semicolon is counted when its block closes. The rule does not run when
`css` returns computed text instead of one literal string. Reports cover the
packed source line; put each declaration on its own line to resolve them.

`metrics/nesting-depth` starts at depth 0 inside a method body and adds one for
each `if`, `unless`, `case`, `case_match`, `while`, `until`, `for`, `rescue`,
`rescue_modifier`, `if_modifier`, `unless_modifier`, `while_modifier`,
`until_modifier`, `conditional`, `block`, or `do_block`. `elsif` and `when` are
sibling arms, not additional levels. The rule reports the first node whose
depth is greater than `max`. Literal contents are not treated as Ruby
structure.

`metrics/component-methods` counts distinct authored instance method names on
a component class, which is a class that declares `@tag_name`. Reopened
declarations share one class model. Attribute readers, prop and event
declarations, nested classes, inherited methods, and singleton helpers do not
count. The rule reports once at the declaration that supplies the component
tag name, or the first declaration when no declaration supplies one, when the
count is greater than `max`. Methods declared in a supporting file reached by
`require` or `require_relative` still contribute to the component total; only
the report location is limited to selected target files.

### Accessibility

`accessibility/control-name` checks visible `<button>`, `<a href>`, and
elements whose `role` contains the `button` token. A control is named by
visible authored text, a named child, `aria-label`, a resolvable
`aria-labelledby` target, an image `alt`, or an SVG `<title>`. Hidden, inert,
and `aria-hidden` subtrees are skipped. Dynamic attributes or content,
custom elements, unresolved ARIA references, and native form controls other
than `button` remain unknown or out of scope.

`accessibility/keyboard-activation` checks visible non-native elements with a
`button` role token. A local `onclick` handler must be paired with `onkeydown`
or `onkeyup` on the same element. Native interactive elements are skipped, as
are hidden subtrees and elements with dynamic attributes.

### Opt-in advice

`templates/unstable-key` is off by default. It reports an explicit `key:`
expression that resolves to a loop index binding, or a direct reordering
operation on literal rows that provably lack `key` or `id` fields. An explicit
non-index key silences the literal-reorder pattern. Unknown collections and
computed row shapes remain safe.

`migration/css-timer` is off by default. It reports a hidden driver element
whose native `onanimationend` or `onanimationiteration` callback restarts
state used by that driver and also performs another local state mutation or a
known nonvisual API call. Use of `Mochi.after` or `Mochi.every`, visible
drivers, opaque helper calls, and CSS imported from shared fragments are not
reported. The finding is a review prompt, not proof that the loop is
incorrect.

`money/float-to-minor-units` is off by default. It reports a direct
`MochiFormat.currency` call whose first argument is a multiplication followed
by a zero-precision `round` and/or `to_i`. It does not infer money from names,
inspect other Float arithmetic, or prove the total is wrong. Exact
`MochiMoney` ledgers and unrelated rounding pass. The finding is a review
prompt to accumulate exact minor units and round once at display.

Opt in with the same strict configuration schema. Any enabled warning is still
blocking:

```yaml mochi-lint-advice
version: 1
include:
  - "lib/**/*.rb"
rules:
  templates/unstable-key: warning
  migration/css-timer: warning
  money/float-to-minor-units: warning
```

## Generic contract examples

Typed child props and keyed rows keep names and identity explicit:

```ruby mochi-lint-example
class ChildBadge
  @tag_name = "child-badge"
  prop :label, String, required: true
  prop :count, Integer, default: 0

  def html
    %Q{<span>{@label}</span><span>{@count}</span>}
  end
end

class ParentPanel
  @tag_name = "parent-panel"
  @badges

  def initialize
    @badges = [{"id" => "a", "label" => "Alpha", "count" => 2}]
  end

  def html
    %Q{
      {each @badges as badge, key: badge["id"]}
        <child-badge label="{badge["label"]}" count="{badge["count"]}"></child-badge>
      {end}
    }
  end
end
```

A custom button role needs a local keyboard path:

```ruby mochi-lint-example
class MenuButton
  @tag_name = "menu-button"

  def html
    %Q{<div role="button" tabindex="0" onclick="{open}" onkeydown="{key}">Menu</div>}
  end

  def open
    # open the menu
  end

  def key(event)
    open if event[:key] == "Enter" || event[:key] == " "
  end
end
```

Accumulate exact minor units and round once at display:

```ruby mochi-lint-example
cost = MochiMoney.ledger
MochiMoney.add_ratio(cost, 202_000 * 300, 1_000_000)
cents = MochiMoney.round_half_up(cost)
MochiFormat.currency(cents, "USD", "en-US", 2)
```

## Suppressions

A suppression names one rule and gives a nonempty reason. Ruby uses a comment:

```ruby
# mochi-lint: disable-next metrics/method-length -- generated lookup table keeps this method together
def lookup_table
  # ...
end
```

Template literals use an HTML comment in the authored template text:

```html
<!-- mochi-lint: disable-next accessibility/control-name -- the surrounding group supplies the visible label -->
<!-- mochi-lint: disable-next accessibility/keyboard-activation -- this fixture isolates pointer behavior -->
<div role="button" onclick="{toggle}"></div>
```

`disable-next` targets the next eligible Ruby construct at the same or a
nested scope, or the next template element or `{each}`, `{if}`, or `{unless}`
block at the same or a nested scope. Eligible Ruby targets are a fixed set of
syntax nodes such as methods, classes, calls, assignments, and control-flow
nodes; parameter lists and wrapper nodes are not targets. A directive
suppresses a diagnostic only when the diagnostic is in the same file and its
entire source range lies inside that target. Comments inside template
placeholders or Ruby strings are not directives. A template suppression
comment is ordinary authored HTML comment text; lint does not strip it from
the built template.

Only `disable-next` exists. The following are `lint/suppression` errors at the
directive location:

- malformed directives or a missing `-- reason`
- a missing, multiple, comma-separated, or whitespace-separated rule name
- the wildcard forms `*`, `all`, `all-rules`, or any rule name containing `*`
- file-wide `disable` directives
- unknown rule IDs
- the always-on rules `ruby/syntax`, `analysis/limitation`, and
  `lint/suppression`
- a directive with no following target
- an unused or stale directive, including one for a rule that is off
- duplicate directives for the same rule and target
- overlapping directives for the same rule

Suppression diagnostics are always errors and cannot themselves be
suppressed.

## Static-analysis boundary

Lint reports only what the checked-in source proves. It does not execute
application Ruby, compile a bundle, start the VM or a browser, invoke Node.js,
or inspect runtime state. Dynamic values, unresolved method inventories,
unknown receivers, computed row shapes, and external ancestors are not treated
as proof of a defect. A syntax or source-mapping limitation in a selected source
is reported as a blocking analysis diagnostic instead of silently excluding the
file. Files outside the selected set can contribute class and method inventory
for cross-file checks, but their own diagnostics and templates are not reported.

The implementation keeps one Tree-sitter AST per source for the run, reuses
template views and the project index across rule passes, indexes line starts
once, and bounds each rule to its relevant indexed syntax. It does not spawn a
subprocess or build pipeline per file and does not maintain a persistent cache.

## Adoption policy

Adopt the strict policy directly. There is no baseline, grandfathering,
automatic fix, formatter, editor integration, or shadow rollout. Intentional
negative fixtures belong in tests that assert their expected diagnostics; they
are not excluded with a baseline. A real exception uses a narrow
`disable-next` directive with the contract it demonstrates stated in the
reason.
