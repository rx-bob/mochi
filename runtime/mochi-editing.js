// Portable bound controls share one commit rule with the AppKit editor.
(function (global) {
  "use strict";

  var compositions = new WeakMap();

  function finish(target, edit, event, dispatch) {
    edit.committed = target.value;
    if (target.disabled || edit.initial === edit.committed) {
      if (edit.deferred !== undefined) target.value = edit.deferred;
      return;
    }
    dispatch(target, event);
  }

  function dispatchEdit(target, event, dispatch) {
    if (target.disabled) return;
    if (event.type !== "input" || target.getAttribute("data-mochi-portable-edit") !== "value") {
      dispatch(target, event);
      return;
    }
    var edit = compositions.get(target);
    if (event.isComposing || (edit && !edit.ended)) return;
    compositions.delete(target);
    if (!edit) dispatch(target, event);
    else if (edit.committed === undefined) finish(target, edit, event, dispatch);
    else if (target.value !== edit.committed) dispatch(target, event);
  }

  function deferEditValue(target, value) {
    var edit = compositions.get(target);
    if (!edit || edit.committed !== undefined) return false;
    edit.deferred = value;
    return true;
  }

  function attachEditor(root, dispatch) {
    root.addEventListener("compositionstart", function (event) {
      var target = event.target;
      if (target.nodeType === 1 && target.getAttribute("data-mochi-portable-edit") === "value" && !target.disabled) {
        compositions.set(target, { initial: target.value, ended: false });
      }
    });
    root.addEventListener("compositionend", function (event) {
      var target = event.target;
      var edit = compositions.get(target);
      if (!edit) return;
      edit.ended = true;
      // Some browsers end composition without a non-composing input.
      // Prefer that input when it arrives in the same turn.
      global.setTimeout(function () {
        if (compositions.get(target) !== edit || !target.isConnected || !root.contains(target)) return;
        finish(target, edit, { type: "input", target: target }, dispatch);
      }, 0);
    });
  }

  global.MochiHostAdapter.register({
    name: "editing",
    version: 1,
    attachEditor: attachEditor,
    dispatchEdit: dispatchEdit,
    deferEditValue: deferEditValue
  });
})(typeof window !== "undefined" ? window : globalThis);
