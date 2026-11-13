# Capacity failures and recovery

Mochi compiles fixed VM capacities into the runtime. The bundle manifest and
runtime artifact carry the same capacity profile fingerprint; the loader rejects
an artifact mismatch before it starts the VM. See [fixed capacities](../docs/fixed-capacities.md)
for configuration and the complete default profile.

The build profile also contains host bounds for bridge envelopes, fetches,
formatting cache entries, events, drag payloads, and file handles/readers.
Manifest metadata copies only the limits required by each declared capability.
The loader freezes that limit map and passes it to adapter operations; adapters
must reject missing limits instead of silently falling back to a larger
runtime default. Configuration validation checks JSON/base64 expansion and
concurrent reservations before a capability can be built.
Bootstrap also checks declared adapters against that exact profile, rejects
missing/unknown limits and unsupported table sizes, and verifies network JSON
expansion plus concurrent response reservations before loading adapter code.
The installed limit map is an immutable copy, including when multiple mounts
share one adapter load. File/drag relationships remain compiler validation;
their optional implementations own their eventual readers and event state.

Global Ruby event delivery uses `host_event_queue_entries` as both its queued
recipient limit and per-chain delivery limit for one synchronous drain.
`host_event_queue_bytes` bounds the encoded payload cost retained by queued
recipients. The loader snapshots subscribers on publication and rechecks each
registration and mount generation before calling Ruby. Unsubscribe and disposal
remove that subscriber's pending deliveries. On exhaustion, Mochi clears the
offending chain's queued work, reports one source-located event error, and
continues with independent queued publications.

Native handler arguments, including `dataset`, `target_dataset`, and
`current_target_dataset`, share the existing `host_event_args_bytes` limit
(default **8,192 bytes** for the encoded UTF-8 JSON argument envelope). The
legacy and explicit target maps serialize separately, so both copies count;
row context and any other arguments count too. Composed-path entries remain
small labels, with no dataset copied onto each path entry.

An oversized target or handler dataset is rejected before the Ruby handler
runs with `ABI event argument bytes exhausted`, requested/used/limit counts,
the authored handler location, and the capacity profile fingerprint. Nothing
is truncated and no limit is raised automatically. A subsequent valid click
runs normally. The report-08 Ruby/browser probe covers both target-only and
current-target-only overflow under the default profile.

## Failure report

The VM keeps the first capacity rejection from an entry. It reports the
resource, requested amount, used amount, configured capacity, and the Ruby
class/method (or binding) that was running. The loader maps that method or
binding to the authored Ruby file and line and includes the compiled profile
fingerprint. The existing `mochi:error` event, element error, and `onError`
hook carry the report.

Scratch and persistent-state failures use the same count format. Named
resources include scratch objects/bytes/ivars/slots, state bytes/objects/ivars/
slots, ivars per object, component registrations, reactive bindings, classes,
ABI bytecode, host command bytes, and ABI patch/emit/fetch/evaluation buffers.
A limit is a hard boundary: Mochi reports the rejected
operation instead of growing the arena, trapping, truncating a successful
result, or retrying with a different resource.

## Lifetime and recovery

Each VM entry starts and ends with empty registers, frames, entry arguments,
scratch roots, and tick scratch. Persistent component state, class and method
definitions remain available. Scratch reclamation within long entries remains
active; the entry reset is not a replacement for reclamation. Disposing an
instance releases its component root and bindings so those capacities can be
reused. A mount that fails while initializing is disposed with its partial
registrations removed.

A rejected operation does not publish a successful binding patch or deliver
host commands left in the failed entry's outboxes. The loader clears those
outboxes on failure. Mochi does not roll back arbitrary Ruby statements that
already changed persistent state before the rejected operation; applications
should treat the reported operation as failed and decide how to repair that
state.

The standalone row-capacity browser fixture renders 540 ordinary rows of hashes
under the default profile. With `scratch_objects: 512`, its live row projection
exceeds the object limit and reports that resource at the authored template.
Doubling `scratch_bytes` from 131,072 to 262,144 leaves the same object failure;
changing an unrelated resource does not fix it. After removing the rejected
mount, a smaller component mounts and updates normally. This records the current
compiled workload rather than assuming the historical 540-row report must fail.

Earlier prose claimed the 512-object fixture succeeded. Exhausted JSON string
allocations could previously become nil without marking the parse as failed,
and binding serialization could lose its first error. Those paths now reject
instead of silently accepting incomplete values.

`gvm_capacity_boundaries.spec.ts` uses independent Ruby workloads with 128 scratch
objects, 8,192 scratch bytes, 256 scratch slots, two component registrations,
four bindings, and 1,024-byte patch/emit buffers. It checks the actual resource
and profile, failed prop decoding, partial mount cleanup, preserved unrelated
components, no partial DOM patch, discarded host requests, and subsequent valid
updates. Goose tests exercise scratch ivar exhaustion and recovery as well as
the other scratch pools. Component declarations beyond the fixed 256-ivar mask
are rejected by the compiler before execution.

Patch evaluation stops at the first rejected getter, clears the whole pending
patch batch and makes the component's bindings eligible for reevaluation. Later
getters cannot erase the original error. Failed fetch/capability callbacks and
unmounted hooks also discard their pending host commands. A full native emit or
fetch outbox raises a capacity error through the existing Ruby error channel;
it cannot silently return a successful operation with a truncated batch.

The Goose host-command accumulator uses the selected `host_emit_envelope_bytes`
limit, reserving one byte for the bridge terminator. It stops the entry on the
first overflowing command. This does not roll back prior Ruby or VM-side storage
mutations, and it does not add automatic retries. Linear-memory limits remain
build-selected. Rejected bytecode appends preserve the previously loaded program.

The standalone WASM build reads profile metadata from the current generated
header when writing its companion JSON. Metadata is no longer compiled into the
build tool's cached native sidecar, which could otherwise reuse an older profile
while emcc built the new one.

## E5.S2 validation — 2026-11-13

The focused browser suites pass all 42 checks across Chromium, Firefox, and
WebKit. They compile Ruby fixtures against the real VM, including independent
object, byte, slot, component, binding, patch, emit, fetch and host-command
failures. Every rejected workload is followed by valid work, with rejected host
requests absent from the network and storage. The 540-row default and both
512-object profiles have the outcomes described above.

The VM suite passes 184 tests (17,951 assertions), including scratch ivar and
state reclamation, numerical overflow diagnostics, rejected bytecode loading,
failed JSON/prop decoding and atomic rejection of a multi-binding patch batch.
The runtime suite passes 145 tests; the capacity compiler specs pass three
examples. All 29 source/test mirrors match. New modules and entry-lifecycle
changes pass goosefmt. Existing file/function-size lint violations remain in
`abi.goose`, `json_args.goose` and `signals.goose`.

The existing standalone compile-time gate passes all 15 minimal-app cold, warm
and edited builds below one second. The broader app gate requires a Cowboy
checkout and was not used as story acceptance.

Payload membership/determinism checks reach the byte-ceiling gate, which remains
red: current core is 451,657 raw / 147,087 gzip bytes versus the recorded 416,678
raw ceiling. A control using the retained earlier VM build and committed loader
also exceeds that ceiling (450,579 raw / 146,798 gzip). The standalone WASM
change is 191,441 → 192,505 raw bytes and 87,092 → 87,363 gzip bytes; its JS glue
remains 63,170 raw / 17,609 gzip. The extra VM bytes enforce named capacity
rejection, preserve the first failure and prevent partial output. No payload
budget was increased to hide the existing full-checkout gap.

## E5.S3 validation — 2026-11-13

All 148 runtime tests pass, including missing/invalid bootstrap limits,
immutable lowered limits shared by concurrent mounts, missing registration,
and adapter retry. Four capacity compiler examples cover serialized metadata,
JSON/base64 expansion and concurrent file/network reservations; 11 package
graph examples cover optional membership and checkout-independent identities.

The independent Ruby browser fixture passes Chromium, Firefox and WebKit.
Before a capability component mounts, neither its adapter nor its Ruby package
is requested. Concurrent formatting/network mounts each request their adapter
and bytecode once, and the network callbacks return the expected result.

The payload audit now validates all three fixtures with shared integrity and
explicit membership expectations, tests rejection of accidental eager loading,
and gates network bytes as well as minimal/formatting bytes. Repeated builds
remain byte-identical across temporary roots. The earlier E5.S2 ceiling failure
is resolved by the measured, explained budget refresh in
[PAYLOAD_BUDGETS.md](PAYLOAD_BUDGETS.md); raw ceilings remain exact and gzip
tolerance is unchanged.
