// CSV catalog adapter.
// The host reads the file and passes it as settings.file_text. This script does
// not touch disk. request: { action, settings, payload }
//   catalog.search  { query, limit }     substring match on code and name
//   catalog.search  { codes: [...] }     exact code match, first row per code, includes price
// result items: { code, name, unit, category, price, source }
(function (global) {
  "use strict";

  function text(value) {
    return value == null ? "" : String(value).trim();
  }

  // Quoted fields, doubled quotes, commas and newlines inside quotes, CRLF or LF.
  function parseCsv(input) {
    var rows = [];
    var row = [];
    var field = "";
    var quoted = false;
    var index = 0;
    while (index < input.length) {
      var char = input.charAt(index);
      if (quoted) {
        if (char === '"') {
          if (input.charAt(index + 1) === '"') {
            field += '"';
            index += 1;
          } else {
            quoted = false;
          }
        } else {
          field += char;
        }
      } else if (char === '"') {
        if (field !== "") throw new Error("unexpected quote in CSV field");
        quoted = true;
      } else if (char === ",") {
        row.push(field);
        field = "";
      } else if (char === "\n") {
        row.push(field);
        if (!(row.length === 1 && row[0] === "")) rows.push(row);
        row = [];
        field = "";
      } else if (char !== "\r") {
        field += char;
      }
      index += 1;
    }
    if (quoted) throw new Error("unterminated quoted CSV field");
    if (row.length || field !== "") {
      row.push(field);
      rows.push(row);
    }
    return rows;
  }

  function loadItems(settings) {
    var raw = String(settings.file_text || "").replace(/^\uFEFF/, "");
    var rows = parseCsv(raw);
    var header = rows.shift() || [];
    var indexes = {};
    header.forEach(function (name, index) {
      name = text(name);
      if (name && !Object.prototype.hasOwnProperty.call(indexes, name)) indexes[name] = index;
    });
    function cell(row, column) {
      column = text(column);
      if (!column || !Object.prototype.hasOwnProperty.call(indexes, column)) return "";
      var value = row[indexes[column]];
      return text(value);
    }
    var items = [];
    rows.forEach(function (row) {
      var code = cell(row, settings.code);
      if (!code) return;
      items.push({
        code: code,
        name: cell(row, settings.name),
        unit: cell(row, settings.unit),
        category: cell(row, settings.category),
        price: cell(row, settings.price),
        source: "csv"
      });
    });
    return items;
  }

  function exactCodes(items, codes) {
    var wanted = {};
    codes.forEach(function (code) {
      code = text(code);
      if (code) wanted[code] = true;
    });
    var seen = {};
    var found = [];
    items.forEach(function (item) {
      if (!wanted[item.code] || seen[item.code]) return;
      seen[item.code] = true;
      found.push(item);
    });
    return found;
  }

  function searchQuery(items, query, limit) {
    var q = text(query).toLowerCase();
    if (!q) return [];
    var cap = limit == null || isNaN(Number(limit)) ? 20 : Number(limit);
    if (cap < 1) cap = 20;
    var scored = [];
    items.forEach(function (item) {
      var code = item.code.toLowerCase();
      var name = item.name.toLowerCase();
      var score = 0;
      if (code === q) score = 300;
      else if (code.indexOf(q) === 0) score = 200;
      else if (code.indexOf(q) >= 0) score = 150;
      else if (name.indexOf(q) >= 0) score = 100;
      if (score > 0) scored.push({ score: score, item: item });
    });
    scored.sort(function (a, b) {
      if (b.score !== a.score) return b.score - a.score;
      return a.item.code < b.item.code ? -1 : (a.item.code > b.item.code ? 1 : 0);
    });
    return scored.slice(0, cap).map(function (entry) { return entry.item; });
  }

  function search(settings, payload) {
    var items = loadItems(settings);
    payload = payload || {};
    if (Array.isArray(payload.codes)) return { ok: true, items: exactCodes(items, payload.codes) };
    return { ok: true, items: searchQuery(items, payload.query, payload.limit) };
  }

  function execute(request) {
    var action = request && request.action;
    var settings = (request && request.settings) || {};
    var payload = (request && request.payload) || {};
    if (action !== "catalog.search") {
      return Promise.resolve({ ok: false, error: "This adapter only looks up products." });
    }
    try {
      return Promise.resolve(search(settings, payload));
    } catch (error) {
      return Promise.resolve({ ok: false, error: error && error.message ? error.message : String(error) });
    }
  }

  global.MaxxAdapter = { execute: execute };
})(window);
