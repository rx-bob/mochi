#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MRUBY_DIR="${MRUBY_DIR:-$SCRIPT_DIR/../build_wasm/mruby/src}"
GOOSE_REPO="${GOOSE_REPO:-$SCRIPT_DIR/../../mochi-goose}"
GOOSE_VM="${GOOSE_VM:-$GOOSE_REPO/src/goose_vm}"
GOOSE_ENTRY="$GOOSE_VM/vm.goose"

if [ -n "${GOOSE:-}" ]; then
  if command -v "$GOOSE" >/dev/null 2>&1; then
    GOOSE_BIN="$(command -v "$GOOSE")"
  else
    GOOSE_BIN="$GOOSE"
  fi
elif command -v goose >/dev/null 2>&1; then
  GOOSE_BIN="$(command -v goose)"
else
  GOOSE_BIN="/Users/bob/.local/bin/goose"
fi

BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1"
    exit 1
  fi
}

need_file() {
  if [ ! -f "$1" ]; then
    echo "Error: required file not found: $1"
    exit 1
  fi
}

need_exec() {
  if [ ! -x "$1" ]; then
    echo "Error: required executable not found: $1"
    exit 1
  fi
}

need_cmd ruby
need_cmd rake
need_cmd emcc
need_cmd wasm-opt
need_cmd zstd
need_cmd bc
need_cmd gzip
need_exec "$GOOSE_BIN"
need_file "$GOOSE_ENTRY"
need_file "$SCRIPT_DIR/mochi_bridge.c"
need_file "$SCRIPT_DIR/type_strip.rb"
need_file "$SCRIPT_DIR/mochi_component_compiler.rb"
need_file "$SCRIPT_DIR/my_counter.rb"
need_file "$SCRIPT_DIR/painter.js"
need_file "$SCRIPT_DIR/bootstrapper.js"
need_file "$GOOSE_VM/mrb_abi_shim.c"
need_file "$GOOSE_VM/mrbgem_loader.c"
need_file "$GOOSE_VM/include/mruby.h"
for rb in counter todo users; do
  need_file "$SCRIPT_DIR/${rb}.rb"
done

if [ ! -d "$MRUBY_DIR" ]; then
  echo "Error: mruby source not found at $MRUBY_DIR"
  echo "Set MRUBY_DIR or fetch mruby before building."
  exit 1
fi

SORBET_AVAILABLE=0
if command -v srb >/dev/null 2>&1; then
  SORBET_AVAILABLE=1
fi

echo "=== Mochi PoC WASM Build ==="

# 0. Host mrbc only. The Emscripten libmruby cross-build is gone.
if [ -n "${MRBC:-}" ]; then
  need_exec "$MRBC"
  echo "[0/8] Using host mrbc: $MRBC"
else
  MRBC="$MRUBY_DIR/build/host/bin/mrbc"
  if [ ! -x "$MRBC" ]; then
    echo "[0/8] Building host mrbc..."
    cat > "$BUILD_TMP/build_config_host.rb" <<'RUBY'
MRuby::Build.new do |conf|
  conf.toolchain :clang
  conf.gem core: 'mruby-compiler'
  conf.gem core: 'mruby-bin-mrbc'
end
RUBY
    HOST_BUILD_LOG="$BUILD_TMP/host-build.log"
    if ! (
      cd "$MRUBY_DIR"
      MRUBY_CONFIG="$BUILD_TMP/build_config_host.rb" rake
    ) >"$HOST_BUILD_LOG" 2>&1; then
      tail -40 "$HOST_BUILD_LOG"
      echo "Error: host mrbc build failed."
      exit 1
    fi
    tail -3 "$HOST_BUILD_LOG"
    need_exec "$MRBC"
  else
    echo "[0/8] Using host mrbc: $MRBC"
  fi
fi

# emcc needs the Python and bundled LLVM that match its install. The homebrew
# wrapper exposes both under the Cellar prefix; use them when present. Keep
# this after the host mrbc build so native clang is still the host compiler.
EMCC_BIN="$(command -v emcc)"
EMCC_REAL="$(ruby -e 'puts File.realpath(ARGV[0])' "$EMCC_BIN")"
EMCC_ROOT="$(cd "$(dirname "$EMCC_REAL")/.." && pwd)"
if [ -d "$EMCC_ROOT/libexec/llvm/bin" ]; then
  export PATH="$EMCC_ROOT/libexec/llvm/bin:$PATH"
fi
if [ -z "${EMSDK_PYTHON:-}" ]; then
  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
      EMSDK_PYTHON="$(command -v "$candidate")"
      break
    fi
  done
fi
if [ -z "${EMSDK_PYTHON:-}" ]; then
  echo "Error: emcc needs Python 3.10 or newer."
  echo "Set EMSDK_PYTHON to a suitable interpreter."
  exit 1
fi
export EMSDK_PYTHON

# 1. Sorbet type checking (optional — requires sorbet in PATH)
echo "[1/8] Type checking (Sorbet)"
if [ "$SORBET_AVAILABLE" -eq 1 ]; then
  # Run sorbet on all .rb files that have `# typed:` annotations
  if srb tc "$SCRIPT_DIR" --ignore='*.chi,*.mrb,*.wasm,*.js,*.html,*.c,*.sh,*.rb.tmp' 2>&1; then
    echo "  sorbet: all files passed type checking"
  else
    echo "  sorbet: type errors found (fix before build)"
    exit 1
  fi
else
  echo "  sorbet: not installed — skipping type check (install: gem install sorbet)"
fi

# 2. Strip Sorbet annotations → .rb.tmp, then compile → .chi
echo "[2/8] Stripping Sorbet annotations → .rb.tmp → bytecode"
for rb in counter todo users; do
  ruby "$SCRIPT_DIR/type_strip.rb" "$SCRIPT_DIR/${rb}.rb" "$SCRIPT_DIR/${rb}.rb.tmp"
  "$MRBC" -o "$SCRIPT_DIR/${rb}.chi.tmp" "$SCRIPT_DIR/${rb}.rb.tmp"
  tail -c +11 "$SCRIPT_DIR/${rb}.chi.tmp" > "$SCRIPT_DIR/${rb}.chi"
  rm "$SCRIPT_DIR/${rb}.chi.tmp" "$SCRIPT_DIR/${rb}.rb.tmp"
done
ruby "$SCRIPT_DIR/mochi_component_compiler.rb" \
  "$SCRIPT_DIR/my_counter.rb" "$BUILD_TMP/my_counter.rb"
ruby "$SCRIPT_DIR/type_strip.rb" \
  "$BUILD_TMP/my_counter.rb" "$BUILD_TMP/my_counter.stripped.rb"
"$MRBC" -o "$BUILD_TMP/my_counter.chi" "$BUILD_TMP/my_counter.stripped.rb"
tail -c +11 "$BUILD_TMP/my_counter.chi" > "$SCRIPT_DIR/my_counter.chi"
echo "  counter.chi:    $(wc -c < "$SCRIPT_DIR/counter.chi") bytes"
echo "  todo.chi:       $(wc -c < "$SCRIPT_DIR/todo.chi") bytes"
echo "  users.chi:      $(wc -c < "$SCRIPT_DIR/users.chi") bytes"
echo "  my_counter.chi: $(wc -c < "$SCRIPT_DIR/my_counter.chi") bytes"

# 3. Emit the standalone Goose VM C and its host header.
echo "[3/8] Emitting Goose VM → goose_vm.c"
"$GOOSE_BIN" \
  -o "$BUILD_TMP/goose_vm.c" \
  --standalone \
  --header "$BUILD_TMP/goose_vm.h" \
  --stack-reserve 512K \
  -O2 \
  "$GOOSE_ENTRY"

# 4. Compile bridge + opaque ABI shim + mrbgem loader + Goose VM → wasm.
# Use a temp dir so emcc produces glue that references `mochi.wasm` (not
# `_emscripten_glue.wasm`).
echo "[4/8] Compiling mochi_bridge.c + Goose VM → mochi.wasm"
emcc \
  -Oz \
  -fwasm-exceptions \
  -sSUPPORT_LONGJMP=wasm \
  -DMOCHI_ABI_OWNS_GOOSE_LIFECYCLE \
  -sEXPORTED_FUNCTIONS='["_main","_mochi_init_runtime","_mochi_hydrate_component","_mochi_process_events","_mochi_render_buffer_offset","_mochi_css_buffer_offset","_mochi_tag_buffer_offset","_mochi_event_buffer_offset","_mochi_load_iseq","_mochi_malloc","_mochi_render","_mochi_component_css","_mochi_component_tag","_mochi_invoke_lifecycle","_mochi_write_event","_mochi_reset_events","_mochi_fetch_outbox_offset","_mochi_fetch_outbox_len","_mochi_fetch_outbox_clear","_mochi_fetch_inbox_offset","_mochi_deliver_fetch","_malloc","_free"]' \
  -sEXPORTED_RUNTIME_METHODS='["ccall","cwrap","UTF8ToString","stringToUTF8","lengthBytesUTF8","HEAPU8","setValue","getValue"]' \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=4194304 \
  -sSTACK_SIZE=1048576 \
  -sMODULARIZE=1 \
  -sEXPORT_NAME="MochiModule" \
  -sNO_EXIT_RUNTIME=1 \
  --no-entry \
  -I"$GOOSE_VM/include" \
  "$SCRIPT_DIR/mochi_bridge.c" \
  "$GOOSE_VM/mrb_abi_shim.c" \
  "$GOOSE_VM/mrbgem_loader.c" \
  "$BUILD_TMP/goose_vm.c" \
  -o "$BUILD_TMP/mochi.js"

# Move wasm to project root; keep glue JS for bundling
mv "$BUILD_TMP/mochi.wasm" "$SCRIPT_DIR/mochi.wasm"
cp "$BUILD_TMP/mochi.js" "$SCRIPT_DIR/_emscripten_glue.js"

# 5. Optimize WASM binary
echo "[5/8] Running wasm-opt + wasm-strip"
wasm-opt -Oz \
  --strip-debug --strip-producers \
  --enable-bulk-memory --enable-exception-handling --enable-nontrapping-float-to-int \
  "$SCRIPT_DIR/mochi.wasm" -o "$SCRIPT_DIR/mochi.wasm"

# 6. Bundle JS: Emscripten glue + painter + bootstrapper → mochi.js
echo "[6/8] Bundling mochi.js"
cat "$SCRIPT_DIR/_emscripten_glue.js" "$SCRIPT_DIR/painter.js" "$SCRIPT_DIR/bootstrapper.js" > "$SCRIPT_DIR/mochi.js"

# 7. Summary and size gate.
WASM_RAW=$(wc -c < "$SCRIPT_DIR/mochi.wasm")
WASM_GZ=$(gzip -c "$SCRIPT_DIR/mochi.wasm" | wc -c)
JS_SIZE=$(wc -c < "$SCRIPT_DIR/mochi.js")
BASELINE_GZ=$((125 * 1024))

echo ""
echo "[7/8] Build complete!"
echo ""
echo "  WASM (Goose VM):   $(echo "scale=1; $WASM_RAW / 1024" | bc) KB raw / $(echo "scale=1; $WASM_GZ / 1024" | bc) KB gzip"
echo "  mochi.js:          $(echo "scale=1; $JS_SIZE / 1024" | bc) KB"
echo "  counter.chi:       $(wc -c < "$SCRIPT_DIR/counter.chi") bytes"
echo "  todo.chi:          $(wc -c < "$SCRIPT_DIR/todo.chi") bytes"
echo "  users.chi:         $(wc -c < "$SCRIPT_DIR/users.chi") bytes"
echo "  my_counter.chi:    $(wc -c < "$SCRIPT_DIR/my_counter.chi") bytes"
echo ""

if [ "$WASM_GZ" -ge "$BASELINE_GZ" ]; then
  echo "Error: mochi.wasm gzip is $WASM_GZ bytes; must be below $BASELINE_GZ bytes (125 KiB)."
  exit 1
fi

# 8. Build raw compression dictionary from all .chi files
# Chrome uses ZSTD_dct_rawContent, so we must use a raw dictionary (not zstd --train format)
echo "[8/8] Building compression dictionary"
cat "$SCRIPT_DIR"/*.chi > "$SCRIPT_DIR/mochi-dict.dat"

# Pre-compress each .chi with the raw dictionary for server use
for chi in "$SCRIPT_DIR"/*.chi; do
  zstd --no-dictID -D "$SCRIPT_DIR/mochi-dict.dat" -f -o "${chi}.dcz" "$chi" 2>/dev/null
done

DICT_SIZE=$(wc -c < "$SCRIPT_DIR/mochi-dict.dat")
echo "  mochi-dict.dat:  $DICT_SIZE bytes"
echo ""
echo "  Serve with: node server.js"
