# Fixed VM capacities

Mochi compiles VM arenas into the GVM artifact. A manifest limit cannot resize
those inline arrays. The selected profile therefore builds a matching runtime
before the Ruby bundle is emitted.

Start from [`capacity.example.json`](capacity.example.json), edit only the
limits your application needs, then pass the file to the compiler:

```sh
mochi -i ./app -o ./dist --capacity-config ./mochi-capacities.json
```

The versioned `capacities` object sets tick scratch bytes, objects, ivars, and
slots; persistent state classes, objects, ivars, slots, bytes, and component
registrations; promotion depth; reactive bindings; ABI bytecode bytes and call
arguments; per-object ivars; Goose stack reservation and region count; the
fixed Goose guard size; WebAssembly stack size; and total WebAssembly memory.
It also sets host fetch, emit, event, drag, formatting-cache, and file
handle/reader/chunk/whole-read limits. Only the subset used by a declared host
capability is copied into that capability's manifest entry and passed to its
adapter. Adapters cannot select a larger limit at runtime.
The current Goose binary has 47 stack regions and a fixed 1 MiB guard per
region; the compiler rejects attempts to change those implementation bounds.
Fields omitted from a version 1 file use the defaults in
the example. Unknown fields, non-positive values, integer overflow, and
incompatible combinations fail before output cleanup or compilation.

Several limits follow the current value representation: state object handles
have a 15-bit index (maximum 32768), the ABI accepts at most 8 call arguments,
and the fixed ivar dirty mask tracks 256 ivars per object. Persistent object,
ivar, slot, and byte pools must also leave room for the collector's reserved
headroom. The compiler estimates inline arenas, bytecode, bridge buffers, and
stack storage and rejects a `memory_bytes` value below that minimum.

GVM artifacts have a hard WebAssembly linear-memory maximum of
`memory_bytes`. Linear memory can grow up to that limit for runtime and bytecode
allocations, but the configured Goose arenas never expand. These limits bound
the memory an application may reach; increasing them can raise its possible
memory footprint even when it does not use the full arena. Host buffer sizes
that are part of the WASM bridge also count toward the minimum-memory check.
Relationships between fetch envelope size, JSON escaping, file base64
expansion, concurrent readers, and reserved host buffers are validated before
building the runtime.

The compiler normalizes the configuration and hashes the normalized values.
Custom artifacts are built in an isolated copy of the GVM source, then cached
by capacity fingerprint, runtime source identity, and toolchain versions. Two
profiles produce separate WebAssembly and JavaScript artifacts. A default
build uses the installed default artifact without rebuilding GVM. The bundle
manifest records the profile and its fingerprint; the loader reads the
fingerprint and limits embedded in the instantiated artifact and rejects a
mismatch before runtime initialization.

The configured capacities are hard bounds. Pools do not expand adaptively.
Ruby-facing exhaustion diagnostics and recovery behavior are described with
the capacity failure contract in the runtime documentation.
