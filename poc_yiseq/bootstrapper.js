// bootstrapper.js — Mochi WASM bootstrapper (~2KB)
// Lazy-loads the WASM runtime when components become visible.

(function() {
  'use strict';

  let _module = null;
  let _modulePromise = null;
  let _api = null;

  // Load the WASM module (deduplicated — only fetches once)
  function loadRuntime() {
    if (_modulePromise) return _modulePromise;
    _modulePromise = MochiModule().then(function(mod) {
      _module = mod;
      _api = {
        init:        mod.cwrap('mochi_init_runtime',        'number', []),
        loadIseq:    mod.cwrap('mochi_load_iseq',           'number', ['number', 'number']),
        hydrate:     mod.cwrap('mochi_hydrate_component',   'number', ['number', 'number', 'number']),
        render:      mod.cwrap('mochi_render',              'number', ['number']),
        writeEvent:  mod.cwrap('mochi_write_event',         'number', ['number']),
        processEvts: mod.cwrap('mochi_process_events',      'number', []),
        resetEvts:   mod.cwrap('mochi_reset_events',        'number', []),
        renderBuf:   mod.cwrap('mochi_render_buffer_offset','number', []),
        mochiMalloc: mod.cwrap('mochi_malloc',              'number', ['number']),
      };
      _api.init();
      return { mod: mod, api: _api };
    });
    return _modulePromise;
  }

  // Allocate a C string in WASM memory
  function allocCString(mod, str) {
    var len = mod.lengthBytesUTF8(str) + 1;
    var ptr = _api.mochiMalloc(len);
    mod.stringToUTF8(str, ptr, len);
    return ptr;
  }

  // Load .mrb bytecode into the VM
  async function loadBytecode(url) {
    var resp = await fetch(url);
    var buf = await resp.arrayBuffer();
    var bytes = new Uint8Array(buf);
    var ptr = _api.mochiMalloc(bytes.length);
    _module.HEAPU8.set(bytes, ptr);
    var result = _api.loadIseq(ptr, bytes.length);
    if (result < 0) {
      var errBuf = _api.renderBuf();
      throw new Error('load_iseq failed: ' + _module.UTF8ToString(errBuf));
    }
    return result;
  }

  // Hydrate a component: instantiate Ruby class, render, paint DOM
  function hydrateComponent(el, componentId, className) {
    var idPtr = allocCString(_module, componentId);
    var clsPtr = allocCString(_module, className);
    var slot = _api.hydrate(idPtr, clsPtr, 0);
    if (slot < 0) throw new Error('hydrate failed for ' + className + ': ' + slot);

    // Initial render
    renderComponent(el, componentId);

    // Event delegation
    el.addEventListener('click', function(e) {
      var btn = e.target.closest('[data-action]');
      if (!btn) return;
      var method = btn.getAttribute('data-action');
      dispatchEvent(componentId, 'click', method);
      renderComponent(el, componentId);
    });

    el.addEventListener('input', function(e) {
      var input = e.target.closest('[data-action]');
      if (!input) return;
      var method = input.getAttribute('data-action');
      dispatchEvent(componentId, 'input', method);
      renderComponent(el, componentId);
    });

    return slot;
  }

  // Dispatch an event to the WASM VM
  function dispatchEvent(componentId, eventType, method) {
    var line = componentId + '|' + eventType + '|' + method;
    var linePtr = allocCString(_module, line);
    _api.writeEvent(linePtr);
    _api.processEvts();
  }

  // Render a component: call Ruby #html, read shared memory, paint DOM
  function renderComponent(el, componentId) {
    var idPtr = allocCString(_module, componentId);
    var htmlLen = _api.render(idPtr);
    if (htmlLen > 0) {
      var bufPtr = _api.renderBuf();
      var html = _module.UTF8ToString(bufPtr);
      MochiPainter.paint(el, html);
    }
  }

  // Boot: observe [data-mochi] elements, hydrate when visible
  async function boot() {
    var elements = document.querySelectorAll('[data-mochi]');
    if (!elements.length) return;

    var runtime = await loadRuntime();

    // Collect unique bytecode URLs
    var loaded = {};
    for (var i = 0; i < elements.length; i++) {
      var src = elements[i].getAttribute('data-mochi-src');
      if (src && !loaded[src]) {
        await loadBytecode(src);
        loaded[src] = true;
      }
    }

    // Hydrate each component
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      var id = el.getAttribute('data-mochi');
      var cls = el.getAttribute('data-mochi-class');
      if (id && cls) {
        hydrateComponent(el, id, cls);
      }
    }
  }

  // Lazy boot with IntersectionObserver (or immediate if not supported)
  function lazyBoot() {
    if (!('IntersectionObserver' in window)) {
      boot();
      return;
    }

    var target = document.querySelector('[data-mochi]');
    if (!target) return;

    var observer = new IntersectionObserver(function(entries) {
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].isIntersecting) {
          observer.disconnect();
          boot();
          return;
        }
      }
    }, { rootMargin: '200px' });

    observer.observe(target);
  }

  // Expose for direct use
  window.MochiBootstrap = {
    loadRuntime: loadRuntime,
    loadBytecode: loadBytecode,
    hydrateComponent: hydrateComponent,
    dispatchEvent: dispatchEvent,
    renderComponent: renderComponent,
    boot: boot,
    lazyBoot: lazyBoot,
  };

  // Auto-boot on DOMContentLoaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', lazyBoot);
  } else {
    lazyBoot();
  }
})();
