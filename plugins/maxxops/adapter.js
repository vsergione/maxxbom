// MaxxOps adapter. Talks to the dbAPI data plane used by MaxxOps.
// The plugin calls MaxxAdapter.execute(request) and waits for a standard result.
// request: { action, settings, payload }
//   catalog.search  payload { query, limit }  → items { code, name, unit, category, source }
//   orders.load     payload { offer_id }      → items { id, code, quantity, uom, category }
//   orders.export   payload { offer_id, items }
// offer_id is the offer number (documents series + number, as shown in MaxxOps)
// or the numeric order id for a draft that has no number yet.
// A line is written only while the order is DRAFT or ON_HOLD.
// code is the product ean_sku, or product_code when the SKU is empty.
// Auth is POST {api}/auth/client with form fields token and secret (API client, not a user login).
// category is stored on the line (attrs.maxxbom.category) so a later load matches it.
// result: { ok: true, items?, error? } or { ok: false, error }
(function (global) {
  "use strict";

  var EDITABLE = { DRAFT: true, ON_HOLD: true };
  var session = { key: "", token: "", exp: 0 };

  function text(value) {
    return value == null ? "" : String(value).trim();
  }

  function setting(settings, key) {
    return text(settings && settings[key]);
  }

  function fail(error) {
    return { ok: false, error: error && error.message ? error.message : String(error || "Request failed.") };
  }

  function numberOf(value) {
    if (typeof value === "number") return isNaN(value) ? 0 : value;
    var parsed = parseFloat(text(value).replace(",", "."));
    return isNaN(parsed) ? 0 : parsed;
  }

  function joinUrl(base, path) {
    return String(base).replace(/\/+$/, "") + "/" + String(path).replace(/^\/+/, "");
  }

  function addQuery(url, name, value) {
    if (!name || value == null || value === "") return url;
    return url + (url.indexOf("?") >= 0 ? "&" : "?") + encodeURIComponent(name) + "=" + encodeURIComponent(value);
  }

  function filterValue(value) {
    return String(value).replace(/\\/g, "\\\\").replace(/,/g, "\\,").replace(/\|/g, "\\|").replace(/\)/g, "\\)");
  }

  function hasErrors(data) {
    if (!data || data.errors == null) return false;
    if (Array.isArray(data.errors)) return data.errors.length > 0;
    if (typeof data.errors === "object") return Object.keys(data.errors).length > 0;
    return true;
  }

  function apiMessage(data, raw) {
    if (data && typeof data === "object") {
      if (typeof data.message === "string" && data.message.trim()) return data.message.trim();
      if (typeof data.error === "string" && data.error.trim()) return data.error.trim();
      var errors = data.errors;
      if (errors && typeof errors === "object" && !Array.isArray(errors)) {
        if (typeof errors.message === "string" && errors.message.trim()) return errors.message.trim();
      }
      if (Array.isArray(errors)) {
        var parts = [];
        for (var i = 0; i < errors.length; i++) {
          var item = errors[i];
          if (typeof item === "string" && item.trim()) parts.push(item.trim());
          else if (item && typeof item === "object") {
            var message = item.detail || item.message || item.title;
            if (typeof message === "string" && message.trim()) parts.push(message.trim());
          }
        }
        if (parts.length) return parts.join(" ");
      }
    }
    return raw ? String(raw).slice(0, 200) : "";
  }

  function request(method, url, body, token, contentType) {
    var headers = { Accept: "application/vnd.api+json, application/json" };
    if (token) headers.Authorization = "Bearer " + token;
    var payload;
    if (body != null) {
      headers["Content-Type"] = contentType || "application/vnd.api+json";
      payload = typeof body === "string" ? body : JSON.stringify(body);
    }
    return fetch(url, { method: method, headers: headers, body: payload }).then(function (response) {
      return response.text().then(function (raw) {
        var data = null;
        try { data = raw ? JSON.parse(raw) : {}; } catch (_) { data = null; }
        if (!response.ok || hasErrors(data)) {
          var detail = apiMessage(data, raw);
          var error = new Error("HTTP " + response.status + (detail ? " — " + detail : ""));
          error.status = response.status;
          throw error;
        }
        return data != null ? data : {};
      });
    });
  }

  function jwtExp(token) {
    var parts = String(token || "").split(".");
    if (parts.length < 2) return 0;
    try {
      var padded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
      while (padded.length % 4) padded += "=";
      var json = JSON.parse(atob(padded));
      return typeof json.exp === "number" ? json.exp : 0;
    } catch (_) {
      return 0;
    }
  }

  function login(base, clientToken, clientSecret) {
    var url = joinUrl(base, "/auth/client");
    var form = "token=" + encodeURIComponent(clientToken) + "&secret=" + encodeURIComponent(clientSecret);
    return request("POST", url, form, "", "application/x-www-form-urlencoded").then(function (data) {
      var token = data && data.access_token ? String(data.access_token) : "";
      if (!token) throw new Error("Client login did not return an access token.");
      return token;
    }).catch(function (error) {
      if (error && error.status === 401) throw new Error("MaxxOps rejected the client token or secret.");
      var message = error && error.message ? error.message : "Client login failed.";
      throw new Error(url + " failed: " + message);
    });
  }

  function connection(settings) {
    var base = setting(settings, "api_base_url").replace(/\/+$/, "");
    var clientToken = setting(settings, "client_token");
    var clientSecret = setting(settings, "client_secret");
    var companyId = setting(settings, "company_id");
    if (!base || !clientToken || !clientSecret || !companyId) {
      return Promise.resolve({ ok: false, error: "Set the API URL, client token, client secret, and company ID in Plugin Settings." });
    }
    if (!/^\d+$/.test(companyId)) return Promise.resolve({ ok: false, error: "Company ID must be a number." });
    var key = base + "\n" + clientToken + "\n" + companyId;
    var now = Math.floor(Date.now() / 1000);
    if (session.key === key && session.token && session.exp > now + 60) {
      return Promise.resolve({ ok: true, base: base, token: session.token, companyId: companyId, clientToken: clientToken, clientSecret: clientSecret });
    }
    return login(base, clientToken, clientSecret).then(function (token) {
      var exp = jwtExp(token);
      session = { key: key, token: token, exp: exp || now + 300 };
      return { ok: true, base: base, token: token, companyId: companyId, clientToken: clientToken, clientSecret: clientSecret };
    }).catch(function (error) {
      session = { key: "", token: "", exp: 0 };
      return fail(error);
    });
  }

  function call(conn, method, url, body) {
    return request(method, url, body, conn.token).catch(function (error) {
      if (!error || error.status !== 401) throw error;
      session = { key: "", token: "", exp: 0 };
      return login(conn.base, conn.clientToken, conn.clientSecret).then(function (token) {
        var exp = jwtExp(token);
        session = {
          key: conn.base + "\n" + conn.clientToken + "\n" + conn.companyId,
          token: token,
          exp: exp || Math.floor(Date.now() / 1000) + 300
        };
        conn.token = token;
        return request(method, url, body, token);
      });
    });
  }

  function dataUrl(conn, path) {
    return joinUrl(conn.base, "/data/" + String(path).replace(/^\/+/, ""));
  }

  function readData(data) {
    if (!data || data.data == null) return [];
    return Array.isArray(data.data) ? data.data : [data.data];
  }

  function attr(resource, name) {
    var attributes = resource && resource.attributes;
    if (!attributes || !Object.prototype.hasOwnProperty.call(attributes, name)) return undefined;
    return attributes[name];
  }

  function relId(resource, name) {
    var rel = resource && resource.relationships && resource.relationships[name];
    if (!rel) {
      var direct = attr(resource, name);
      return direct == null ? "" : text(direct);
    }
    if (rel.id != null) return text(rel.id);
    var linked = rel.data;
    if (Array.isArray(linked)) return linked.length && linked[0] && linked[0].id != null ? text(linked[0].id) : "";
    if (linked && linked.id != null) return text(linked.id);
    var fallback = attr(resource, name);
    return fallback == null ? "" : text(fallback);
  }

  function indexIncluded(data) {
    var map = {};
    var list = data && Array.isArray(data.included) ? data.included : [];
    list.forEach(function (item) {
      if (!item || item.type == null || item.id == null) return;
      map[item.type + ":" + item.id] = item;
    });
    return map;
  }

  function included(map, type, id) {
    return id ? map[type + ":" + id] || null : null;
  }

  function parseAttrs(raw) {
    if (!raw) return {};
    if (typeof raw === "object") return raw;
    try {
      var parsed = JSON.parse(raw);
      return parsed && typeof parsed === "object" ? parsed : {};
    } catch (_) {
      return null;
    }
  }

  function storedCategory(attrs) {
    if (!attrs || !attrs.maxxbom || !Object.prototype.hasOwnProperty.call(attrs.maxxbom, "category")) return null;
    return text(attrs.maxxbom.category);
  }

  function attrsWithCategory(attrs, category) {
    var next = {};
    var source = attrs && typeof attrs === "object" ? attrs : {};
    Object.keys(source).forEach(function (key) { next[key] = source[key]; });
    var bom = {};
    if (next.maxxbom && typeof next.maxxbom === "object") {
      Object.keys(next.maxxbom).forEach(function (key) { bom[key] = next.maxxbom[key]; });
    }
    bom.category = category;
    next.maxxbom = bom;
    return JSON.stringify(next);
  }

  function getPage(conn, url, offset, limit) {
    var paged = url + (url.indexOf("?") >= 0 ? "&" : "?") + "page[offset]=" + offset + "&page[limit]=" + limit;
    return call(conn, "GET", paged, null);
  }

  function getAll(conn, url) {
    var items = [];
    var map = {};
    var offset = 0;
    var limit = 100;
    var seenPage = {};

    function mergeIncluded(data) {
      var extra = indexIncluded(data);
      Object.keys(extra).forEach(function (key) { map[key] = extra[key]; });
    }

    function next() {
      return getPage(conn, url, offset, limit).then(function (data) {
        var chunk = readData(data);
        var marker = chunk.length ? text(chunk[0].id) || text(attr(chunk[0], "id")) : "";
        if (!chunk.length || (marker && seenPage[marker])) return { items: items, included: map };
        if (marker) seenPage[marker] = true;
        items = items.concat(chunk);
        mergeIncluded(data);
        if (chunk.length < limit || offset >= 5000) return { items: items, included: map };
        offset += chunk.length;
        return next();
      });
    }

    return next();
  }

  function productCode(resource) {
    return text(attr(resource, "ean_sku")) || text(attr(resource, "product_code"));
  }

  function productUnit(resource) {
    return text(attr(resource, "uom")) || relId(resource, "uom");
  }

  function categoryName(map, resource) {
    var id = relId(resource, "category_id");
    var category = included(map, "product_categories", id);
    return category ? text(attr(category, "name")) : "";
  }

  function taxOf(map, resource) {
    var id = relId(resource, "vat_id");
    var tax = included(map, "config_taxes", id);
    return {
      taxId: id,
      rate: tax ? numberOf(attr(tax, "value")) : 0
    };
  }

  function catalogItem(resource, map) {
    return {
      code: productCode(resource),
      name: text(attr(resource, "name")),
      unit: productUnit(resource),
      category: categoryName(map, resource),
      source: text(attr(resource, "type")) || "product",
      productCode: text(attr(resource, "product_code"))
    };
  }

  function rank(item, query) {
    var q = query.toLowerCase();
    var code = item.code.toLowerCase();
    var alt = item.productCode.toLowerCase();
    var name = item.name.toLowerCase();
    if (code && code === q) return 400;
    if (alt && alt === q) return 380;
    if (code && code.indexOf(q) === 0) return 300;
    if (alt && alt.indexOf(q) === 0) return 280;
    if (code && code.indexOf(q) >= 0) return 200;
    if (alt && alt.indexOf(q) >= 0) return 180;
    if (name.indexOf(q) >= 0) return 100;
    return 1;
  }

  function searchCatalog(conn, payload) {
    var query = text(payload && payload.query);
    if (!query) return Promise.resolve({ ok: true, items: [] });
    var limit = payload && payload.limit != null ? Number(payload.limit) : 10;
    if (!limit || limit < 1) limit = 10;
    var filter = "company_id=" + conn.companyId + ",(name~=~" + filterValue(query) +
      "||ean_sku~=~" + filterValue(query) + "||product_code~=~" + filterValue(query) + ")";
    var url = dataUrl(conn, "products") + "?filter=" + encodeURIComponent(filter) +
      "&include=" + encodeURIComponent("category_id,vat_id");
    return getPage(conn, url, 0, Math.max(limit, Math.min(limit * 4, 40))).then(function (data) {
      var map = indexIncluded(data);
      var seen = {};
      var ranked = readData(data).map(function (resource) {
        return catalogItem(resource, map);
      }).filter(function (item) {
        return item.code;
      }).map(function (item) {
        return { score: rank(item, query), item: item };
      });
      ranked.sort(function (a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return a.item.code < b.item.code ? -1 : a.item.code > b.item.code ? 1 : 0;
      });
      var items = [];
      ranked.forEach(function (entry) {
        if (items.length >= limit || seen[entry.item.code]) return;
        seen[entry.item.code] = true;
        items.push({
          code: entry.item.code,
          name: entry.item.name,
          unit: entry.item.unit,
          category: entry.item.category,
          source: entry.item.source
        });
      });
      return { ok: true, items: items };
    });
  }

  function findOrder(conn, offerId) {
    function expanded(filter) {
      var url = dataUrl(conn, "orders_expanded") + "?filter=" + encodeURIComponent(filter);
      return getPage(conn, url, 0, 2).then(readData);
    }

    return expanded("company_id=" + conn.companyId + ",doc_num=" + filterValue(offerId)).then(function (rows) {
      if (rows.length > 1) throw new Error("Several offers share the number " + offerId + ".");
      if (rows.length === 1) return rows[0];
      if (!/^\d+$/.test(offerId)) {
        throw new Error("No offer with number " + offerId + ". A draft without a number can be opened by its order id.");
      }
      return expanded("company_id=" + conn.companyId + ",id=" + offerId).then(function (byId) {
        if (!byId.length) throw new Error("No offer with number or id " + offerId + ".");
        return byId[0];
      });
    }).then(function (row) {
      var id = text(attr(row, "id")) || text(row.id);
      if (!id) throw new Error("MaxxOps did not return an order id.");
      return call(conn, "GET", dataUrl(conn, "orders/" + encodeURIComponent(id)), null).then(function (doc) {
        var order = readData(doc)[0] || {};
        var company = relId(order, "company_id");
        if (company && company !== conn.companyId) throw new Error("Offer " + offerId + " belongs to another company.");
        return {
          id: id,
          state: text(attr(order, "state")) || text(attr(row, "state")),
          currency: text(attr(order, "currency")),
          label: text(attr(row, "doc_num")) || id
        };
      });
    });
  }

  function lineFromResource(resource, map) {
    var productId = relId(resource, "product_id");
    var product = included(map, "products", productId);
    var code = text(attr(resource, "ean_sku")) || (product ? productCode(product) : "");
    var attrs = parseAttrs(attr(resource, "attrs"));
    var category = attrs ? storedCategory(attrs) : null;
    if (category == null) category = product ? categoryName(map, product) : "";
    var uom = text(attr(resource, "uom")) || relId(resource, "uom");
    return {
      id: text(resource.id) || text(attr(resource, "id")),
      code: code,
      quantity: numberOf(attr(resource, "qty")),
      uom: uom,
      category: category || ""
    };
  }

  function loadLines(conn, orderId) {
    var url = dataUrl(conn, "orders/" + encodeURIComponent(orderId) + "/order_items") +
      "?include=" + encodeURIComponent("product_id,product_id.category_id");
    return getAll(conn, url).then(function (page) {
      return page.items.filter(function (resource) {
        return !relId(resource, "source_order_item_id");
      }).map(function (resource) {
        return lineFromResource(resource, page.included);
      }).filter(function (item) {
        return item.code;
      });
    });
  }

  function loadOrders(conn, payload) {
    var offerId = text(payload && payload.offer_id);
    if (!offerId) return Promise.resolve({ ok: false, error: "Offer ID is required." });
    return findOrder(conn, offerId).then(function (order) {
      return loadLines(conn, order.id).then(function (items) {
        return { ok: true, items: items };
      });
    });
  }

  function requireEditable(order) {
    if (EDITABLE[order.state]) return;
    throw new Error("Offer " + order.label + " is " + (order.state || "not editable") + ". Lines can be changed while the offer is Draft or On hold.");
  }

  function findProduct(conn, code) {
    function one(field) {
      var filter = "company_id=" + conn.companyId + "," + field + "=" + filterValue(code);
      var url = dataUrl(conn, "products") + "?filter=" + encodeURIComponent(filter) +
        "&include=" + encodeURIComponent("vat_id");
      return getPage(conn, url, 0, 2).then(function (data) {
        return { rows: readData(data), included: indexIncluded(data) };
      });
    }
    return one("ean_sku").then(function (found) {
      if (found.rows.length) return found;
      return one("product_code");
    }).then(function (found) {
      if (!found.rows.length) throw new Error("Product " + code + " is not in the MaxxOps catalog for this company.");
      if (found.rows.length > 1) throw new Error("Several products share the code " + code + ".");
      return { product: found.rows[0], included: found.included };
    });
  }

  function createLine(conn, order, item) {
    var code = text(item.code);
    return findProduct(conn, code).then(function (found) {
      var product = found.product;
      var productId = text(product.id);
      if (!/^\d+$/.test(productId)) throw new Error("Product " + code + " has no id.");
      var tax = taxOf(found.included, product);
      var price = attr(product, "unit_price");
      if (price == null || price === "") price = attr(product, "sale_unit_price");
      var unit = text(item.uom) || productUnit(product);
      if (!unit) throw new Error("Product " + code + " has no unit, and the line did not send one.");
      var attributes = {
        order_id: Number(order.id),
        product_id: Number(productId),
        product_name: text(attr(product, "name")).slice(0, 255) || code,
        product_type: text(attr(product, "type")) || "product",
        qty: numberOf(item.quantity),
        unit_price: numberOf(price),
        catalog_unit_price: numberOf(price),
        tax: tax.rate,
        uom: unit,
        attrs: attrsWithCategory({}, text(item.category))
      };
      var sku = text(attr(product, "ean_sku"));
      if (sku) attributes.ean_sku = sku;
      if (/^\d+$/.test(tax.taxId)) attributes.tax_id = Number(tax.taxId);
      if (order.currency) attributes.currency = order.currency;
      return call(conn, "POST", dataUrl(conn, "order_items"), {
        data: { type: "order_items", attributes: attributes }
      });
    });
  }

  function updateLine(conn, existing, item) {
    var attributes = { qty: numberOf(item.quantity) };
    var attrs = parseAttrs(attr(existing, "attrs"));
    if (attrs) attributes.attrs = attrsWithCategory(attrs, text(item.category));
    var id = text(existing.id) || text(attr(existing, "id"));
    return call(conn, "PATCH", dataUrl(conn, "order_items/" + encodeURIComponent(id)), {
      data: { type: "order_items", id: id, attributes: attributes }
    });
  }

  function exportOrders(conn, payload) {
    var offerId = text(payload && payload.offer_id);
    if (!offerId) return Promise.resolve({ ok: false, error: "Offer ID is required." });
    var items = payload && Array.isArray(payload.items) ? payload.items : [];
    return findOrder(conn, offerId).then(function (order) {
      requireEditable(order);
      if (!items.length) return { ok: true };
      var url = dataUrl(conn, "orders/" + encodeURIComponent(order.id) + "/order_items");
      return getAll(conn, url).then(function (page) {
        var byId = {};
        page.items.forEach(function (resource) {
          var id = text(resource.id) || text(attr(resource, "id"));
          if (id) byId[id] = resource;
        });
        var chain = Promise.resolve();
        items.forEach(function (item) {
          chain = chain.then(function () {
            var source = item || {};
            var work;
            var id = text(source.id);
            if (id && byId[id]) work = updateLine(conn, byId[id], source);
            else if (!text(source.code)) work = Promise.reject(new Error("A line is missing its product code."));
            else work = createLine(conn, order, source);
            return work.catch(function (error) {
              var code = text(source.code);
              var message = error && error.message ? error.message : "Request failed.";
              if (code && message.indexOf(code) < 0) message = code + ": " + message;
              throw new Error(message);
            });
          });
        });
        return chain.then(function () { return { ok: true }; });
      });
    });
  }

  function run(action, settings, payload) {
    return connection(settings).then(function (conn) {
      if (!conn.ok) return conn;
      if (action === "catalog.search") return searchCatalog(conn, payload);
      if (action === "orders.load") return loadOrders(conn, payload);
      if (action === "orders.export") return exportOrders(conn, payload);
      return { ok: false, error: "Unknown adapter action." };
    }).catch(function (error) {
      return fail(error);
    });
  }

  function execute(request) {
    var action = request && request.action;
    var settings = (request && request.settings) || {};
    var payload = (request && request.payload) || {};
    if (action !== "catalog.search" && action !== "orders.load" && action !== "orders.export") {
      return Promise.resolve({ ok: false, error: "Unknown adapter action." });
    }
    return run(action, settings, payload);
  }

  global.MaxxAdapter = { execute: execute };
})(window);
