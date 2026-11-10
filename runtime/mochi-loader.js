// mochi-loader.js - static Custom Element + Shadow DOM loader for mochi-gvm.
(function (global) {
  "use strict";

  var RITE_HEADER = new Uint8Array([0x52, 0x49, 0x54, 0x45, 0x30, 0x34, 0x30, 0x30, 0x00, 0x00]);
  var COMPONENT_DIR = "components/";
  var DEFAULT_MANIFEST = "mochi-manifest.json";

  var state = {
    manifest: null,
    manifestUrl: null,
    modulePromise: null,
    irepPromises: new Map(),
    internCache: new Map(),
    tags: new Set()
  };

  function absoluteUrl(path, base) {
    return new URL(path, base).href;
  }

  function runtimeUrl(manifest, manifestUrl) {
    return absoluteUrl(manifest.wasm_file || "mochi-gvm.wasm", manifestUrl);
  }

  function jsUrl(manifest, manifestUrl) {
    if (manifest.js_file) return absoluteUrl(manifest.js_file, manifestUrl);
    var wasm = manifest.wasm_file || "mochi-gvm.wasm";
    return absoluteUrl(wasm.replace(/\.wasm($|\?)/, ".js$1"), manifestUrl);
  }

  function chiUrl(component, manifestUrl) {
    var path = component.chi_file || (component.tag_name + ".chi");
    if (path.indexOf("/") === -1) path = COMPONENT_DIR + path;
    return absoluteUrl(path, manifestUrl);
  }

  function encode(text) {
    return new TextEncoder().encode(text);
  }

  function decode(bytes) {
    return new TextDecoder().decode(bytes);
  }

  function lastError(module) {
    if (!module._mochi_last_error_offset || !module._mochi_last_error_len) return "";
    var offset = module._mochi_last_error_offset();
    var length = module._mochi_last_error_len();
    if (!offset || length <= 0) return "";
    return decode(module.HEAPU8.subarray(offset, offset + length));
  }

  function withUtf8(module, text, callback) {
    var bytes = encode(text);
    var malloc = module._malloc || module._mochi_malloc;
    var free = module._free || module._mochi_free;
    var pointer = malloc(bytes.length + 1);

    if (!pointer) throw new Error("mochi-gvm: out of memory");

    module.HEAPU8.set(bytes, pointer);
    module.HEAPU8[pointer + bytes.length] = 0;

    try {
      return callback(pointer, bytes.length);
    } finally {
      if (free) free(pointer);
    }
  }

  function intern(module, name) {
    if (!name) return 0;
    if (state.internCache.has(name)) return state.internCache.get(name);

    var symbol = withUtf8(module, name, function (pointer, length) {
      return module._mochi_intern(pointer, length);
    });

    if (!symbol) throw new Error("mochi-gvm: failed to intern " + name);
    state.internCache.set(name, symbol);
    return symbol;
  }

  function loadScript(url) {
    return new Promise(function (resolve, reject) {
      var script = global.document.createElement("script");
      script.src = url;
      script.async = true;
      script.onload = function () { resolve(); };
      script.onerror = function () { reject(new Error("mochi-loader: failed to load " + url)); };
      global.document.head.appendChild(script);
    });
  }

  async function loadRuntime(manifest, manifestUrl) {
    if (state.modulePromise) return state.modulePromise;

    state.modulePromise = (async function () {
      var wasmUrl = runtimeUrl(manifest, manifestUrl);
      var factory = loader.moduleFactory || global.MochiModule;

      if (!factory) {
        await loadScript(jsUrl(manifest, manifestUrl));
        factory = global.MochiModule;
      }

      if (!factory) throw new Error("mochi-loader: MochiModule factory not found");

      var module = typeof factory === "function"
        ? await factory({
            locateFile: function (path) {
              return /\.wasm($|\?)/.test(path) ? wasmUrl : absoluteUrl(path, manifestUrl);
            }
          })
        : factory;

      if (!module || !module._mochi_init_runtime) {
        throw new Error("mochi-loader: invalid mochi-gvm module");
      }

      if (module._mochi_init_runtime() !== 0) {
        throw new Error("mochi-loader: runtime init failed: " + lastError(module));
      }

      return module;
    })().catch(function (error) {
      state.modulePromise = null;
      throw error;
    });

    return state.modulePromise;
  }

  async function loadComponentClass(component, manifest, manifestUrl) {
    var url = chiUrl(component, manifestUrl);
    var existing = state.irepPromises.get(url);
    if (existing) return existing;

    var promise = (async function () {
      var module = await loadRuntime(manifest, manifestUrl);
      var response = await global.fetch(url);
      if (!response.ok) throw new Error("mochi-loader: failed to fetch " + url);

      var stripped = new Uint8Array(await response.arrayBuffer());
      var bytes = new Uint8Array(RITE_HEADER.length + stripped.length);
      bytes.set(RITE_HEADER, 0);
      bytes.set(stripped, RITE_HEADER.length);

      var malloc = module._malloc || module._mochi_malloc;
      var free = module._free || module._mochi_free;
      var pointer = malloc(bytes.length);
      if (!pointer) throw new Error("mochi-gvm: out of memory");

      try {
        module.HEAPU8.set(bytes, pointer);
        if (module._mochi_load_irep(pointer, bytes.length) !== 0) {
          throw new Error("mochi-loader: load_irep failed for " + component.class_name + ": " + lastError(module));
        }
      } finally {
        if (free) free(pointer);
      }

      return module;
    })();

    state.irepPromises.set(url, promise);
    promise.catch(function () { state.irepPromises.delete(url); });
    return promise;
  }

  async function mountInstance(component, manifest, manifestUrl) {
    var module = await loadComponentClass(component, manifest, manifestUrl);
    var instance;

    withUtf8(module, component.class_name, function (pointer, length) {
      instance = module._mochi_mount_component(pointer, length);
    });

    if (instance === 0 || instance === 0n) {
      throw new Error("mochi-loader: mount failed for " + component.class_name + ": " + lastError(module));
    }

    (component.bindings || []).forEach(function (binding) {
      var symbol = intern(module, binding.getter_sym);
      if (module._mochi_register_binding(instance, binding.id, symbol) !== 0) {
        throw new Error("mochi-loader: binding registration failed for " + binding.getter_sym + ": " + lastError(module));
      }
    });

    var mounted = intern(module, "mounted");
    if (mounted) module._mochi_dispatch_event(instance, mounted);
    if (typeof loader.applyPatches === "function") await loader.applyPatches(instance, module);

    return { module: module, instance: instance };
  }

  function resolveTarget(root, path) {
    var node = root;
    for (var i = 0; i < path.length; i++) {
      if (!node) return null;
      node = node.childNodes[path[i]];
    }
    return node || null;
  }

  function eventTarget(event, root, eventName) {
    var attribute = "data-mochi-" + eventName;
    var node = event.target;
    while (node && node !== root) {
      if (node.nodeType === 1 && node.hasAttribute(attribute)) return node;
      node = node.parentNode;
    }
    return null;
  }

  function defineComponent(component, manifestUrl) {
    var tag = component.tag_name;
    if (!tag || state.tags.has(tag) || global.customElements.get(tag)) return;

    var template = global.document.createElement("template");
    template.innerHTML = component.html_template || "";
    var bindings = component.bindings || [];
    var eventNames = [];
    (component.events || []).forEach(function (event) {
      if (event.event && eventNames.indexOf(event.event) === -1) eventNames.push(event.event);
    });

    var Element = class extends global.HTMLElement {
      constructor() {
        super();
        this.bindingTargets = {};
        this.bindingData = {};
        this.refs = this.bindingTargets;
        this._mochiComponent = component;
        this._mochiManifestUrl = manifestUrl;
        this._mochiReady = null;
        this._mochiModule = null;
        this._mochiInstance = null;
      }

      connectedCallback() {
        if (this.shadowRoot) return;

        var root = this.attachShadow({ mode: "open" });
        var style = global.document.createElement("style");
        style.textContent = component.css || "";
        root.appendChild(style);

        var fragment = template.content.cloneNode(true);
        this._resolveBindings(fragment);
        root.appendChild(fragment);
        this._attachEvents(root);

        var element = this;
        this._mochiReady = mountInstance(component, state.manifest, manifestUrl).then(function (mounted) {
          element._mochiModule = mounted.module;
          element._mochiInstance = mounted.instance;
          return mounted;
        }).catch(function (error) {
          element.mochiError = error;
          console.error("[mochi] " + tag + " mount failed", error);
          throw error;
        });
      }

      _resolveBindings(root) {
        for (var i = 0; i < bindings.length; i++) {
          var binding = bindings[i];
          var node = resolveTarget(root, binding.path || []);
          if (!node) {
            throw new Error("mochi-loader: missing binding path [" + (binding.path || []).join(", ") + "] for " + tag);
          }
          this.bindingTargets[binding.id] = node;
          this.bindingData[binding.id] = binding;
        }
      }

      _attachEvents(root) {
        var element = this;
        eventNames.forEach(function (eventName) {
          root.addEventListener(eventName, function (event) {
            var target = eventTarget(event, root, eventName);
            if (target) element._dispatch(target, event);
          });
        });
      }

      _dispatch(target, event) {
        var element = this;
        var method = target.getAttribute("data-mochi-" + event.type);
        if (!method || !this._mochiReady) return;

        this._mochiReady.then(function (mounted) {
          var symbol = intern(mounted.module, method);
          if (mounted.module._mochi_dispatch_event(mounted.instance, symbol) !== 1) {
            throw new Error("mochi-loader: event dispatch failed for " + method + ": " + lastError(mounted.module));
          }
          if (typeof loader.applyPatches === "function") {
            return loader.applyPatches(mounted.instance, mounted.module);
          }
        }).catch(function (error) {
          element.mochiError = error;
          console.error("[mochi] " + tag + " event failed", error);
        });
      }
    };

    state.tags.add(tag);
    global.customElements.define(tag, Element);
  }

  async function boot(url, options) {
    options = options || {};
    if (options.moduleFactory) loader.moduleFactory = options.moduleFactory;

    var manifestUrl = absoluteUrl(url || DEFAULT_MANIFEST, global.document.baseURI);
    if (state.manifestUrl === manifestUrl && state.manifest) return state.manifest;

    var response = await global.fetch(manifestUrl);
    if (!response.ok) throw new Error("mochi-loader: failed to fetch " + manifestUrl);

    var manifest = await response.json();
    if (Array.isArray(manifest)) manifest = { components: manifest };
    if (!manifest.components) manifest.components = [];

    state.manifest = manifest;
    state.manifestUrl = manifestUrl;

    for (var i = 0; i < manifest.components.length; i++) {
      defineComponent(manifest.components[i], manifestUrl);
    }

    return manifest;
  }

  var loader = {
    boot: boot,
    moduleFactory: null,
    applyPatches: null,
    get manifest() { return state.manifest; },
    get components() { return state.manifest ? state.manifest.components : []; }
  };

  global.MochiLoader = loader;
  if (typeof module === "object" && module.exports) module.exports = loader;

  if (global.document && global.document.currentScript) {
    var script = global.document.currentScript;
    if (script.dataset.mochiAutoBoot !== "false") {
      var manifestPath = script.dataset.mochiManifest || DEFAULT_MANIFEST;
      var start = function () {
        boot(manifestPath).catch(function (error) {
          console.error("[mochi] loader boot failed", error);
        });
      };
      if (global.document.readyState === "loading") {
        global.document.addEventListener("DOMContentLoaded", start, { once: true });
      } else {
        start();
      }
    }
  }
})(typeof globalThis !== "undefined" ? globalThis : window);
