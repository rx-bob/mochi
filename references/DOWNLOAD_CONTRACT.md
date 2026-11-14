# Bounded Ruby downloads

`MochiDownload.save(filename, content_type, content)` starts one browser download
from a live component's user action. It returns `true` after handing the request
to the browser. This is not confirmation of a completed disk write: browser
policy, the save dialog, and user cancellation remain under browser control.

```ruby
def export
  MochiDownload.save("records.jsonl", "application/x-ndjson;charset=utf-8", @lines)
end
```

Bind the method to a click or keyboard action. Mochi loads the optional Ruby
package and adapter before rendering the component's controls; there is no
asynchronous capability import inside the action. Missing user activation,
stale ownership, unsupported arguments, and exhausted limits produce a
Ruby-facing error at the caller's source. Computed getters cannot download.
Unrelated components/apps omit the package and adapter.

## Input and bounds

- `content` is one String or an Array of at most 1,024 String parts. Strings
  carry exact bytes, including NUL and invalid UTF-8. There is no JSON encoding,
  newline conversion, BOM, or implicit concatenation into another VM String.
  Empty content is valid. The adapter creates one bounded Blob, not a stream.
- The filename is a UTF-8 basename of 1–255 bytes. Slash, backslash, control
  characters, `.` and `..` are rejected. The browser/OS may sanitize filenames
  or normalize Unicode; tests compare canonically equivalent Unicode names.
- Content type is a MIME `type/subtype`, optionally followed by exactly
  `;charset=utf-8`, with a 127-byte ceiling. Parameters other than that charset
  are unsupported. Blob MIME casing follows the browser's lowercase behavior.
- `host_file_buffer_bytes` bounds one download (default 262,144 bytes).
  `host_event_queue_bytes` bounds bytes retained by pending download leases
  (default 2,097,152), and `host_file_handles` bounds their count (default 128).
  These existing capacity keys supply separate download-adapter counters;
  they do not consume the file reader's counters. Limits are checked before
  browser handoff. Default capacity profiles and WASM memory limits do not change.

## Lifetime

Mochi owns the anchor, Blob, and object URL. Failure before handoff removes the
anchor, cancels its timer, and revokes any allocated URL immediately. Successful
handoff removes the anchor and holds the URL for 30 seconds before revocation;
browser timer throttling can delay cleanup, while byte/count bounds still apply.
The timer retains only a URL and adapter bookkeeping, not VM byte views or
component objects. The Blob owns its copied bytes until the URL is released.

Unmount removes ownership metadata without shortening the accepted URL lease.
This prevents disposal from racing the browser's asynchronous consumption.
There is no portable browser signal for disk completion and no Ruby cancellation
operation after handoff. Reloading/closing the document releases its URLs.
Filesystem writes, save pickers, streaming output, and unbounded exports are
outside this contract.

## Inspector and Ruby tests

Inspector exports the **current filtered set in its current order**, including
rows outside the visible page. JSONL runs `JSON.generate` once per record and
adds LF. CSV uses header `id,severity,message,source,sequence,timestamp`, CRLF
record separators, quotes every data field, and doubles embedded quotes. Its
timestamp column contains the original integer milliseconds, independent of
display zone. Unicode, commas, embedded quotes, and embedded newlines survive.
An empty selection downloads an empty JSONL file or a CSV header only. This
small serializer is fixture code, not a general Ruby CSV library.

```ruby
download ".export-jsonl"
assert_download filename: "records.jsonl", bytes: expected_jsonl
```

`download` uses a trusted browser click and captures the resulting artifact.
`assert_download` checks its suggested filename and exact downloaded bytes;
`bytes:` accepts a Ruby String or Array of integers from 0 through 255. The
runner reports mismatches at the authored test line and deletes its temporary
download. Assertions allow canonical Unicode filename equivalence, never
content-byte normalization. The harness has a separate 16 MiB capture limit.
No JavaScript is needed in authored applications or browser scenarios.
