#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project="$work/Station inspector"
dom="$work/Web bundle"
desktop="$work/Mac bundle"
cp -R e2e/fixtures/clay_inspector "$project"
cp "$project/public/station-sans.woff2" "$project/public/unused.woff2"
ruby -rjson -e '
  path = ARGV.fetch(0)
  declaration = JSON.parse(File.read(path))
  declaration.fetch("fonts")["Unused"] = "public/unused.woff2"
  File.write(path, JSON.generate(declaration))
' "$project/mochi-portable.json"
app="$desktop/Stations.app"
resources="$app/Contents/Resources"
for build in 1 2; do
  compiler/mochi --target=dom -i "$project" -o "$dom"
  compiler/mochi --target=desktop -i "$project" -o "$desktop"
done
test -x "$app/Contents/MacOS/Mochi"
plist="$app/Contents/Info.plist"
test "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = org.mochi.stations
test "$(plutil -extract CFBundleName raw -o - "$plist")" = Stations
ruby -rjson -e '
  resources, dom = ARGV
  scene = JSON.parse(File.read(File.join(resources, "scene.json")))
  native_files = Dir.children(resources).sort
  expected = scene.fetch("packages") + scene.fetch("fonts").values +
    %w[scene.json 0-OFL.txt LICENSE.clay.txt]
  abort "unexpected native resource inventory: #{native_files}" unless native_files == expected.sort
  abort "desktop scene contains template source" if scene.to_json.match?(/html_template|<button|@font-face/)
  dom_chi = Dir.glob("components/*.chi", base: dom).map { |file| File.basename(file) }.sort
  abort "different component inventories" unless dom_chi == scene.fetch("packages").sort
  shared = scene.fetch("packages").select { |file| file.start_with?("ruby-") }
  abort "missing or duplicated shared station package" unless shared.size == 1 &&
    scene.fetch("packages").first == shared.first
  dom_chi.each do |name|
    abort "different bytecode for #{name}" unless File.binread(File.join(resources, name)) ==
      File.binread(File.join(dom, "components", name))
  end
  files = Dir.glob("**/*", base: dom).select { |file| File.file?(File.join(dom, file)) }
  manifest = JSON.parse(File.read(File.join(dom, "mochi-manifest.json")))
  resources_by_kind = manifest.fetch("resources").values.group_by { |resource| resource.fetch("kind") }
  abort "unexpected portable resource inventory" unless
    resources_by_kind.transform_values(&:size) == { "font" => 3, "font-license" => 1, "document-style" => 2, "style" => 1 }
  expected = %w[index.html mochi-manifest.json mochi-gvm.wasm mochi-gvm.js mochi-loader.js
    components/record-inspector.json components/record-inspector.chi
    components/station-details.json components/station-details.chi] +
    shared.map { |file| "components/#{file}" } +
    resources_by_kind.values.flatten.map { |resource| resource.fetch("file") }
  abort "unexpected DOM inventory: #{files.sort}" unless files.sort == expected.sort
  abort "unexpected DOM loader contents" unless File.binread(File.join(dom, "mochi-loader.js")) ==
    File.binread("runtime/mochi-loader.js")
' "$resources" "$dom"
gvm=${MOCHI_GVM_DIR:-../mochi-gvm}
mrbc=${MRBC:-}
if [ -z "$mrbc" ]; then
  for compiler_root in . "$gvm"; do
    for profile in mochi-v2-host host; do
      candidate="$compiler_root/build_wasm/mruby/src/build/$profile/bin/mrbc"
      if [ -x "$candidate" ]; then
        mrbc=$candidate
        break 2
      fi
    done
  done
fi
if [ -z "$mrbc" ]; then
  echo "Set MRBC to the matching mruby bytecode compiler for the native ABI test." >&2
  exit 1
fi
"$mrbc" -o "$work/native_probe.irep" "$gvm/tests/fixtures/native_probe.rb"
runtime/desktop/build_host.sh "$gvm" "$gvm/tests/gvm/abi_host_test.c" "$work/abi_host_test"
"$work/abi_host_test" "$work/native_probe.irep"
runtime/desktop/build_host.sh "$gvm" runtime/desktop/test/inspector.m "$work/test-inspector"
"$work/test-inspector" "$resources" "$work/inspector.png"

# A broken browser dependency override must be irrelevant to desktop replay.
export MOCHI_E2E_NODE_MODULES="$work/no-playwright"
test_file=inspector_test.rb
compiler/mochi test --target=desktop -i "$project" --test-file="$test_file"
compiler/mochi test --target=desktop -i "$project" --test-file=scroll_test.rb
compiler/mochi test --target=desktop -i "$project" --test-file=details_test.rb

rejected="$work/Rejected details"
cp -R "$project" "$rejected"
ruby e2e/fixtures/clay_inspector/probes/reject_details.rb "$rejected"
compiler/mochi test --target=desktop -i "$rejected" --test-file=rejected_details_test.rb

ruby -e '
  file = ARGV.fetch(0)
  source = File.read(file).sub(%q("Selected station 02"), %q("Selected station 99"))
  File.write(file, source)
' "$project/test/$test_file"
cat >> "$project/test/$test_file" <<'RUBY'

Mochi::Test.test("reject a missing row") do
  mount "record-inspector"
  click "[data-id='99']"
end

Mochi::Test.test("reject an unsupported selector") do
  mount "record-inspector"
  click ".record"
end

Mochi::Test.test("reject a label as a button") do
  mount "record-inspector"
  click "[data-view='selection']"
end
RUBY

status=0
log="$work/failed-replay.log"
compiler/mochi test --target=desktop -i "$project" --test-file="$test_file" > "$log" 2>&1 || status=$?
cat "$log"
test "$status" -eq 1
grep -qF "inspector_test.rb:7 (step 6 assert_text [data-view='selection']): expected text 'Selected station 99', got 'Selected station 02'" "$log"
grep -qF "(step 2 click [data-id='99']): selector matched no accessible control or text" "$log"
grep -qF "(step 2 click .record): unsupported desktop selector" "$log"
grep -qF "(step 2 click [data-view='selection']): selector must identify an accessible button" "$log"

editor="$PWD/e2e/fixtures/clay_editor"
compiler/mochi --target=desktop -i "$editor" -o "$work/Editor bundle"
runtime/desktop/build_host.sh "$gvm" runtime/desktop/test/editor.m "$work/editor"
"$work/editor" "$work/Editor bundle/Station editor.app/Contents/Resources"
compiler/mochi test --target=desktop -i "$editor" --test-file=editor_test.rb

storage="$PWD/e2e/fixtures/clay_storage"
compiler/mochi test --target=desktop -i "$storage" --test-file=storage_test.rb
quota="$work/Quota project"
cp -R "$storage" "$quota"
cp "$storage/probes/storage_quota_test.rb" "$quota/test/"
compiler/mochi test --target=desktop -i "$quota" --test-file=storage_quota_test.rb

compiler/mochi --target=desktop -i "$storage" -o "$work/Storage bundle"
runtime/desktop/build_host.sh "$gvm" runtime/desktop/test/storage.m "$work/test-storage"
storage_resources="$work/Storage bundle/Station storage.app/Contents/Resources"
isolated_store="$work/Isolated storage"
MOCHI_DESKTOP_STORAGE_DIR="$isolated_store" "$work/test-storage" "$storage_resources" seed

other="$work/Other app"
cp -R "$storage" "$other"
ruby -rjson -e '
  path = ARGV.fetch(0)
  project = JSON.parse(File.read(path))
  project["app_id"] = "org.mochi.Station-storage"
  File.write(path, project.to_json)
' "$other/mochi-portable.json"
compiler/mochi --target=desktop -i "$other" -o "$work/Other bundle"
MOCHI_DESKTOP_STORAGE_DIR="$isolated_store" "$work/test-storage" "$work/Other bundle/Station storage.app/Contents/Resources" absent
MOCHI_DESKTOP_STORAGE_DIR="$isolated_store" "$work/test-storage" "$storage_resources" reopen
MOCHI_DESKTOP_STORAGE_DIR="$isolated_store" "$work/test-storage" "$storage_resources" absent
touch "$work/Blocked storage"
MOCHI_DESKTOP_STORAGE_DIR="$work/Blocked storage" "$work/test-storage" "$storage_resources" cold-unavailable
