// FileMaker adapter.
// The plugin calls MaxxAdapter.execute(request) and waits for a standard result.
// request: { action, settings, payload }
//   catalog.search  payload { query, limit }  → items { code, name, unit, category, source }
//   orders.load     payload { offer_id }      → items { id, code, quantity, uom, category }
//   orders.export   payload { offer_id, items }
// result: { ok: true, items?, error? } or { ok: false, error }
(function (global) {
  "use strict";

  var AUTH = { location: "query", name: "apiKey" };

  function text(value) {
    return value == null ? "" : String(value).trim();
  }

  function parts(path) {
    if (!path) return [];
    return String(path).replace(/\[(\d+)\]/g, ".$1").split(".").filter(Boolean);
  }

  function get(source, path) {
    var current = source;
    var keys = parts(path);
    for (var i = 0; i < keys.length; i++) {
      if (current == null || !Object.prototype.hasOwnProperty.call(Object(current), keys[i])) return undefined;
      current = current[keys[i]];
    }
    return current;
  }

  function addQuery(url, name, value) {
    if (!name || value == null || value === "") return url;
    return url + (url.indexOf("?") >= 0 ? "&" : "?") + encodeURIComponent(name) + "=" + encodeURIComponent(value);
  }

  function postJson(url, body, apiKey) {
    var finalUrl = url;
    var headers = { "Content-Type": "application/json" };
    var payload = JSON.parse(JSON.stringify(body || {}));
    if (apiKey && AUTH.location === "header") headers[AUTH.name] = apiKey;
    else if (apiKey && AUTH.location === "body") payload[AUTH.name] = apiKey;
    else if (apiKey && AUTH.location !== "none") finalUrl = addQuery(finalUrl, AUTH.name, apiKey);

    return fetch(finalUrl, { method: "POST", headers: headers, body: JSON.stringify(payload) }).then(function (response) {
      return response.text().then(function (raw) {
        var data = null;
        try { data = raw ? JSON.parse(raw) : {}; } catch (_) { data = null; }
        if (!response.ok) {
          var paths = ["message", "error", "statusMessage", "scriptResult.message"];
          var detail = "";
          for (var i = 0; i < paths.length && !detail; i++) {
            var found = get(data, paths[i]);
            if (found) detail = String(found);
          }
          if (!detail && raw) detail = raw.slice(0, 200);
          throw new Error("HTTP " + response.status + " " + (response.statusText || "") + (detail ? " — " + detail : ""));
        }
        return data != null ? data : raw;
      });
    });
  }

  function readList(data, paths) {
    if (Array.isArray(data)) return data;
    for (var i = 0; i < paths.length; i++) {
      var value = get(data, paths[i]);
      if (Array.isArray(value)) return value;
    }
    return [];
  }

  function fail(error) {
    return { ok: false, error: error && error.message ? error.message : String(error || "Request failed.") };
  }

  function setting(settings, key) {
    return text(settings && settings[key]);
  }

  function offerLinesUrl(settings) {
    var explicit = setting(settings, "offer_lines_api_url");
    if (explicit) return explicit;
    var importUrl = setting(settings, "import_api_url");
    if (importUrl.indexOf("import-sketch") < 0) return "";
    return importUrl.replace("import-sketch", "get-offer-lines");
  }

  function catalogItem(raw, source) {
    var item = raw || {};
    return {
      code: text(item.code),
      name: text(item.name),
      unit: text(item.unit),
      category: text(item.category),
      source: text(item.source) || source
    };
  }

  function searchOnce(url, apiKey, query, limit, source) {
    var body = { query: query, resultLimit: limit };
    if (source === "subgroup") body.subgroup = 1;
    return postJson(url, body, apiKey).then(function (data) {
      return {
        source: source,
        items: readList(data, ["scriptResult.result", "results", "data"]).map(function (raw) {
          return catalogItem(raw, source);
        }),
        error: null
      };
    }).catch(function (error) {
      return { source: source, items: [], error: error };
    });
  }

  function mergeCatalog(products, subgroups, limit) {
    var seen = {};
    var merged = [];
    products.forEach(function (item) {
      var code = text(item.code);
      if (code) seen[code] = true;
      merged.push(item);
    });
    subgroups.forEach(function (item) {
      var code = text(item.code);
      if (code && seen[code]) return;
      if (code) seen[code] = true;
      merged.push(item);
    });
    return limit != null ? merged.slice(0, limit) : merged;
  }

  function endpointLabel(source) {
    return source === "subgroup" ? "Subgroup catalog" : "Product catalog";
  }

  function searchCatalog(settings, payload) {
    var query = text(payload && payload.query);
    if (!query) return Promise.resolve({ ok: true, items: [] });
    var url = setting(settings, "catalog_api_url");
    var apiKey = setting(settings, "api_key");
    if (!url || !apiKey) return Promise.resolve({ ok: false, error: "Set the catalog URL and API key in Plugin Settings." });
    var limit = payload && payload.limit != null ? payload.limit : 10;
    return Promise.all([
      searchOnce(url, apiKey, query, limit, "product"),
      searchOnce(url, apiKey, query, limit, "subgroup")
    ]).then(function (parts) {
      var products = [];
      var subgroups = [];
      var errors = [];
      parts.forEach(function (part) {
        if (part.error) {
          errors.push(endpointLabel(part.source) + " request failed: " + (part.error.message || "request failed."));
          return;
        }
        if (part.source === "subgroup") subgroups = part.items;
        else products = part.items;
      });
      var items = mergeCatalog(products, subgroups);
      if (!items.length && errors.length) return { ok: false, error: errors.join(" ") };
      var result = { ok: true, items: items };
      if (errors.length) result.error = errors.join(" ");
      return result;
    });
  }

  function orderItem(raw) {
    var item = raw || {};
    var quantity = item.quantity;
    if (typeof quantity !== "number") {
      var parsed = parseFloat(String(quantity == null ? "" : quantity).trim().replace(",", "."));
      quantity = isNaN(parsed) ? 0 : parsed;
    }
    return {
      id: text(item.id),
      code: text(item.code),
      quantity: quantity,
      uom: text(item.uom),
      category: text(item.category)
    };
  }

  function loadOrders(settings, payload) {
    var offerId = text(payload && payload.offer_id);
    if (!offerId) return Promise.resolve({ ok: false, error: "Offer ID is required." });
    var url = offerLinesUrl(settings);
    var apiKey = setting(settings, "api_key");
    if (!url || !apiKey) {
      return Promise.resolve({ ok: false, error: "Set the offer lines URL and API key in Plugin Settings." });
    }
    return postJson(url, { offer_id: offerId }, apiKey).then(function (data) {
      var items = readList(data, ["scriptResult.result", "result"]).map(orderItem).filter(function (item) {
        return item.code;
      });
      return { ok: true, items: items };
    }).catch(function (error) {
      return fail(error);
    });
  }

  function exportOrders(settings, payload) {
    var offerId = text(payload && payload.offer_id);
    if (!offerId) return Promise.resolve({ ok: false, error: "Offer ID is required." });
    var url = setting(settings, "import_api_url");
    var apiKey = setting(settings, "api_key");
    if (!url || !apiKey) return Promise.resolve({ ok: false, error: "Set the import URL and API key in Plugin Settings." });
    var items = (payload && Array.isArray(payload.items) ? payload.items : []).map(function (item) {
      var source = item || {};
      var mapped = {
        code: text(source.code),
        quantity: source.quantity,
        uom: text(source.uom),
        category: text(source.category)
      };
      var id = text(source.id);
      if (id) mapped.id = id;
      return mapped;
    });
    return postJson(url, { offer_id: offerId, items: items }, apiKey).then(function () {
      return { ok: true };
    }).catch(function (error) {
      return fail(error);
    });
  }

  function execute(request) {
    var action = request && request.action;
    var settings = (request && request.settings) || {};
    var payload = (request && request.payload) || {};
    if (action === "catalog.search") return searchCatalog(settings, payload);
    if (action === "orders.load") return loadOrders(settings, payload);
    if (action === "orders.export") return exportOrders(settings, payload);
    return Promise.resolve({ ok: false, error: "Unknown adapter action." });
  }

  global.MaxxAdapter = { execute: execute };
})(window);
