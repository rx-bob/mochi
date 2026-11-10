(function () {
  'use strict';

  var logEl = document.getElementById('event-log');
  var shadowView = document.getElementById('shadow-view');
  var runtimeStatus = document.getElementById('runtime-status');
  var myCounterHost = null;
  var entries = [];
  var previousCount = null;
  var startedAt = Date.now();

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, function (char) {
      return {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;',
      }[char];
    });
  }

  function timestamp() {
    var elapsed = ((Date.now() - startedAt) / 1000).toFixed(2);
    return '+' + elapsed + 's';
  }

  function appendLog(kind, message, ok) {
    entries.push({
      time: timestamp(),
      kind: kind,
      message: message,
      ok: Boolean(ok),
    });
    if (entries.length > 40) entries.shift();

    logEl.innerHTML = entries.map(function (entry) {
      var kindClass = entry.ok ? 'tag ok' : 'tag';
      return '<span class="time">' + escapeHtml(entry.time) + '</span> ' +
        '<span class="' + kindClass + '">' + escapeHtml(entry.kind) + '</span> ' +
        escapeHtml(entry.message);
    }).join('\n');
    logEl.scrollTop = logEl.scrollHeight;
  }

  function formatBytes(bytes) {
    if (typeof bytes !== 'number' || !isFinite(bytes)) return '—';
    if (bytes < 1024) return bytes + ' B';
    return (bytes / 1024).toFixed(1) + ' KB';
  }

  async function measureArtifact(url) {
    var response = await fetch(url);
    if (!response.ok) throw new Error(url + ': HTTP ' + response.status);
    var buffer = await response.arrayBuffer();
    var gzip = null;

    if (typeof CompressionStream !== 'undefined') {
      try {
        var stream = new Blob([buffer]).stream().pipeThrough(new CompressionStream('gzip'));
        gzip = (await new Response(stream).arrayBuffer()).byteLength;
      } catch (_) {
        gzip = null;
      }
    }

    return { raw: buffer.byteLength, gzip: gzip };
  }

  async function loadArtifactMetrics() {
    try {
      var results = await Promise.all([
        measureArtifact('/poc_yiseq/my_counter.chi'),
        measureArtifact('/poc_yiseq/mochi.wasm'),
      ]);
      var chi = results[0];
      var wasm = results[1];

      document.getElementById('metric-chi').textContent = formatBytes(chi.raw);
      document.getElementById('metric-wasm').textContent = formatBytes(wasm.raw);
      document.getElementById('metric-wasm-gz').textContent =
        wasm.gzip === null ? 'unavailable' : formatBytes(wasm.gzip);
    } catch (error) {
      appendLog('metrics', 'artifact measurement failed: ' + error.message);
    }
  }

  async function loadSource() {
    try {
      var response = await fetch('/poc_yiseq/my_counter.rb');
      if (!response.ok) throw new Error('HTTP ' + response.status);
      document.getElementById('source-view').textContent = await response.text();
    } catch (error) {
      document.getElementById('source-view').textContent =
        'Could not load my_counter.rb: ' + error.message;
    }
  }

  function updateTelemetry(host, reason) {
    var root = host.shadowRoot;
    if (!root) return;

    var wrapper = root.querySelector('.wrapper');
    var heading = root.querySelector('h1');
    var style = root.querySelector('style[data-mochi-style]');
    var actionButtons = root.querySelectorAll('[data-action]');
    var count = heading ? heading.textContent.trim() : '—';
    var mounted = wrapper && wrapper.getAttribute('data-mounted') === '1';

    document.getElementById('live-tag').textContent = host.localName;
    document.getElementById('live-mounted').textContent = mounted ? 'yes' : 'no';
    document.getElementById('live-count').textContent = count;
    document.getElementById('live-css').textContent =
      style ? formatBytes(style.textContent.length) : 'none';
    document.getElementById('live-shadow').textContent = 'open';
    document.getElementById('live-actions').textContent = actionButtons.length + ' bound';

    var mountedEl = document.getElementById('live-mounted');
    var shadowEl = document.getElementById('live-shadow');
    var countEl = document.getElementById('live-count');
    mountedEl.classList.toggle('ok', mounted);
    shadowEl.classList.toggle('ok', true);
    countEl.classList.toggle('ok', count !== '—');

    shadowView.textContent = wrapper
      ? wrapper.outerHTML.trim()
      : 'waiting for .wrapper in shadow root…';

    if (previousCount !== null && count !== previousCount) {
      appendLog('render', count, true);
    }
    previousCount = count;

    if (reason === 'initial') {
      runtimeStatus.textContent = 'hydrated';
      runtimeStatus.classList.add('ready');
      appendLog('runtime', 'MyCounter shadow root attached', true);
      appendLog('lifecycle', 'mounted → data-mounted="' + (mounted ? '1' : '0') + '"', mounted);
      appendLog('css', 'shadow style applied' + (style ? ' · ' + formatBytes(style.textContent.length) : ''), Boolean(style));
      appendLog('render', count, true);
    }
  }

  function watchMyCounter() {
    var host = document.querySelector('my-counter');
    if (!host) {
      setTimeout(watchMyCounter, 80);
      return;
    }

    myCounterHost = host;

    if (!host.shadowRoot) {
      setTimeout(watchMyCounter, 80);
      return;
    }

    updateTelemetry(host, 'initial');

    var observer = new MutationObserver(function () {
      updateTelemetry(host, 'mutation');
    });
    observer.observe(host.shadowRoot, {
      subtree: true,
      childList: true,
      attributes: true,
      characterData: true,
    });

    host.shadowRoot.addEventListener('click', function (event) {
      var button = event.target.closest('[data-action]');
      if (button) {
        appendLog('event', 'click → ' + button.getAttribute('data-action'));
      }
    }, true);
  }

  function wireDemoActions() {
    var buttons = document.querySelectorAll('[data-demo-action]');
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].addEventListener('click', function () {
        var action = this.getAttribute('data-demo-action');
        if (action === 'reload') {
          window.location.reload();
          return;
        }

        if (!myCounterHost || !myCounterHost.shadowRoot) {
          appendLog('error', 'MyCounter is not hydrated yet');
          return;
        }

        var target = myCounterHost.shadowRoot.querySelector(
          'button[data-action="' + action + '"]'
        );
        if (!target) {
          appendLog('error', 'no shadow button for action: ' + action);
          return;
        }

        appendLog('demo', 'external dispatch → ' + action);
        target.click();
      });
    }

    document.getElementById('clear-log').addEventListener('click', function () {
      entries = [];
      appendLog('log', 'cleared');
    });
  }

  window.addEventListener('error', function (event) {
    appendLog('error', event.message || 'unknown browser error');
  });

  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason && event.reason.message
      ? event.reason.message
      : String(event.reason);
    appendLog('error', reason);
  });

  appendLog('boot', 'demo page ready');
  appendLog('load', 'mochi.js bundle loaded; waiting for MyCounter shadow root …');
  wireDemoActions();
  watchMyCounter();
  loadSource();
  loadArtifactMetrics();

  setTimeout(function () {
    if (!myCounterHost || !myCounterHost.shadowRoot) {
      runtimeStatus.textContent = 'not hydrated';
      appendLog('error', 'MyCounter did not hydrate within 12s');
    }
  }, 12000);
})();
