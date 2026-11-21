#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
fixture="$PWD/e2e/fixtures/clay_inspector"
output=$1
mkdir -p "$output/native"
output=$(cd "$output" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export MOCHI_DESKTOP_STORAGE_DIR="$work/storage"

ruby runtime/test/mochi_test_recorder.rb "$fixture/test" "$output/test-plan.json" inspector_test.rb
compiler/mochi --target=desktop -i "$fixture" -o "$work/bundle"
runtime/desktop/build_host.sh "${MOCHI_GVM_DIR:-../mochi-gvm}" runtime/desktop/test/replay.m \
  "$work/replay" -DMOCHI_DESKTOP_CAPTURE
widths=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("widths")' "$fixture/parity.json")
for width in $widths; do
  "$work/replay" "$work/bundle/Stations.app/Contents/Resources" "$output/test-plan.json" "$output/native" "$width" 2
done
mkdir -p "$output/native-1x"
wrap_widths=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("wrapWidths")' "$fixture/parity.json")
for width in $wrap_widths; do
  "$work/replay" "$work/bundle/Stations.app/Contents/Resources" "$output/test-plan.json" "$output/native-1x" "$width" 1
done

ruby runtime/test/mochi_test_recorder.rb "$fixture/test" "$output/scroll-plan.json" scroll_test.rb
mkdir -p "$output/native-scroll"
scroll_widths=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("scrollWidths")' "$fixture/parity.json")
for width in $scroll_widths; do
  "$work/replay" "$work/bundle/Stations.app/Contents/Resources" "$output/scroll-plan.json" "$output/native-scroll" "$width" 2
done

ruby runtime/test/mochi_test_recorder.rb "$fixture/test" "$output/editor-plan.json" editor_test.rb
mkdir -p "$output/native-editor"
editor_widths=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("editorWidths")' "$fixture/parity.json")
for width in $editor_widths; do
  MOCHI_DESKTOP_STORAGE_DIR="$work/editor-$width" \
    "$work/replay" "$work/bundle/Stations.app/Contents/Resources" "$output/editor-plan.json" "$output/native-editor" "$width" 2
done
