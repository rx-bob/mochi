# Ruby task guide

Use Ruby APIs below for common browser work. Every example points to its full
checked-in Ruby source, supported contract, and behavioral regression. No
application JavaScript or manual capability script tags are needed.

## Set up the development command

From a Mochi checkout, run `task install:dev`. The installer prints the `PATH`
entry to add; it does not edit shell startup files. See the
[install and resource lookup reference](../AGENTS.md#installing-the-development-command)
for custom prefixes, update/removal, and runtime resource discovery.

## Schedule work

Use `Mochi.after(milliseconds, :callback)`, `Mochi.every(milliseconds,
:callback)`, and `Mochi.cancel_timer(handle)`. Start and stop explicitly, and
cancel from `unmounted` when the component owns a repeating poll. Timer callbacks
are zero-argument methods on that mounted component.

- Fixture: [TimerRoot.rb](../e2e/fixtures/feedback_review/lib/TimerRoot.rb).
- Contract: [mount-owned timers](TIMER_CONTRACT.md).
- Regression: [`gvm_feedback_review.spec.ts`](../e2e/tests/gvm_feedback_review.spec.ts), timer scheduling, cancellation, failed mount, and disposal cases; run `task framework:feedback`.
- Limits: delays are milliseconds; zero is asynchronous and not a cadence promise. Background tabs may throttle timers. There is no calendar scheduler.

## Persist a preference or draft

Read `MochiStore.value(store)` during `initialize`, then register
`Mochi.storage_subscribe(key, "on_change")`. Write with
`MochiStore.write(store, text)` and apply each callback with
`MochiStore.accept(store, payload)`. The write result means the command was
queued; the subscription payload confirms success or reports the retained value
and `quota`/`unavailable` error.

- Fixture: [StorageRoot.rb](../e2e/fixtures/feedback_review/lib/StorageRoot.rb).
- Contract: [storage and subscriptions](RUBY_SURFACE.md#storage-and-subscriptions), also summarized in [AGENTS.md](../AGENTS.md#storage-and-subscriptions).
- Regression: [`gvm_feedback_review.spec.ts`](../e2e/tests/gvm_feedback_review.spec.ts), reload, malformed text, quota/unavailable, external changes, and unmount cases; run `task framework:feedback`.
- Limits: storage values are Strings. Use `JSON.generate`/`JSON.parse` with an explicit format and shape check for small structured preferences. The active `host_emit_envelope_bytes` profile limit bounds each command; do not treat storage as document persistence. A CSS-hidden mounted screen remains subscribed.

## Download data

Call `MochiDownload.save(filename, content_type, string_or_parts)` directly from
a user action. It hands one bounded Blob to the browser; `true` does not mean a
file reached disk.

- Fixture: [InspectorRoot.rb](../e2e/fixtures/ui_contracts/lib/InspectorRoot.rb) and [download_test.rb](../e2e/fixtures/ui_contracts/test/download_test.rb).
- Contract: [bounded Ruby downloads](DOWNLOAD_CONTRACT.md).
- Regression: [`gvm_ui_contracts.spec.ts`](../e2e/tests/gvm_ui_contracts.spec.ts), actual bytes, optional package loading, and disposal lease; run `task framework:ui:inspector`.
- Limits: one String or up to 1,024 String parts, bounded by the active `host_file_buffer_bytes` profile. Streaming output and file-system writes are unsupported.

## Bind multiple child events

Declare each typed event in the child, for example
`event :action, value: String` and `event :change, value: String`. Bind both on
the same child with braced Ruby handlers such as
`on:action="{receive($event)}" on:change="{receive($event)}"`.

- Fixtures: [ReviewChild.rb](../e2e/fixtures/feedback_review/lib/ReviewChild.rb) and [ReviewRoot.rb](../e2e/fixtures/feedback_review/lib/ReviewRoot.rb).
- Contract: [typed props, child events, and controls](RUBY_SURFACE.md#boolean-props-child-events-and-form-controls) and [event migration notes](API_MIGRATIONS.md#global-events).
- Regression: [`gvm_feedback_review.spec.ts`](../e2e/tests/gvm_feedback_review.spec.ts), nested typed children retain both event connections across updates and remounts; run `task framework:feedback`.
- Limits: event payloads must match the child declaration. Unbraced or mixed-literal child event handlers fail compilation.

## Read nested row data from events

For identity on the element carrying a handler, read
`event["current_target_dataset"]["node"]`. Target data is separate:
`event["target_dataset"]` describes the clicked element and does not search its
ancestors. Nested `each` rows can pass group and field values through typed
child props or their own event payloads.

- Fixtures: [InspectorRoot.rb](../e2e/fixtures/ui_contracts/lib/InspectorRoot.rb), [NestedFormRoot.rb](../e2e/fixtures/ui_contracts/lib/NestedFormRoot.rb), and [EditableGraphRoot.rb](../e2e/fixtures/ui_contracts/lib/EditableGraphRoot.rb).
- Contract: [native event identity](RUBY_SURFACE.md#native-event-identity).
- Regression: [nested form Ruby scenarios](../e2e/fixtures/ui_contracts/test/nested_form_test.rb) and [`gvm_ui_contracts.spec.ts`](../e2e/tests/gvm_ui_contracts.spec.ts), nested keyed editor data and target/handler dataset identity; run `task framework:ui`.
- Limits: dataset values are Strings. Event snapshots are bounded by the active event-envelope capacity; no nearest-ancestor dataset lookup occurs.

## Register scoped shortcuts

Register from `mounted` with
`MochiShortcuts.register(key, callback, options)`, check `result["ok"]` in the
callback, and use `MochiShortcuts.cancel(token)` when the scope should end
before unmount. Use `scope: "application"` for modal Escape handling and
`active_ref` when a static ref controls eligibility.

- Fixtures: [EditableGraphRoot.rb](../e2e/fixtures/ui_contracts/lib/EditableGraphRoot.rb) and [NestedFormRoot.rb](../e2e/fixtures/ui_contracts/lib/NestedFormRoot.rb).
- Contract: [owned keyboard shortcuts](SHORTCUT_CONTRACT.md).
- Regression: [`gvm_ui_contracts.spec.ts`](../e2e/tests/gvm_ui_contracts.spec.ts), active form scope, graph precedence, editable inputs, conditional refs, remounts, and package omission; run `task framework:ui:graph` and `task framework:ui:form`.
- Limits: modifiers match exactly; Ctrl and Meta are separate. CSS hiding does not deactivate an `active_ref`. Unmount cancels the owner's registrations.

## Choose a screen lifetime

Use a conditional `{if @open}` branch when its children should be removed and
recreated. A conditional child loads its descriptor and bytecode on first mount;
the loader caches immutable resources, while each later mount gets fresh
instance state. Removal releases its mount-owned resources. Keep a screen mounted
and change its `display` style when it should retain local state. Hidden mounted
components keep timers, storage subscriptions, and shortcut registrations
active. Mochi does not add keep-alive or automatic state persistence.

- Fixtures: [NestedFormRoot.rb](../e2e/fixtures/ui_contracts/lib/NestedFormRoot.rb) demonstrates conditional editor removal/fresh drafts; [EditableGraphRoot.rb](../e2e/fixtures/ui_contracts/lib/EditableGraphRoot.rb) hides its viewport while preserving the mounted graph.
- Contracts: [component lifecycle](../AGENTS.md#component-lifecycle), [mount-owned timers](TIMER_CONTRACT.md), [storage subscriptions](RUBY_SURFACE.md#storage-and-subscriptions), and [shortcut scopes](SHORTCUT_CONTRACT.md#active-scopes-and-precedence).
- Regression: [nested form lifecycle scenarios](../e2e/fixtures/ui_contracts/test/nested_form_test.rb), [`gvm_ui_contracts.spec.ts`](../e2e/tests/gvm_ui_contracts.spec.ts), and [`gvm_feedback_review.spec.ts`](../e2e/tests/gvm_feedback_review.spec.ts); run `task framework:ui:form` and `task framework:ui:graph`.
- Limits: short DOM moves preserve a mount; settled removal disposes it; later reinsertion mounts fresh. Routes are opt-in through `AppRouter`; there is no implicit keep-alive.

## Verify examples

Build and typecheck the shared Ruby fixtures with:

```sh
task build
compiler/mochi --typecheck -i e2e/fixtures/ui_contracts -o /tmp/mochi-ui-typecheck
compiler/mochi --typecheck -i e2e/fixtures/feedback_review -o /tmp/mochi-feedback-typecheck
```

Run `task framework:feedback` for timer/storage/child-event examples and
`task framework:ui` for downloads, datasets, shortcuts, and screen lifetime.
These checks use Chromium, Firefox, and WebKit; no external service is needed.
