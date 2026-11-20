#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project="$work/Station inspector"
dom="$work/Web bundle"
desktop="$work/Mac bundle"
cp -R e2e/fixtures/clay_inspector "$project"
app="$desktop/Mochi.app"
resources="$app/Contents/Resources"
for build in 1 2; do
  compiler/mochi --target=dom -i "$project" -o "$dom"
  compiler/mochi --target=desktop -i "$project" -o "$desktop"
done
codesign --verify --strict "$app"
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
  dom_chi.each do |name|
    abort "different bytecode for #{name}" unless File.binread(File.join(resources, name)) ==
      File.binread(File.join(dom, "components", name))
  end
  files = Dir.glob("**/*", base: dom).select { |file| File.file?(File.join(dom, file)) }
  expected = %w[index.html mochi-manifest.json mochi-gvm.wasm mochi-gvm.js mochi-loader.js
    components/record-inspector.json components/record-inspector.chi public/OFL.txt public/station-sans.woff2]
  abort "unexpected DOM inventory: #{files.sort}" unless files.sort == expected.sort
  abort "unexpected DOM loader contents" unless File.binread(File.join(dom, "mochi-loader.js")) ==
    File.binread("runtime/mochi-loader.js")
' "$resources" "$dom"
runtime/desktop/build_host.sh "${MOCHI_GVM_DIR:-../mochi-gvm}" runtime/desktop/test/inspector.m "$work/test-inspector"
"$work/test-inspector" "$resources" "$work/inspector.png"
