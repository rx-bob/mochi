# Optional owned keyboard shortcuts

`MochiShortcuts` is an optional Ruby package and browser adapter. Referencing
it from a reachable component/helper adds its capability dependency. The host
module loads when a consuming component mounts; unrelated applications omit
both package and adapter. No application JavaScript or document handle is needed.

```ruby
def mounted
  @undo_shortcut = MochiShortcuts.register("z", "on_undo",
    {"ctrl" => true, "prevent" => true})
end

def on_undo(result)
  if result["ok"]
    undo_change
  else
    @error = result["error"]
  end
end

def stop_shortcut
  MochiShortcuts.cancel(@undo_shortcut)
end
```

`register(key, callback, options = {})` returns an Integer cleanup token
immediately. Successful registration does **not** invoke the callback.
Matched keys deliver the usual `ok/value/error` envelope. Its `value` contains
`token`, `key`, `code`, `ctrl_key`, `alt_key`, `meta_key`, `shift_key`, and
`repeat`. Registration errors use `ok: false`, `value: nil`, and an error string;
callbacks must check `ok` before performing their action.

`cancel(token)` needs no callback. It affects only the requesting component's
current mount, and is harmless for an already canceled or foreign token.
Malformed tokens report an error. Unmount cancels all owned registrations;
tokens cannot reach a newer mount even if a VM instance number is reused.

## Options and matching

| Option | Default | Meaning |
| --- | --- | --- |
| `scope` | `"component"` | `"component"` or `"application"` |
| `active_ref` | absent | Activate while this named static ref exists; restrict component scope to its region |
| `ctrl`, `alt`, `meta`, `shift` | `false` | Exact modifier requirements |
| `prevent` | `false` | Prevent browser default for a winning match |
| `allow_editable` | `false` | Permit matches in editable controls |
| `repeat` | `false` | Permit repeated keydown events |

Options other than `scope` and `active_ref` must be Booleans. `active_ref` must be a nonempty String. Unknown options, empty keys,
missing callbacks, invalid scopes, and capacity exhaustion fail explicitly.
Letter keys are case-normalized, so `"z"` with `shift: true` matches native
`"Z"`. Named keys such as `"Escape"` match their browser key name exactly.
There is no platform-dependent modifier alias: register Ctrl and Meta
separately when both are intended. Extra pressed modifiers reject a match.

Input, textarea, select, and contenteditable paths are ignored by default.
Detection follows the composed event path through open shadow components;
an explicit `contenteditable="false"` island stops inherited editability.
Composition (`isComposing` or legacy key code 229) is always ignored, including
when editable controls or repeats are allowed. Already default-prevented events
are left alone. An application scope may opt Escape into editable controls.

## Active scopes and precedence

- A component registration is eligible when the key event's composed path
  includes its mounted owner. Nested component owners take precedence over
  ancestors. Within the same scope/owner, the latest matching registration wins.
- Registering an application shortcut activates its owner's application scope.
  The most recently activated live application owner takes precedence and
  suppresses all other owners' shortcuts, including keys it does not match.
  Canceling its last application registration exposes the previous owner.
- Within an active application owner, its application registrations take
  precedence over its component registrations. Ties use registration order.
- Exactly one eligible registration runs. Default prevention happens
  synchronously in the capture listener, only for that live winning match
  when `prevent` is true. An unmatched key retains browser defaults; suppressing
  lower shortcut scopes does not itself prevent the key.

Without `active_ref`, registration activates immediately. With it, a missing or
disconnected ref deactivates the registration without canceling its token.
Reappearance or replacement reactivates it with a new precedence order. This
follows DOM presence, not CSS visibility: hiding an element with styles does
not deactivate it. Component scopes additionally require the event path to
include the active ref. Ref lookup is confined to the owning mount; row-local
refs remain deferred.

The form registers once with `"active_ref" => "dialog"`. Local and prop-driven
conditional branches therefore activate/deactivate its shortcut layer without
waiting for another component to mount. Reconciliation observes branch changes;
keydown also rechecks refs before choosing a winner. This closes the window
between a branch change and observer delivery.

One document keydown listener serves owned registrations and is removed when
none remain. Active and inactive registration count is bounded by the existing capacity profile's
`bindings` limit (`shortcuts.limits.registrations`, default 2,048). Failed
registrations retain no slot. No new VM arena, capacity default, or telemetry
surface is introduced.

## Fixture behavior and evidence

Graph Ctrl/Meta+Z undo and Ctrl/Meta+Shift+Z redo operate while focus is within
the graph, including its focusable viewport. Its note input retains ordinary
editing behavior. An open form's application scope suppresses graph actions;
Escape cancels from nested editor inputs. User-opened dialogs focus a named
focus-trapped region and use `Mochi.restore_focus` on Escape/cancel. An initially
open form has no captured opener and falls back to its toggle button.

Ruby scenarios use existing `focus`, `press`, and `assert_focused` operations.
Browser checks cover overlapping scopes, prop-driven open/close, native default
handling, repeated reuse of the same custom element, package omission, and lazy
single adapter loading. Adapter tests cover modifiers, composition, editability,
repeats, precedence, explicit cancellation, stale mounts, listener disposal,
capacity rejection, and subsequent recovery.
