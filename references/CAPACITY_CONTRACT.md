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
and ABI bytecode. A limit is a hard boundary: Mochi reports the rejected
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

The standalone row-capacity browser fixture asserts that 540 ordinary rows of
hashes render under both the default profile and a deliberately reduced
`scratch_objects: 512` profile. It separately asserts that an oversized mount
reports the actual constrained object limit and that a valid component can
mount and update afterward. The 540-row workload is expected to work under
both profiles; the deliberately oversized workload is expected to fail at the
named bound.
