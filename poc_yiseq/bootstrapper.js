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
        css:         mod.cwrap('mochi_component_css',       'number', ['number']),
        cssBuf:      mod.cwrap('mochi_css_buffer_offset',   'number', []),
        tag:         mod.cwrap('mochi_component_tag',       'number', ['number']),
        tagBuf:      mod.cwrap('mochi_tag_buffer_offset',   'number', []),
        mochiMalloc: mod.cwrap('mochi_malloc',              'number', ['number']),
      };
      _api.fetchOutbox    = mod.cwrap('mochi_fetch_outbox_offset', 'number', []);
      _api.fetchOutboxLen = mod.cwrap('mochi_fetch_outbox_len',    'number', []);
      _api.fetchOutboxClr = mod.cwrap('mochi_fetch_outbox_clear',  'number', []);
      _api.fetchInbox     = mod.cwrap('mochi_fetch_inbox_offset',  'number', []);
      _api.deliverFetch   = mod.cwrap('mochi_deliver_fetch',       'number', ['number', 'number', 'number']);
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

  // RITE header stripped at build time, prepended at load time
  var RITE_HEADER = new Uint8Array([0x52,0x49,0x54,0x45,0x30,0x34,0x30,0x30,0x00,0x00]);

  // Load .chi bytecode into the VM
  async function loadBytecode(url) {
    var resp = await fetch(url);
    var buf = await resp.arrayBuffer();
    var stripped = new Uint8Array(buf);

    // Prepend the RITE header
    var full = new Uint8Array(RITE_HEADER.length + stripped.length);
    full.set(RITE_HEADER, 0);
    full.set(stripped, RITE_HEADER.length);

    var ptr = _api.mochiMalloc(full.length);
    _module.HEAPU8.set(full, ptr);
    var result = _api.loadIseq(ptr, full.length);
    if (result < 0) {
      var errBuf = _api.renderBuf();
      throw new Error('load_iseq failed: ' + _module.UTF8ToString(errBuf));
    }
    return result;
  }

  function readStringBuffer(length, ptr) {
    if (length <= 0) return '';
    return _module.UTF8ToString(ptr, length);
  }

  function componentCss(componentId) {
    var idPtr = allocCString(_module, componentId);
    var length = _api.css(idPtr);
    return readStringBuffer(length, _api.cssBuf());
  }

  function componentTag(componentId) {
    var idPtr = allocCString(_module, componentId);
    var length = _api.tag(idPtr);
    return readStringBuffer(length, _api.tagBuf());
  }

  // Components with CSS render inside a shadow root, keeping selectors local.
  // The persistent style and body siblings survive painter updates.
  function ensureShadowHost(el, componentId, css) {
    if (!css) return el;

    var root = el.shadowRoot || el.attachShadow({ mode: 'open' });
    var style = root.querySelector('style[data-mochi-style]');
    if (!style) {
      style = document.createElement('style');
      style.setAttribute('data-mochi-style', componentId);
      root.insertBefore(style, root.firstChild);
    }
    style.textContent = css;

    var body = root.querySelector('[data-mochi-body]');
    if (!body) {
      body = document.createElement('div');
      body.setAttribute('data-mochi-body', '');
      root.appendChild(body);
    }
    return body;
  }

  function renderTarget(el) {
    return el._mochiBody || el;
  }

  // Hydrate a component: instantiate Ruby class, apply CSS, render, paint DOM.
  // The C bridge calls Ruby #mounted before this function returns.
  function hydrateComponent(el, componentId, className) {
    var idPtr = allocCString(_module, componentId);
    var clsPtr = allocCString(_module, className);
    var slot = _api.hydrate(idPtr, clsPtr, 0);
    if (slot < 0) throw new Error('hydrate failed for ' + className + ': ' + slot);

    var tag = componentTag(componentId);
    if (tag) {
      var actualTag = (el.localName || el.tagName || '').toLowerCase();
      if (actualTag !== tag) {
        throw new Error(
          'component tag mismatch for ' + className + ': expected <' +
          tag + '>, got <' + actualTag + '>'
        );
      }
    }

    el._mochiBody = ensureShadowHost(el, componentId, componentCss(componentId));

    // Initial render
    renderComponent(el, componentId);
    drainFetchOutbox();

    // Event delegation. Shadow-root listeners see the real button target;
    // a listener on the host would be retargeted and lose data-action.
    var eventRoot = el.shadowRoot || el;
    eventRoot.addEventListener('click', function(e) {
      var btn = e.target.closest('[data-action]');
      if (!btn) return;
      var method = btn.getAttribute('data-action');
      dispatchEvent(componentId, 'click', method);
      renderComponent(el, componentId);
    });

    eventRoot.addEventListener('input', function(e) {
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
    drainFetchOutbox();
  }

  // Check if Ruby queued any fetch requests, execute them in JS
  function drainFetchOutbox() {
    var len = _api.fetchOutboxLen();
    if (len <= 0) return;

    var outboxPtr = _api.fetchOutbox();
    var raw = _module.UTF8ToString(outboxPtr, len);
    _api.fetchOutboxClr();

    var lines = raw.trim().split('\n');
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split('|');
      if (parts.length < 4) continue;
      // parts: [fetchId, componentId, callback, url]
      executeFetch(parts[1], parts[2], parts[3]);
    }
  }

  // Perform the actual fetch, deliver response back to WASM
  function executeFetch(componentId, callback, url) {
    fetch(url).then(function(resp) {
      return resp.text();
    }).then(function(text) {
      // Write response body into the inbox buffer
      var inboxPtr = _api.fetchInbox();
      var encoded = new TextEncoder().encode(text);
      var maxLen = 65536 - 1;
      var writeLen = Math.min(encoded.length, maxLen);
      _module.HEAPU8.set(encoded.subarray(0, writeLen), inboxPtr);
      _module.HEAPU8[inboxPtr + writeLen] = 0;

      // Call mochi_deliver_fetch(component_id, callback, resp_len)
      var compPtr = allocCString(_module, componentId);
      var cbPtr = allocCString(_module, callback);
      _api.deliverFetch(compPtr, cbPtr, writeLen);

      // Re-render the component that made the request
      var el = document.querySelector('[data-mochi="' + componentId + '"]');
      if (el) renderComponent(el, componentId);

      // Check if the callback triggered more fetches
      drainFetchOutbox();
    }).catch(function(err) {
      console.error('[mochi] fetch error:', url, err);
    });
  }

  // Render a component: call Ruby #html, read shared memory, paint DOM
  function renderComponent(el, componentId) {
    var idPtr = allocCString(_module, componentId);
    var htmlLen = _api.render(idPtr);
    if (htmlLen > 0) {
      var bufPtr = _api.renderBuf();
      var html = _module.UTF8ToString(bufPtr);
      MochiPainter.paint(renderTarget(el), html);
    }
  }

  function discoverElements() {
    var nodes = document.querySelectorAll(
      '[data-mochi], [data-mochi-class][data-mochi-src]'
    );
    var elements = [];
    for (var i = 0; i < nodes.length; i++) {
      if (elements.indexOf(nodes[i]) === -1) elements.push(nodes[i]);
    }
    return elements;
  }

  // Boot: observe marked/custom elements, hydrate when visible. The C bridge
  // validates each element's @tag_name once its bytecode class is loaded.
  async function boot() {
    var elements = discoverElements();
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

    var target = discoverElements()[0];
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
