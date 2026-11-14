# Drag and file transfer

Mochi owns native drag events and keeps `DataTransfer` inside the browser event
listener. Ruby handlers receive ordinary values in the normalized `$event`
Hash. The `drag` adapter is optional and loads only for a reachable package
that uses `MochiDrag`.

## Typed values and text

Use `MochiDrag.set_data(value)` from `ondragstart` to transfer a Ruby value to
another Mochi component. Supported values are `String`, `Integer`, `Float`,
`Boolean`, `nil`, `Array`, and `Hash`, nested within the configured depth, item,
and byte limits. The typed transfer uses versioned MIME type
`application/vnd.mochi.value+json`; its representation is internal and must
not be constructed by application code.

Use `MochiDrag.set_text(text)` for plain text. A target calls
`MochiDrag.accept(type, effect)` from `ondragover`; supported effects are
`"copy"`, `"move"`, and `"link"`. Mochi prevents the browser default only when
the offered types include the accepted type. A Ruby `ondrop` handler receives
`drag_value`, `drag_text`, `drag_types`, `drag_effect`, and `drag_source` in
`$event`. Missing typed data is `nil`; missing plain text is an empty String.

```ruby
def start_drag(_event)
  MochiDrag.set_data({ "id" => @id, "active" => false })
end

def allow_drop(_event)
  MochiDrag.accept("application/vnd.mochi.value+json", "move")
end

def receive_drop(event)
  @selected = event["drag_value"]
end
```

Bind these methods to `ondragstart`, `ondragover`, and `ondrop`. The handler
must make `accept` calls during `ondragover` so Mochi can synchronously cancel
the browser default. Ruby receives no DOM objects, and Mochi never evaluates or
renders transferred text or data as HTML. External and forged typed payloads
are parsed as data, version checked, and bounded before Ruby delivery.

The default `host_drag_payload_bytes` limit is 1,024 bytes. Tune it in the
build capacity configuration when an application needs larger application
payloads. Depth and item counts have fixed upper bounds. Drag-free applications
do not load `mochi-drag.js`.

## Files

OS file drops and file-input selections use opaque, mount-owned handles. In a
Ruby drop or file-input change handler, `$event["files"]` is an Array of
metadata Hashes with `"handle"`, `"name"`, `"size"`, `"type"`, and
`"last_modified"` fields. A zero-byte file is valid. An empty or unknown MIME
type remains metadata and does not reject the file. File bytes and local paths
are never included.

```ruby
def files_selected(event)
  event["files"].each do |file|
    @label = "#{file["name"]} (#{file["size"]} bytes)"
    MochiFiles.release(file["handle"]) # when this application is done with it
  end
end
```

Use an ordinary `<input type="file" multiple onchange="{files_selected($event)}">`
as the accessible selection fallback. Bind `ondrop="{files_selected($event)}"`
to a drop target to receive dropped files; Mochi accepts file dragovers and
snapshots the native `File` references in the drop event. Ruby sees only the
metadata Hashes. `MochiFiles.release(handle)` explicitly releases one handle;
unmount and failed dispatch release mount-owned references automatically.
Handles from another component mount, a previous generation, or an already
released entry raise an actionable files error. Replacing a file selection
does not invalidate earlier handles; release them or let their component
unmount.

The full metadata batch is checked before handles are published. The default
`host_file_handles` capacity is 128 active handles, and serialized metadata is
bounded by `host_event_args_bytes`. If either limit is exceeded, the handler
gets one error and no handle from that batch remains registered.

### Bounded byte streaming

Open a reader for a file handle, then request one chunk at a time. A chunk is
an ordinary binary Ruby String. `bytesize` reports its byte count and
`getbyte(index)` returns a byte value from 0 through 255, including for NUL
and invalid UTF-8 data. Consume the current chunk before requesting another.

```ruby
def start_file(file)
  @reader = MochiFiles.open(file["handle"])
  @byte_count = 0
  @checksum = 0
  MochiFiles.read_next(@reader, :on_file_read)
end

def on_file_read(result)
  unless result["ok"]
    @file_error = result["error"]
    return
  end

  read = result["value"]
  if read["state"] == "chunk"
    bytes = read["bytes"]
    index = 0
    while index < bytes.bytesize
      @checksum = (@checksum * 31 + bytes.getbyte(index)) % 2147483647
      @byte_count += 1
      index += 1
    end
    MochiFiles.read_next(@reader, :on_file_read)
  else # "eof"
    @offset = read["offset"]
    MochiFiles.close(@reader)
  end
end
```

`read_next` returns a result Hash with `"ok"`, `"value"`, and `"error"`.
Successful values have `"state"` equal to `"chunk"` or `"eof"`; chunks also
include `"offset"`, `"next_offset"`, `"total"`, and binary `"bytes"`. Errors
set `"ok"` to false and include a message. `cancel` and `close` are idempotent;
closing during a read cancels it and suppresses its callback. EOF closes the
reader automatically, and read errors close the reader before delivering the
error result. Unmount and failed mount also close every reader and release its
File reference.

`host_file_readers` (default 4) and `host_file_chunk_bytes` (default 8,192)
bound concurrent readers and each requested range. The loader also checks the
serialized response against `host_fetch_envelope_bytes` before it enters the
VM inbox. Oversized files are streamed without allocating a whole-file Ruby
String. Applications must release file handles when they no longer need them.

For a small file, `MochiFiles.read(reader, callback)` returns the complete
binary String. It checks the file size against `host_file_whole_read_bytes`
(default 48,000) before requesting any bytes, then assembles bounded slices.
An oversized file returns an error without reading it; reopen the handle and
use `read_next` instead. Whole-file reads use the configured reader slot and
Mochi permits one whole-file operation at a time so concurrent streaming
readers retain their reserved buffers. It closes the reader on success or
failure. `close` or `cancel` during a read cancels the current slice and
suppresses the callback.

`MochiFiles.read_text(reader, callback, "UTF-8")` provides the same bounded
whole-file convenience for text. UTF-8 is the only supported encoding. Mochi
decodes each bounded range with a strict streaming decoder, so a multibyte
character split across slices remains intact. Malformed UTF-8 and unsupported
encoding names return deterministic errors; no replacement characters or
general Ruby Encoding subsystem are provided. The returned Ruby String
contains the validated UTF-8 bytes.

Ruby-authored tests can use `select_files(selector, files: [...])`,
`drop_files(selector, files: [...])`, and `drag(source, target)`. File entries
accept a path relative to the test file or inline `bytes` as a String or an
Array of byte values. The test runner constructs browser File and DataTransfer
objects. These helpers and their synthetic input stay in the test runner and
do not enter application bundles. `assert_state` checks rendered Ruby state;
`expect_error` checks runtime errors against the calling Ruby test line.

File support is a separate optional `files` adapter. File-input-only apps do
not load drag handling, and text-only drag apps do not load file handling. A
component that handles both kinds of transfer declares both capabilities.
Applications do not receive the internal base64 wire representation.

### Native OS drop verification

Controlled browser File drops and file-input selections are covered by the
cross-engine Playwright contract test. Automated browsers do not initiate a
desktop OS drag. Manual check: serve the standalone file-contract fixture, drag
one zero-byte file and one ordinary file from the desktop into its drop target,
and confirm the Ruby output shows each file's name, size, MIME type, and a
distinct handle. This environment did not perform that desktop gesture; native
OS-drop verification remains pending.
