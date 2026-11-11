// Host for adapter scripts.
// A dialog installs one script for product lookup and one for offers, then
// calls Maxx.call(action, payload). catalog.search uses the lookup slot.
// orders.load and orders.export use the offers slot.
// The adapter owns the request. This file checks the result shape and returns:
//   { ok: true, items: [], error: "" } or { ok: false, items: [], error: "..." }
// catalog.search items: { code, name, unit, category, price, source }
// orders.load items:    { id, code, quantity, uom, category }
// orders.export payload: { offer_id, items: [{ id, code, quantity, uom, category }] }
(function (global) {
  "use strict";

  function asText(value) {
    return value == null ? "" : String(value).trim();
  }

  function emptySlot() {
    return {
      settings: {},
      actions: [],
      ready: {},
      name: "",
      scriptError: "",
      datasourceError: "",
      execute: null
    };
  }

  var slots = { catalog: emptySlot(), orders: emptySlot() };

  function loadIsolated(source) {
    var sandbox = {};
    var runner = new Function("window", source);
    runner(sandbox);
    return sandbox.MaxxAdapter;
  }

  function configureSlot(slot, data) {
    data = data || {};
    slot.settings = {};
    slot.actions = [];
    slot.ready = {};
    slot.execute = null;
    slot.name = data.datasource_name ? String(data.datasource_name) : (data.api_adapter_name ? String(data.api_adapter_name) : "");
    slot.datasourceError = data.datasource_error ? String(data.datasource_error) : "";
    slot.scriptError = "";
    var source = data.adapter_script ? String(data.adapter_script) : "";
    var declared = Array.isArray(data.adapter_actions) ? data.adapter_actions : [];
    if (source) {
      try {
        var adapter = loadIsolated(source);
        if (!adapter || typeof adapter.execute !== "function") {
          slot.scriptError = "Adapter script did not provide execute.";
        } else {
          slot.execute = adapter.execute;
        }
      } catch (error) {
        slot.scriptError = error && error.message ? error.message : String(error);
      }
    } else if (declared.length) {
      slot.scriptError = "Adapter script was not found.";
    }
    if (!slot.scriptError) {
      slot.settings = data.adapter_settings && typeof data.adapter_settings === "object" ? data.adapter_settings : {};
      slot.actions = declared;
      slot.ready = data.adapter_ready && typeof data.adapter_ready === "object" ? data.adapter_ready : {};
    }
  }

  function configure(data) {
    data = data || {};
    var nested = Object.prototype.hasOwnProperty.call(data, "catalog") || Object.prototype.hasOwnProperty.call(data, "orders");
    if (nested) {
      if (Object.prototype.hasOwnProperty.call(data, "catalog")) configureSlot(slots.catalog, data.catalog || {});
      if (Object.prototype.hasOwnProperty.call(data, "orders")) configureSlot(slots.orders, data.orders || {});
    } else {
      configureSlot(slots.catalog, data);
    }
    return slots.catalog.scriptError;
  }

  function slotFor(action) {
    if (action === "orders.load" || action === "orders.export") return slots.orders;
    return slots.catalog;
  }

  function standardItems(action, items) {
    if (!Array.isArray(items)) return [];
    if (action === "catalog.search") {
      return items.map(function (item) {
        item = item || {};
        return {
          code: asText(item.code),
          name: asText(item.name),
          unit: asText(item.unit),
          category: asText(item.category),
          price: asText(item.price),
          source: asText(item.source)
        };
      });
    }
    if (action === "orders.load") {
      return items.map(function (item) {
        item = item || {};
        return {
          id: asText(item.id),
          code: asText(item.code),
          quantity: item.quantity,
          uom: asText(item.uom),
          category: asText(item.category)
        };
      });
    }
    return [];
  }

  function call(action, payload) {
    var slot = slotFor(action);
    if (slot.datasourceError) return Promise.resolve({ ok: false, items: [], error: slot.datasourceError });
    if (slot.scriptError) return Promise.resolve({ ok: false, items: [], error: slot.scriptError });
    if (typeof slot.execute !== "function") {
      return Promise.resolve({ ok: false, items: [], error: "No data source is selected." });
    }
    var request = { action: action, settings: slot.settings, payload: payload || {} };
    return Promise.resolve().then(function () {
      return slot.execute(request);
    }).then(function (result) {
      if (!result || typeof result !== "object" || result.ok !== true) {
        var message = result && result.error ? String(result.error) : "Adapter request failed.";
        return { ok: false, items: [], error: message };
      }
      return {
        ok: true,
        items: standardItems(action, result.items),
        error: result.error ? String(result.error) : ""
      };
    }, function (error) {
      return { ok: false, items: [], error: error && error.message ? error.message : String(error) };
    });
  }

  function isReady(action) {
    var slot = slotFor(action);
    return !slot.scriptError && !slot.datasourceError && !!slot.ready[action] && slot.actions.indexOf(action) >= 0;
  }

  global.Maxx = {
    configure: configure,
    call: call,
    ready: isReady,
    name: function (action) { return slotFor(action || "catalog.search").name; },
    error: function (action) {
      var slot = slotFor(action || "catalog.search");
      return slot.scriptError || slot.datasourceError;
    }
  };
})(window);
