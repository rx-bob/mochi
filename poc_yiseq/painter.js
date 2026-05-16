// painter.js — Mochi DOM painter (~1KB)
// Efficiently patches the DOM from HTML strings rendered by Ruby.
// Future: read binary opcodes from shared memory instead of HTML strings.

(function() {
  'use strict';

  // Morph-style DOM patching: update existing elements in-place
  // to preserve event listeners, focus state, and scroll position.
  function paint(container, html) {
    // Create a temporary container to parse the new HTML
    var tmp = document.createElement('div');
    tmp.innerHTML = html;

    // Simple strategy: if structure is same, patch attributes + text.
    // Otherwise, replace innerHTML (fast path for initial render).
    if (!container.firstElementChild) {
      container.innerHTML = html;
      return;
    }

    // Patch existing DOM
    patchChildren(container, tmp);
  }

  function patchChildren(target, source) {
    var tc = Array.from(target.childNodes);
    var sc = Array.from(source.childNodes);

    // Remove extra children
    for (var i = sc.length; i < tc.length; i++) {
      target.removeChild(tc[i]);
    }

    for (var i = 0; i < sc.length; i++) {
      if (i >= tc.length) {
        // Append new child
        target.appendChild(sc[i].cloneNode(true));
      } else if (tc[i].nodeType !== sc[i].nodeType ||
                 tc[i].nodeName !== sc[i].nodeName) {
        // Replace incompatible node
        target.replaceChild(sc[i].cloneNode(true), tc[i]);
      } else if (tc[i].nodeType === 3) {
        // Text node — update content
        if (tc[i].textContent !== sc[i].textContent) {
          tc[i].textContent = sc[i].textContent;
        }
      } else if (tc[i].nodeType === 1) {
        // Element — patch attributes then recurse
        patchAttributes(tc[i], sc[i]);
        patchChildren(tc[i], sc[i]);
      }
    }
  }

  function patchAttributes(target, source) {
    // Remove stale attributes
    var targetAttrs = target.attributes;
    for (var i = targetAttrs.length - 1; i >= 0; i--) {
      var name = targetAttrs[i].name;
      if (!source.hasAttribute(name)) {
        target.removeAttribute(name);
      }
    }
    // Set/update attributes
    var sourceAttrs = source.attributes;
    for (var i = 0; i < sourceAttrs.length; i++) {
      var name = sourceAttrs[i].name;
      var val = sourceAttrs[i].value;
      if (target.getAttribute(name) !== val) {
        target.setAttribute(name, val);
      }
    }
  }

  window.MochiPainter = { paint: paint };
})();
