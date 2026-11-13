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
gets one error and no handle from that batch remains registered. Contents and
bounded read operations are covered by E9.S3–E9.S4.

File support is a separate optional `files` adapter. File-input-only apps do
not load drag handling, and text-only drag apps do not load file handling. A
component that handles both kinds of transfer declares both capabilities.

### Native OS drop verification

Controlled browser File drops and file-input selections are covered by the
cross-engine Playwright contract test. Automated browsers do not initiate a
desktop OS drag. Manual check: serve the standalone file-contract fixture, drag
one zero-byte file and one ordinary file from the desktop into its drop target,
and confirm the Ruby output shows each file's name, size, MIME type, and a
distinct handle. This environment did not perform that desktop gesture; native
OS-drop verification remains pending.
