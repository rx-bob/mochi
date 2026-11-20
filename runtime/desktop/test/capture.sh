#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
fixture="$PWD/e2e/fixtures/clay_inspector"
output=$1
mkdir -p "$output/native"
output=$(cd "$output" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ruby runtime/test/mochi_test_recorder.rb "$fixture/test" "$output/test-plan.json" inspector_test.rb
compiler/mochi --target=desktop -i "$fixture" -o "$work/bundle"
runtime/desktop/build_host.sh "${MOCHI_GVM_DIR:-../mochi-gvm}" runtime/desktop/test/replay.m \
  "$work/replay" -DMOCHI_DESKTOP_CAPTURE
widths=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("widths")' "$fixture/parity.json")
for width in $widths; do
  "$work/replay" "$work/bundle/Mochi.app/Contents/Resources" "$output/test-plan.json" "$output/native" "$width" 2
done
mkdir -p "$output/native-1x"
wrap_widths=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("wrapWidths")' "$fixture/parity.json")
for width in $wrap_widths; do
  "$work/replay" "$work/bundle/Mochi.app/Contents/Resources" "$output/test-plan.json" "$output/native-1x" "$width" 1
done
