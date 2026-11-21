#!/bin/sh
# Link the standalone generated Goose VM, the pinned Clay layout bridge, and AppKit.
set -eu
root=$(cd "$(dirname "$0")" && pwd)
gvm=$1
entry=$2
binary=$3
shift 3
if [ ! -f "$gvm/dist/goose_vm.c" ]; then
  echo "Missing $gvm/dist/goose_vm.c. Build the matching mochi-gvm artifacts first." >&2
  exit 1
fi
if [ ! -f "$gvm/src/gvm/include/mochi_native.h" ]; then
  echo "Missing native GVM ABI v3 header in $gvm. Use a matching mochi-gvm checkout." >&2
  exit 1
fi
xcrun clang -DMOCHI_NATIVE_STANDALONE -Os -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Wno-parentheses-equality "$@" \
  -I"$root" -I"$root/../clay/vendor" -I"$gvm/src/gvm" -I"$gvm/src/gvm/include" \
  "$gvm/dist/goose_vm.c" "$gvm/src/gvm/mrb_abi_shim.c" "$gvm/src/gvm/mrbgem_loader.c" \
  "$gvm/src/gvm/mochi_gvm_bridge.c" "$root/../clay/layout.c" "$root/VM.m" "$root/Contracts.m" "$root/Storage.m" "$root/View.m" "$entry" \
  -framework AppKit -framework CoreText -lsqlite3 -Wl,-dead_strip -o "$binary"
