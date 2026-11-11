var UnitMap = (function () {
  // Quantity kind stored on a rule. Area, length and volume take their
  // label and catalog names from the quotation unit.
  var UNITS = ["pcs", "area", "length", "volume", "custom"];
  var DIMENSIONS = ["area", "length", "volume"];
  var LEGACY = { m2: "area", mtr: "length", m: "length", m3: "volume" };
  var QUOTATION_UNITS = ["m", "cm", "mm", "ft", "in"];
  var QUANTITY_LABELS = {
    pcs: "Pieces",
    area: "Area",
    length: "Length",
    volume: "Volume",
    custom: "Custom"
  };
  var QUOTATION_EXPORT = {
    m: { area: "m2", length: "mtr", volume: "m3" },
    cm: { area: "cm2", length: "cm", volume: "cm3" },
    mm: { area: "mm2", length: "mm", volume: "mm3" },
    ft: { area: "ft2", length: "ft", volume: "ft3" },
    in: { area: "in2", length: "in", volume: "in3" }
  };
  var QUOTATION_LABELS = {
    m: { area: "m²", length: "m", volume: "m³" },
    cm: { area: "cm²", length: "cm", volume: "cm³" },
    mm: { area: "mm²", length: "mm", volume: "mm³" },
    ft: { area: "ft²", length: "ft", volume: "ft³" },
    in: { area: "in²", length: "in", volume: "in³" }
  };
  // Extra catalog names for one quotation unit. The export name is accepted
  // separately and is not repeated here. The meter list is the historical default.
  var QUOTATION_ACCEPT = {
    m: {
      area: ["m²"],
      length: ["mtr.", "m", "meter", "meters", "linear meter"],
      volume: ["m³", "m3.", "cubic meter", "cubic meters"]
    },
    cm: {
      area: ["cm²"],
      length: ["centimeter", "centimeters"],
      volume: ["cm³", "cubic centimeter", "cubic centimeters"]
    },
    mm: {
      area: ["mm²"],
      length: ["millimeter", "millimeters"],
      volume: ["mm³", "cubic millimeter", "cubic millimeters"]
    },
    ft: {
      area: ["ft²", "sq ft", "sqft", "square foot", "square feet"],
      length: ["lf", "foot", "feet", "linear ft", "linear feet"],
      volume: ["ft³", "cu ft", "cuft", "cubic foot", "cubic feet"]
    },
    in: {
      area: ["in²", "sq in", "sqin", "square inch", "square inches"],
      length: ["inch", "inches"],
      volume: ["in³", "cu in", "cuin", "cubic inch", "cubic inches"]
    }
  };

  function exportNameFor(unit, uom) {
    var table = QUOTATION_EXPORT[unit];
    var key = canonicalUom(uom);
    if (table && table[key]) return table[key];
    return key || uom;
  }

  function acceptFor(unit, uom) {
    var table = QUOTATION_ACCEPT[unit];
    var key = canonicalUom(uom);
    var names = table && table[key];
    return names ? names.slice() : [];
  }

  function labelFor(unit, uom) {
    var key = canonicalUom(uom);
    if (key === "pcs" || key === "custom" || !key) return key || "";
    var table = QUOTATION_LABELS[unit] || QUOTATION_LABELS.m;
    return (table && table[key]) || key;
  }

  function quantityLabel(uom) {
    var key = canonicalUom(uom);
    return QUANTITY_LABELS[key] || key || "";
  }

  function standardExportName(uom, name) {
    var key = canonicalUom(uom);
    var text = String(name == null ? "" : name).trim().toLowerCase();
    if (!text) return true;
    return QUOTATION_UNITS.some(function (unit) {
      var standard = QUOTATION_EXPORT[unit][key];
      return standard && standard.toLowerCase() === text;
    });
  }

  function acceptTokens(value) {
    var list = Array.isArray(value) ? value : String(value == null ? "" : value).split(",");
    var names = [];
    list.forEach(function (name) {
      var text = String(name == null ? "" : name).trim();
      if (!text) return;
      if (names.some(function (existing) { return existing.toLowerCase() === text.toLowerCase(); })) return;
      names.push(text);
    });
    return names;
  }

  function sameNameSet(left, right) {
    if (left.length !== right.length) return false;
    var keys = {};
    left.forEach(function (name) { keys[String(name).toLowerCase()] = true; });
    return right.every(function (name) { return keys[String(name).toLowerCase()]; });
  }

  function standardAcceptList(uom, value) {
    var key = canonicalUom(uom);
    var tokens = acceptTokens(value);
    return QUOTATION_UNITS.some(function (unit) {
      var standard = QUOTATION_ACCEPT[unit][key];
      return standard && sameNameSet(tokens, standard);
    });
  }

  function canonicalUom(uom) {
    var text = String(uom == null ? "" : uom).trim();
    if (!text) return "";
    var key = text.toLowerCase();
    if (LEGACY[key]) return LEGACY[key];
    if (UNITS.indexOf(key) !== -1) return key;
    return text;
  }

  var DEFAULTS = {
    pcs: { export: "pcs", accept: ["stuks", "stuk", "pieces"] },
    area: { export: "m2", accept: ["m²"] },
    length: { export: "mtr", accept: ["mtr.", "m", "meter", "meters", "linear meter"] },
    volume: { export: "m3", accept: ["m³", "m3.", "cubic meter", "cubic meters"] },
    custom: { export: "custom", accept: [] }
  };

  function cloneDefaults() {
    var out = {};
    UNITS.forEach(function (uom) {
      out[uom] = { export: DEFAULTS[uom].export, accept: DEFAULTS[uom].accept.slice() };
    });
    return out;
  }

  function foldLegacy(raw) {
    var out = {};
    UNITS.forEach(function (uom) {
      if (raw[uom] && typeof raw[uom] === "object") out[uom] = raw[uom];
    });
    Object.keys(LEGACY).forEach(function (oldKey) {
      var uom = LEGACY[oldKey];
      if (!out[uom] && raw[oldKey] && typeof raw[oldKey] === "object") out[uom] = raw[oldKey];
    });
    return out;
  }

  function parse(value) {
    var raw = value;
    if (typeof raw === "string") {
      try { raw = JSON.parse(raw); } catch (e) { raw = null; }
    }
    if (!raw || typeof raw !== "object") return cloneDefaults();
    raw = foldLegacy(raw);
    var out = {};
    UNITS.forEach(function (uom) {
      var entry = raw[uom] || {};
      var exportName = entry.export != null ? String(entry.export).trim() : DEFAULTS[uom].export;
      if (!exportName || exportName.toLowerCase() === uom) exportName = DEFAULTS[uom].export;
      var accept = Array.isArray(entry.accept) ? entry.accept : DEFAULTS[uom].accept;
      var names = [];
      accept.forEach(function (name) {
        var text = String(name == null ? "" : name).trim();
        if (!text) return;
        if (text.toLowerCase() === uom.toLowerCase()) return;
        if (text.toLowerCase() === exportName.toLowerCase()) return;
        if (names.some(function (existing) { return existing.toLowerCase() === text.toLowerCase(); })) return;
        names.push(text);
      });
      out[uom] = { export: exportName, accept: names };
    });
    return out;
  }

  function namesFor(entry, uom) {
    var names = [uom];
    if (entry.export) names.push(entry.export);
    return names.concat(entry.accept || []);
  }

  function toPlugin(external, map) {
    if (external == null) return "";
    var raw = String(external).trim();
    if (!raw) return "";
    var key = raw.toLowerCase();
    var parsed = parse(map);
    var found = "";
    UNITS.some(function (uom) {
      var hit = namesFor(parsed[uom], uom).some(function (name) {
        return String(name).trim().toLowerCase() === key;
      });
      if (hit) found = uom;
      return hit;
    });
    return found || raw;
  }

  function toExternal(pluginUom, map) {
    var uom = canonicalUom(pluginUom);
    if (!uom) return "";
    var parsed = parse(map);
    if (parsed[uom] && parsed[uom].export) return parsed[uom].export;
    return uom;
  }

  return {
    UNITS: UNITS,
    DIMENSIONS: DIMENSIONS,
    QUOTATION_UNITS: QUOTATION_UNITS,
    parse: parse,
    toPlugin: toPlugin,
    toExternal: toExternal,
    canonicalUom: canonicalUom,
    exportNameFor: exportNameFor,
    acceptFor: acceptFor,
    labelFor: labelFor,
    quantityLabel: quantityLabel,
    standardExportName: standardExportName,
    standardAcceptList: standardAcceptList
  };
})();
