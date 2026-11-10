/**
 * Minimal WASI shim for running WASI-built mochi-ruby-micro.wasm in the browser.
 *
 * This provides stub implementations for the 37 wasi_snapshot_preview1 imports
 * so that the binary can instantiate in a browser context.
 *
 * WARNING: This is a DEMO shim. Many syscalls are no-ops or minimal stubs.
 * For production, use the Emscripten-built binary which does not need WASI.
 */

function createWASIShim() {
  const envVars = {};
  const args = [];
  const openFds = new Map();
  let nextFd = 3; // 0,1,2 are stdin,stdout,stderr

  return {
    args_get: (argv, argvBuf) => 0,
    args_sizes_get: (argcPtr, argvBufSizePtr) => {
      const mem = new Uint32Array(wasmMemory.buffer);
      mem[argcPtr >> 2] = args.length;
      mem[argvBufSizePtr >> 2] = args.reduce((a, s) => a + s.length + 1, 0);
      return 0;
    },
    environ_get: (environ, environBuf) => 0,
    environ_sizes_get: (environCountPtr, environBufSizePtr) => {
      const mem = new Uint32Array(wasmMemory.buffer);
      mem[environCountPtr >> 2] = 0;
      mem[environBufSizePtr >> 2] = 0;
      return 0;
    },
    clock_res_get: (id, resolution) => {
      const mem = new BigInt64Array(wasmMemory.buffer);
      mem[resolution >> 3] = 1n; // 1 nanosecond resolution
      return 0;
    },
    clock_time_get: (id, precision, time) => {
      const mem = new BigInt64Array(wasmMemory.buffer);
      mem[time >> 3] = BigInt(Math.floor(performance.now() * 1e6));
      return 0;
    },
    fd_advise: (fd, offset, len, advice) => 0,
    fd_close: (fd) => {
      openFds.delete(fd);
      return 0;
    },
    fd_datasync: (fd) => 0,
    fd_fdstat_get: (fd, stat) => {
      const mem = new Uint8Array(wasmMemory.buffer);
      mem[stat] = 0; // filetype regular file
      mem[stat + 1] = 0;
      mem[stat + 2] = 0;
      mem[stat + 3] = 0;
      return 0;
    },
    fd_fdstat_set_flags: (fd, flags) => 0,
    fd_filestat_get: (fd, buf) => 0,
    fd_filestat_set_size: (fd, size) => 0,
    fd_filestat_set_times: (fd, atim, mtim, fst_flags) => 0,
    fd_pread: (fd, iovs, iovsLen, offset, nread) => {
      const mem32 = new Uint32Array(wasmMemory.buffer);
      mem32[nread >> 2] = 0;
      return 0;
    },
    fd_prestat_get: (fd, buf) => {
      // Pretend no preopened directories
      return 8; // __WASI_ENOTSUP
    },
    fd_prestat_dir_name: (fd, path, pathLen) => 8,
    fd_pwrite: (fd, iovs, iovsLen, offset, nwritten) => {
      const mem32 = new Uint32Array(wasmMemory.buffer);
      mem32[nwritten >> 2] = 0;
      return 0;
    },
    fd_read: (fd, iovs, iovsLen, nread) => {
      const mem32 = new Uint32Array(wasmMemory.buffer);
      mem32[nread >> 2] = 0;
      return 0;
    },
    fd_readdir: (fd, buf, bufLen, cookie, bufUsed) => {
      const mem32 = new Uint32Array(wasmMemory.buffer);
      mem32[bufUsed >> 2] = 0;
      return 0;
    },
    fd_renumber: (from, to) => 0,
    fd_seek: (fd, offset, whence, newOffset) => {
      const mem64 = new BigInt64Array(wasmMemory.buffer);
      mem64[newOffset >> 3] = 0n;
      return 0;
    },
    fd_sync: (fd) => 0,
    fd_tell: (fd, offset) => {
      const mem64 = new BigInt64Array(wasmMemory.buffer);
      mem64[offset >> 3] = 0n;
      return 0;
    },
    fd_write: (fd, iovs, iovsLen, nwritten) => {
      const mem8 = new Uint8Array(wasmMemory.buffer);
      const mem32 = new Uint32Array(wasmMemory.buffer);
      let written = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = mem32[(iovs >> 2) + i * 2];
        const len = mem32[(iovs >> 2) + i * 2 + 1];
        const str = new TextDecoder().decode(mem8.subarray(ptr, ptr + len));
        if (fd === 1 || fd === 2) {
          console.log(str);
        }
        written += len;
      }
      mem32[nwritten >> 2] = written;
      return 0;
    },
    path_create_directory: (fd, path, pathLen) => 8,
    path_filestat_get: (fd, flags, path, pathLen, buf) => 8,
    path_filestat_set_times: (fd, flags, path, pathLen, atim, mtim, fst_flags) => 8,
    path_link: (oldFd, oldFlags, oldPath, oldPathLen, newFd, newPath, newPathLen) => 8,
    path_open: (fd, dirflags, path, pathLen, oflags, fs_rights_base, fs_rights_inheriting, fdflags, opened_fd) => {
      const mem32 = new Uint32Array(wasmMemory.buffer);
      mem32[opened_fd >> 2] = nextFd++;
      return 0;
    },
    path_readlink: (fd, path, pathLen, buf, bufLen, bufused) => {
      const mem32 = new Uint32Array(wasmMemory.buffer);
      mem32[bufused >> 2] = 0;
      return 8;
    },
    path_remove_directory: (fd, path, pathLen) => 8,
    path_rename: (fd, oldPath, oldPathLen, newFd, newPath, newPathLen) => 8,
    path_symlink: (oldPath, oldPathLen, fd, newPath, newPathLen) => 8,
    path_unlink_file: (fd, path, pathLen) => 8,
    poll_oneoff: (inPtr, outPtr, nsubscriptions, nevents) => {
      const mem32 = new Uint32Array(wasmMemory.buffer);
      mem32[nevents >> 2] = 0;
      return 0;
    },
    proc_exit: (code) => {
      throw new Error(`WASI proc_exit(${code})`);
    },
    proc_raise: (sig) => 0,
    random_get: (buf, bufLen) => {
      const mem8 = new Uint8Array(wasmMemory.buffer);
      crypto.getRandomValues(mem8.subarray(buf, buf + bufLen));
      return 0;
    },
    sched_yield: () => 0,
    sock_accept: (fd, flags, newFd) => {
      return 52; // __WASI_ENOSYS
    },
    sock_recv: (fd, riData, riDataLen, riFlags, roDataLen, roFlags) => {
      return 52;
    },
    sock_send: (fd, siData, siDataLen, siFlags, soDataLen) => {
      return 52;
    },
    sock_shutdown: (fd, how) => {
      return 52;
    },
  };
}

let wasmMemory = null;

async function loadMochiWASM(wasmUrl) {
  const response = await fetch(wasmUrl);
  const bytes = await response.arrayBuffer();

  const wasi = createWASIShim();

  const importObject = {
    wasi_snapshot_preview1: wasi,
    env: {
      memory: new WebAssembly.Memory({ initial: 256, maximum: 512 }),
      // Stub any env imports the binary might need
      __assert_fail: () => {},
      emscripten_notify_memory_growth: () => {},
    }
  };

  wasmMemory = importObject.env.memory;

  const { instance } = await WebAssembly.instantiate(bytes, importObject);

  console.log("WASM loaded. Exports:", Object.keys(instance.exports).filter(k => k.includes("mochi")));

  return instance;
}

// Expose globally for bootstrapper_v2.js
window.loadMochiWASM = loadMochiWASM;
