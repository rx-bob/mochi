// test_node.js — Verify the full round-trip in Node.js
// Usage: node test_node.js

const fs = require('fs');
const path = require('path');

// Emscripten module needs some browser globals stubbed
globalThis.document = {
  currentScript: { src: __filename },
  querySelectorAll: function() { return []; },
  addEventListener: function() {},
};
globalThis.window = {};

async function main() {
  console.log('=== Mochi WASM PoC — Node.js Test ===\n');

  // Load the Emscripten module factory
  const MochiModule = require('./mochi.js');
  const Module = await MochiModule();

  console.log('[1] Module loaded');

  // Wrap ABI functions
  const api = {
    init:        Module.cwrap('mochi_init_runtime',        'number', []),
    loadIseq:    Module.cwrap('mochi_load_iseq',           'number', ['number', 'number']),
    hydrate:     Module.cwrap('mochi_hydrate_component',   'number', ['number', 'number', 'number']),
    render:      Module.cwrap('mochi_render',              'number', ['number']),
    writeEvent:  Module.cwrap('mochi_write_event',         'number', ['number']),
    processEvts: Module.cwrap('mochi_process_events',      'number', []),
    resetEvts:   Module.cwrap('mochi_reset_events',        'number', []),
    renderBuf:   Module.cwrap('mochi_render_buffer_offset','number', []),
    css:         Module.cwrap('mochi_component_css',       'number', ['number']),
    cssBuf:      Module.cwrap('mochi_css_buffer_offset',   'number', []),
    tag:         Module.cwrap('mochi_component_tag',       'number', ['number']),
    tagBuf:      Module.cwrap('mochi_tag_buffer_offset',   'number', []),
    lifecycle:   Module.cwrap('mochi_invoke_lifecycle',    'number', ['number', 'number']),
    mochiMalloc: Module.cwrap('mochi_malloc',              'number', ['number']),
  };

  // Helper to alloc a C string
  function cstr(s) {
    var len = Module.lengthBytesUTF8(s) + 1;
    var ptr = api.mochiMalloc(len);
    Module.stringToUTF8(s, ptr, len);
    return ptr;
  }

  function readBuffer(length, ptr) {
    return length > 0 ? Module.UTF8ToString(ptr, length) : '';
  }

  // 1. Init runtime
  var r = api.init();
  console.log('[2] init_runtime:', r === 0 ? 'OK' : 'FAIL (' + r + ')');

  // 2. Load counter.chi bytecode (prepend RITE header stripped at build)
  var RITE = Buffer.from([0x52,0x49,0x54,0x45,0x30,0x34,0x30,0x30,0x00,0x00]);
  var stripped = fs.readFileSync(path.join(__dirname, 'counter.chi'));
  var mrb = Buffer.concat([RITE, stripped]);
  var mrbPtr = api.mochiMalloc(mrb.length);
  Module.HEAPU8.set(mrb, mrbPtr);
  r = api.loadIseq(mrbPtr, mrb.length);
  console.log('[3] load_iseq:', r === 0 ? 'OK' : 'FAIL (' + r + ')');
  if (r < 0) {
    var buf = api.renderBuf();
    console.log('    Error:', Module.UTF8ToString(buf));
    process.exit(1);
  }

  // 3. Hydrate component
  var slot = api.hydrate(cstr('counter-1'), cstr('Counter'), 0);
  console.log('[4] hydrate:', slot >= 0 ? 'OK (slot=' + slot + ')' : 'FAIL (' + slot + ')');

  // 4. Initial render
  var htmlLen = api.render(cstr('counter-1'));
  var html = Module.UTF8ToString(api.renderBuf());
  console.log('[5] render:', htmlLen > 0 ? 'OK (' + htmlLen + ' bytes)' : 'FAIL');
  console.log('    HTML:', html.substring(0, 100) + '...');

  // 5. Dispatch events
  api.writeEvent(cstr('counter-1|click|increment'));
  var processed = api.processEvts();
  console.log('[6] process_events:', processed + ' processed');

  api.writeEvent(cstr('counter-1|click|increment'));
  api.writeEvent(cstr('counter-1|click|increment'));
  processed = api.processEvts();
  console.log('[7] process_events:', processed + ' processed');

  // 6. Re-render after events
  htmlLen = api.render(cstr('counter-1'));
  html = Module.UTF8ToString(api.renderBuf());
  console.log('[8] render after 3 increments:', htmlLen > 0 ? 'OK' : 'FAIL');
  console.log('    HTML:', html.substring(0, 100) + '...');

  // Verify count is 3
  if (html.includes('>3<')) {
    console.log('\n    Count is 3 — ROUND-TRIP VERIFIED!\n');
  } else {
    console.log('\n    Expected count=3 but got:', html);
    process.exit(1);
  }

  // 7. Test decrement
  api.writeEvent(cstr('counter-1|click|decrement'));
  api.processEvts();
  api.render(cstr('counter-1'));
  html = Module.UTF8ToString(api.renderBuf());
  console.log('[9] after decrement:', html.includes('>2<') ? 'count=2 OK' : 'FAIL');

  // 8. Test reset
  api.writeEvent(cstr('counter-1|click|reset'));
  api.processEvts();
  api.render(cstr('counter-1'));
  html = Module.UTF8ToString(api.renderBuf());
  console.log('[10] after reset:', html.includes('>0<') ? 'count=0 OK' : 'FAIL');
  if (!html.includes('>0<')) process.exit(1);

  // 9. Canonical Mochi component: template bindings, css, and mounted.
  var myStripped = fs.readFileSync(path.join(__dirname, 'my_counter.chi'));
  var myMrb = Buffer.concat([RITE, myStripped]);
  var myPtr = api.mochiMalloc(myMrb.length);
  Module.HEAPU8.set(myMrb, myPtr);
  r = api.loadIseq(myPtr, myMrb.length);
  console.log('[11] load my_counter.chi:', r === 0 ? 'OK' : 'FAIL (' + r + ')');
  if (r < 0) {
    console.log('     Error:', Module.UTF8ToString(api.renderBuf()));
    process.exit(1);
  }

  slot = api.hydrate(cstr('my-counter-1'), cstr('MyCounter'), 0);
  console.log('[12] hydrate MyCounter:', slot >= 0 ? 'OK (slot=' + slot + ')' : 'FAIL (' + slot + ')');
  if (slot < 0) process.exit(1);

  var tagLen = api.tag(cstr('my-counter-1'));
  var tag = readBuffer(tagLen, api.tagBuf());
  console.log('[13] @tag_name:', tag === 'my-counter' ? 'OK' : 'FAIL (' + tag + ')');
  if (tag !== 'my-counter') process.exit(1);

  var cssLen = api.css(cstr('my-counter-1'));
  var css = readBuffer(cssLen, api.cssBuf());
  var cssOk = css.includes('linear-gradient') && css.includes('button:hover');
  console.log('[14] component css:', cssOk ? 'OK (' + cssLen + ' bytes)' : 'FAIL');
  if (!cssOk) process.exit(1);

  var lifecycle = api.lifecycle(cstr('my-counter-1'), cstr('mounted'));
  console.log('[15] mounted lifecycle:', lifecycle === 0 ? 'OK' : 'FAIL (' + lifecycle + ')');
  if (lifecycle !== 0) process.exit(1);

  htmlLen = api.render(cstr('my-counter-1'));
  html = readBuffer(htmlLen, api.renderBuf());
  var initialOk =
    html.includes('Count: 0') &&
    html.includes('data-mounted="1"') &&
    html.includes('data-action="increment"') &&
    html.includes('data-action="decrement"');
  console.log('[16] initial MyCounter render:', initialOk ? 'OK' : 'FAIL');
  console.log('     HTML:', html.replace(/\s+/g, ' ').substring(0, 150));
  if (!initialOk) {
    console.log('     Expected Count: 0, mounted marker, and data-action bindings');
    process.exit(1);
  }

  api.writeEvent(cstr('my-counter-1|click|increment'));
  api.writeEvent(cstr('my-counter-1|click|increment'));
  api.writeEvent(cstr('my-counter-1|click|decrement'));
  processed = api.processEvts();
  htmlLen = api.render(cstr('my-counter-1'));
  html = readBuffer(htmlLen, api.renderBuf());
  console.log('[17] MyCounter after +1:', html.includes('Count: 1') ? 'OK' : 'FAIL');
  if (!html.includes('Count: 1')) {
    console.log('     Expected Count: 1 but got:', html);
    process.exit(1);
  }
  console.log('\n    MYCOUNTER COMPONENT VERIFIED!\n');

  // Summary
  console.log('\n=== Payload Sizes ===');
  var wasmSize = fs.statSync(path.join(__dirname, 'mochi.wasm')).size;
  var glueSize = fs.statSync(path.join(__dirname, 'mochi.js')).size;
  var bsSize = fs.statSync(path.join(__dirname, 'bootstrapper.js')).size;
  var ptSize = fs.statSync(path.join(__dirname, 'painter.js')).size;
  var mrbSize = fs.statSync(path.join(__dirname, 'counter.chi')).size;
  var myCounterSize = fs.statSync(path.join(__dirname, 'my_counter.chi')).size;

  console.log('  mochi.wasm:       ' + (wasmSize / 1024).toFixed(1) + ' KB');
  console.log('  mochi.js (glue):  ' + (glueSize / 1024).toFixed(1) + ' KB');
  console.log('  bootstrapper.js:  ' + (bsSize / 1024).toFixed(1) + ' KB');
  console.log('  painter.js:       ' + (ptSize / 1024).toFixed(1) + ' KB');
  console.log('  counter.chi:      ' + mrbSize + ' bytes');
  console.log('  my_counter.chi:   ' + myCounterSize + ' bytes');
  console.log('  ---');
  console.log('  Framework JS:     ' + ((bsSize + ptSize) / 1024).toFixed(1) + ' KB');
  console.log('  Component JS:     0 bytes');
}

main().catch(e => { console.error(e); process.exit(1); });
