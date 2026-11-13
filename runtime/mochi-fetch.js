(function (global) {
  "use strict";

  var controllers = new Map();

  function messageOf(error) {
    return error && error.message ? error.message : String(error || "fetch failed");
  }

  function responseEnvelope(response, body) {
    var status = response && typeof response.status === "number" ? response.status : 0;
    var ok = response && typeof response.ok === "boolean"
      ? response.ok
      : status >= 200 && status < 300;
    var contentType = "";
    try {
      contentType = response && response.headers && response.headers.get
        ? response.headers.get("content-type") || "" : "";
    } catch (_) {}
    var data = null;
    if (body && (!contentType || contentType.indexOf("json") !== -1)) {
      try { data = JSON.parse(body); } catch (_) {}
    }
    var error = null;
    if (!ok) error = "HTTP " + status + (response && response.statusText ? " " + response.statusText : "");
    return { status: status, ok: ok, body: body || "", data: data, error: error };
  }

  function responseTextBounded(response, maxBytes) {
    var declaredLength = Number(response && response.headers && response.headers.get
      ? response.headers.get("content-length") : 0);
    if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
      return Promise.reject(new Error("response exceeds configured byte limit " + maxBytes));
    }
    var body = response && response.body;
    if (!body || typeof body.getReader !== "function") {
      return Promise.reject(new Error("bounded response reader is unavailable"));
    }
    var reader = body.getReader();
    var chunks = [];
    var total = 0;
    function read() {
      return reader.read().then(function (result) {
        if (result.done) {
          var bytes = new Uint8Array(total);
          var offset = 0;
          chunks.forEach(function (chunk) {
            bytes.set(chunk, offset);
            offset += chunk.length;
          });
          return new TextDecoder("utf-8").decode(bytes);
        }
        var chunk = result.value instanceof Uint8Array
          ? result.value
          : new Uint8Array(result.value);
        total += chunk.length;
        if (total > maxBytes) {
          return Promise.resolve(reader.cancel()).then(function () {
            throw new Error("response exceeds configured byte limit " + maxBytes);
          });
        }
        chunks.push(chunk);
        return read();
      });
    }
    return read().finally(function () {
      try { reader.releaseLock(); } catch (_) {}
    });
  }

  function fetchRequest(argsJson, limits) {
    var maxResponseBytes = limits && limits.response_bytes;
    if (!Number.isSafeInteger(maxResponseBytes) || maxResponseBytes <= 0) {
      return Promise.resolve({
        status: 0, ok: false, body: "", data: null,
        error: "network capability has no valid response byte limit"
      });
    }
    var request = JSON.parse(argsJson || "{}");
    var options = request.options && typeof request.options === "object" ? request.options : {};
    var fetchOptions = Object.assign({}, options);
    delete fetchOptions.key;
    delete fetchOptions.request_key;
    var body = fetchOptions.body;
    var plainBody = body && typeof body === "object" &&
      (Array.isArray(body) || Object.getPrototypeOf(body) === Object.prototype ||
        Object.getPrototypeOf(body) === null);
    if (plainBody) {
      fetchOptions.body = JSON.stringify(body);
      var headers = fetchOptions.headers && typeof fetchOptions.headers === "object"
        ? Object.assign({}, fetchOptions.headers) : {};
      var hasContentType = Object.keys(headers).some(function (name) {
        return name.toLowerCase() === "content-type";
      });
      if (!hasContentType) headers["content-type"] = "application/json";
      fetchOptions.headers = headers;
    }

    var key = String(request.request_key || "");
    var controller = typeof global.AbortController === "function"
      ? new global.AbortController() : null;
    if (controller) fetchOptions.signal = controller.signal;
    if (key && controller) controllers.set(key, controller);
    if (typeof global.fetch !== "function") {
      if (key) controllers.delete(key);
      return Promise.resolve({ status: 0, ok: false, body: "", data: null, error: "fetch unavailable" });
    }

    var response;
    try {
      response = global.fetch(request.url, fetchOptions);
    } catch (error) {
      if (key) controllers.delete(key);
      return Promise.resolve({ status: 0, ok: false, body: "", data: null, error: messageOf(error) });
    }
    return Promise.resolve(response).then(function (result) {
      return responseTextBounded(result, maxResponseBytes).then(function (bodyText) {
        return responseEnvelope(result, bodyText);
      }, function (error) {
        return {
          status: result && typeof result.status === "number" ? result.status : 0,
          ok: false,
          body: "",
          data: null,
          error: messageOf(error)
        };
      });
    }, function (error) {
      return { status: 0, ok: false, body: "", data: null, error: messageOf(error) };
    }).finally(function () {
      if (key && controllers.get(key) === controller) controllers.delete(key);
    });
  }

  global.MochiHostAdapter.register({
    name: "network",
    version: 1,
    sync: {
      cancel: function (requestKey) {
        var controller = controllers.get(String(requestKey));
        if (controller) {
          controller.abort();
          controllers.delete(String(requestKey));
        }
        return true;
      }
    },
    async: { fetch: fetchRequest }
  });
})(globalThis);
