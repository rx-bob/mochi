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

  function fetchRequest(argsJson) {
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
      var responseValue = result;
      var bodyPromise = result && typeof result.text === "function" ? result.text() : "";
      return Promise.resolve(bodyPromise).then(function (bodyText) {
        return responseEnvelope(responseValue, bodyText);
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
