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

OS file drops and file-input handles use separate opaque, mount-owned Ruby
handles. File metadata and reads are covered by E9.S2–E9.S4; drag transfer does
not expose a browser `File`, `Blob`, or `DataTransfer` object to Ruby.
