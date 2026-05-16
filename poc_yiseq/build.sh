#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MRUBY_DIR="$SCRIPT_DIR/../build_wasm/mruby/src"
BUILD_DIR="$MRUBY_DIR/build/emscripten"

echo "=== Mochi PoC WASM Build ==="

# 1. Compile counter.rb → counter.mrb using host mrbc
echo "[1/3] Compiling counter.rb → counter.mrb"
"$MRUBY_DIR/build/host/bin/mrbc" -o "$SCRIPT_DIR/counter.mrb" "$SCRIPT_DIR/counter.rb"
echo "  counter.mrb: $(wc -c < "$SCRIPT_DIR/counter.mrb") bytes"

# 2. Compile bridge + link with libmruby.a → mochi.wasm
echo "[2/3] Compiling mochi_bridge.c → mochi.wasm"
emcc \
  -Oz \
  -fwasm-exceptions \
  -sSUPPORT_LONGJMP=wasm \
  -sEXPORTED_FUNCTIONS='["_main","_mochi_init_runtime","_mochi_hydrate_component","_mochi_process_events","_mochi_render_buffer_offset","_mochi_event_buffer_offset","_mochi_load_iseq","_mochi_malloc","_mochi_render","_mochi_write_event","_mochi_reset_events","_malloc","_free"]' \
  -sEXPORTED_RUNTIME_METHODS='["ccall","cwrap","UTF8ToString","stringToUTF8","lengthBytesUTF8","HEAPU8","setValue","getValue"]' \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=4194304 \
  -sMODULARIZE=1 \
  -sEXPORT_NAME="MochiModule" \
  -sNO_EXIT_RUNTIME=1 \
  --no-entry \
  -I"$MRUBY_DIR/include" \
  -I"$BUILD_DIR/include" \
  "$SCRIPT_DIR/mochi_bridge.c" \
  "$BUILD_DIR/lib/libmruby.a" \
  -o "$SCRIPT_DIR/mochi.js"

WASM_SIZE=$(wc -c < "$SCRIPT_DIR/mochi.wasm")
GZIP_SIZE=$(gzip -c "$SCRIPT_DIR/mochi.wasm" | wc -c)
echo "  mochi.wasm: $WASM_SIZE bytes raw, ~$GZIP_SIZE bytes gzip"

JS_SIZE=$(wc -c < "$SCRIPT_DIR/mochi.js")
echo "  mochi.js (emscripten glue): $JS_SIZE bytes"

# 3. Summary
echo ""
echo "[3/3] Build complete!"
echo "  Files:"
echo "    mochi.wasm       - mruby VM + bridge ($WASM_SIZE bytes)"
echo "    mochi.js         - Emscripten glue"
echo "    counter.mrb      - Compiled Ruby bytecode"
echo "    bootstrapper.js  - Mochi bootstrapper"
echo "    painter.js       - DOM painter"
echo "    index.html       - Demo page"
echo ""
echo "  Serve with: cd poc_yiseq && python3 -m http.server 8080"
