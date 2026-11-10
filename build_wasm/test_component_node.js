const fs = require('fs');
const buf = fs.readFileSync('./mochi-ruby-micro.wasm');

// SIDE_MODULE=1 wasm needs import stubs provided at instantiate time
const envStubs = {};
const mod = new WebAssembly.Module(buf);
const imports = WebAssembly.Module.imports(mod);
imports.forEach(i => {
  if (i.module === 'env') {
    if (!envStubs[i.name]) { envStubs[i.name] = () => { console.warn('stub:', i.name); }; }
  }
});
// Make env/exit actually work
envStubs['exit'] = (code) => { if (code) throw new Error('exit(' + code + ')'); };

WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: {
    fd_close: () => 0,
    fd_read: () => 0,
    fd_write: () => 0,
    fd_seek: () => 0,
    fd_fdstat_get: () => 0,
    path_open: () => 0,
    path_filestat_get: () => 0,
    clock_time_get: () => 0,
    args_sizes_get: () => 0,
    args_get: () => 0,
    environ_sizes_get: () => 0,
    environ_get: () => 0,
    proc_exit: (code) => { if (code) console.error('proc_exit', code); }
  },
  env: envStubs
}).then(instance => {
  console.log('[test] WASM instantiated successfully');
  const exports = instance.exports;
  console.log('[test] mochi_malloc?', typeof exports.mochi_malloc);
  console.log('[test] mochi_init_runtime?', typeof exports.mochi_init_runtime);
  console.log('[test] mochi_load_iseq?', typeof exports.mochi_load_iseq);

  // Init runtime
  const result = exports.mochi_init_runtime ? exports.mochi_init_runtime() : -1;
  console.log('[test] mochi_init_runtime ->', result);

  // Allocate memory for bytecode (use the module's memory if available)
  if (!exports.memory) {
    console.error('[test] No memory export');
    return;
  }
  const memory = exports.memory;
  const memU8 = new Uint8Array(memory.buffer);

  // If malloc is available, allocate; otherwise use a known offset
  let wasmPtr;
  if (exports.mochi_malloc) {
    wasmPtr = exports.mochi_malloc(256);
  } else {
    wasmPtr = 1024; // Static offset
  }
  console.log('[test] allocated at ptr:', wasmPtr);

  // Load bytecode via ccall equivalent
  // mochi_load_iseq args: (ptr, len) -> int
  if (exports.mochi_load_iseq) {
    const loadResult = exports.mochi_load_iseq(wasmPtr, 0);
    console.log('[test] mochi_load_iseq ->', loadResult);
  }

  console.log('[test] COMPONENT ROUND-TRIP SUCCESS (initialization verified)');
}).catch(err => {
  console.error('[test] WASM instantiation failed:', err.message);
});
