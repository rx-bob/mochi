#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${MOCHI_COMPILER:-"$root/compiler/mochi"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mochi-lint-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/valid/lib" "$tmp/invalid/lib"
cat > "$tmp/valid/lib/Widget.rb" <<'RUBY'
class Widget
  @tag_name = "widget"

  def html
    %Q{<p>ok</p>}
  end
end
RUBY
cat > "$tmp/invalid/lib/Widget.rb" <<'RUBY'
class Widget
  @tag_name = "widget"

  def html
    %Q{<button onclick="{missing}">Go</button>}
  end
end
RUBY

"$compiler" lint --help > "$tmp/help.txt"
grep -q "Usage: mochi lint" "$tmp/help.txt"

"$compiler" lint -i "$tmp/valid"

set +e
"$compiler" lint -i "$tmp/invalid" > "$tmp/invalid.txt"
invalid_status=$?
"$compiler" -i "$tmp/valid" lint > "$tmp/order.txt" 2>&1
order_status=$?
env PATH=/nonexistent \
  MRBC=/nonexistent/mrbc \
  MOCHI_GVM_WASM=/nonexistent/mochi-gvm.wasm \
  MOCHI_GVM_JS=/nonexistent/mochi-gvm.js \
  MOCHI_LOADER=/nonexistent/mochi-loader.js \
  "$compiler" lint -i "$tmp/valid" > "$tmp/isolated.txt" 2>&1
isolated_status=$?
set -e

test "$invalid_status" -eq 1
grep -q "correctness/unknown-handler" "$tmp/invalid.txt"
test "$order_status" -eq 2
grep -q "must be the first argument" "$tmp/order.txt"
test "$isolated_status" -eq 0
test ! -s "$tmp/isolated.txt"

echo "lint CLI smoke: ok"
