  var autoSaveTimer = null;
  var AUTO_SAVE_DEBOUNCE_MS = 600;
  var previewTimer = null;
  var PREVIEW_DEBOUNCE_MS = 350;
  var previewRequestId = 0;
  var quotationLengthUnit = "m";
  var PREVIEW_FIELDS = {
    bom_measure: true,
    bom_uom: true,
    bom_multiplier: true,
    bom_rounding_mode: true,
    bom_rounding_step: true,
    bom_param_material: true
  };

  // Measurement options: value -> label. Used to refill measure dropdown by UOM.
  var MEASURE_OPTIONS = [
    { value: "count", label: "Count" },
    { value: "top_area", label: "Top area" },
    { value: "bottom_area", label: "Bottom area" },
    { value: "front_area", label: "Front area" },
    { value: "back_area", label: "Back area" },
    { value: "left_area", label: "Left area" },
    { value: "right_area", label: "Right area" },
    { value: "total_area", label: "Total area" },
    { value: "material_area", label: "Material area" },
    { value: "top_perimeter", label: "Top perimeter" },
    { value: "bottom_perimeter", label: "Bottom perimeter" },
    { value: "front_perimeter", label: "Front perimeter" },
    { value: "back_perimeter", label: "Back perimeter" },
    { value: "left_perimeter", label: "Left perimeter" },
    { value: "right_perimeter", label: "Right perimeter" },
    { value: "smart_length", label: "Length" },
    { value: "bbox_volume", label: "BBox volume" },
    { value: "bbox_dimensions", label: "BBox dimensions" }
  ];
  // Allowed measure values per UOM. Empty string = placeholder only.
  var MEASURE_BY_UOM = {
    pcs: ["count"],
    area: ["top_area", "bottom_area", "front_area", "back_area", "left_area", "right_area", "total_area", "material_area"],
    length: ["smart_length", "top_perimeter", "bottom_perimeter", "front_perimeter", "back_perimeter", "left_perimeter", "right_perimeter"],
    volume: ["bbox_volume"],
    custom: ["count", "top_area", "bottom_area", "front_area", "back_area", "left_area", "right_area", "total_area", "material_area", "top_perimeter", "bottom_perimeter", "front_perimeter", "back_perimeter", "left_perimeter", "right_perimeter", "smart_length", "bbox_volume", "bbox_dimensions"]
  };
  // Applied when the unit changes, or when the current measure is not valid for that unit.
  var DEFAULT_MEASURE_BY_UOM = {
    pcs: "count",
    area: "top_area",
    length: "smart_length",
    volume: "bbox_volume",
    custom: "count"
  };
  var quotationLengthUnit = "m";

  function defaultMeasureForUom(uom, allowed) {
    var fallback = DEFAULT_MEASURE_BY_UOM[uom];
    if (fallback && allowed.indexOf(fallback) !== -1) return fallback;
    return allowed[0] || "";
  }

  function refillMeasureOptionsForForm(form, options) {
    var measureSelect = form && form.querySelector("[name='bom_measure']");
    var uomSelect = form && form.querySelector("[name='bom_uom']");
    if (!measureSelect || !uomSelect) return;
    var uom = normalizeUom((uomSelect.value || "").trim()) || "pcs";
    var allowed = MEASURE_BY_UOM[uom] || MEASURE_BY_UOM.pcs;
    var current = measureSelect.value || "";
    var keepCurrent = !(options && options.forceDefault) && allowed.indexOf(current) !== -1;
    measureSelect.innerHTML = "";
    var empty = document.createElement("option");
    empty.value = "";
    empty.textContent = "Select measure";
    measureSelect.appendChild(empty);
    (allowed || []).forEach(function(val) {
      var rec = MEASURE_OPTIONS.find(function(r) { return r.value === val; });
      if (rec) {
        var opt = document.createElement("option");
        opt.value = rec.value;
        opt.textContent = rec.label;
        measureSelect.appendChild(opt);
      }
    });
    measureSelect.value = keepCurrent ? current : defaultMeasureForUom(uom, allowed);
    toggleMaterialParamVisibility(form);
  }

  window.refillMeasureOptionsForForm = refillMeasureOptionsForForm;

  function getEmptyRulesPlaceholder() {
    var p = document.createElement("div");
    p.className = "empty-rules-placeholder";
    p.textContent = "No rules yet. Click «Add rule» above to create one.";
    return p;
  }

  function ensureEmptyRulesPlaceholder(container) {
    if (!container) return;
    if (container.querySelectorAll("form").length === 0 && !container.querySelector(".empty-rules-placeholder")) {
      container.appendChild(getEmptyRulesPlaceholder());
    }
  }

  function removeEmptyRulesPlaceholder(container) {
    if (!container) return;
    var el = container.querySelector(".empty-rules-placeholder");
    if (el) el.remove();
  }

  function getBlockForm(block) {
    return block && block.querySelector && block.querySelector("form");
  }

  function updateBlockSummary(block) {
    var form = getBlockForm(block);
    var summaryEl = block && block.querySelector && block.querySelector(".rules-block-summary-main");
    if (!form || !summaryEl) return;
    var code = (form.querySelector("[name='bom']") && form.querySelector("[name='bom']").value) || "—";
    var uomSelect = form.querySelector("[name='bom_uom']");
    var uom = (uomSelect && uomSelect.options[uomSelect.selectedIndex] && uomSelect.options[uomSelect.selectedIndex].text) ? uomSelect.options[uomSelect.selectedIndex].text : (uomSelect && uomSelect.value) || "—";
    var measureSelect = form.querySelector("[name='bom_measure']");
    var measure = (measureSelect && measureSelect.options[measureSelect.selectedIndex] && measureSelect.options[measureSelect.selectedIndex].text) ? measureSelect.options[measureSelect.selectedIndex].text : (measureSelect && measureSelect.value) || "—";
    var multiplier = quantityMultiplier(form.querySelector("[name='bom_multiplier']"));
    summaryEl.textContent = code + " / " + uom + " / " + measure + (multiplier === 1 ? "" : (" × " + formatMultiplier(multiplier)));
  }

  function addItem(content) {
    content = content || {};
    var template = document.getElementById("rules-template");
    if (!template || !template.content) return;
    var clone = template.content.cloneNode(true);
    var container = document.getElementById("rules-container");
    if (!container) return;
    container.appendChild(clone);
    removeEmptyRulesPlaceholder(container);
    var blocks = container.querySelectorAll(".rules-block");
    var block = blocks[blocks.length - 1];
    var form = block && getBlockForm(block);
    if (form) {
      var forms = container.querySelectorAll("form");
      var idxInput = form.querySelector("input[name='ruleset_idx']");
      if (idxInput) idxInput.value = forms.length - 1;
      form.reset();
      if (idxInput) idxInput.value = forms.length - 1;
      fillMaterialSelectForForm(form);
      applyValuesToForm(form, content);
      refillMeasureOptionsForForm(form);
      updateBlockSummary(block);
      scheduleRulePreview();
      var header = block.querySelector(".rules-block-header");
      if (header) {
        header.addEventListener("click", function() {
          block.classList.toggle("collapsed");
        });
      }
    }
  }

  function applyValuesToForm(form, values) {
    if (!form || !values || typeof values !== "object") return;
    Object.keys(values).forEach(function(key) {
      var input = form.querySelector("[name='" + key + "']");
      if (input && values[key] != null) {
        if (input.tagName === "SELECT") {
          var opt = input.querySelector("option[value='" + String(values[key]) + "']");
          if (opt) input.value = values[key];
        } else {
          input.value = values[key];
        }
      }
    });
  }

  window.onSketchUpSelection = function(payload) {
    try {
      console.log("onSketchUpSelection", payload);
      var emptyMsg = document.getElementById("empty-selection-message");
      var container = document.getElementById("rules-container");
      if (!payload || !payload.type) return;

      if (payload.type === "error") {
        setNoSelectionState(emptyMsg, payload.reason, container, document.getElementById("toolbar-actions"));
        return;
      }

      if (payload.type === "rules") {
        cancelRulePreview();
        setSelectionState(emptyMsg, container, document.getElementById("toolbar-actions"));
        clearDirtyState();
        if (!container) return;
        var exportableWrap = document.getElementById("exportable-wrap");
        var exportableFlag = document.getElementById("exportable-flag");
        if (exportableWrap) {
          exportableWrap.classList.remove("hidden");
          exportableWrap.setAttribute("aria-hidden", "false");
        }
        if (exportableFlag) {
          exportableFlag.disabled = false;
          delete exportableFlag.dataset.savedChecked;
          exportableFlag.checked = payload.traversable === true ? false : payload.exportable !== false;
        }
        applyTraversableFlag(payload);
        syncExportableWithTraversable();
        window.currentComponentMaterials = payload.materials && Array.isArray(payload.materials) ? payload.materials : [];
        var schemaVersion = (payload.schema_version && typeof payload.schema_version === "string") ? payload.schema_version : "1.0";
        container.setAttribute("data-schema-version", schemaVersion);
        container.innerHTML = "";
        var rules = [];
        try {
          if (payload.bom_rules != null) {
            var raw = typeof payload.bom_rules === "string" ? payload.bom_rules : JSON.stringify(payload.bom_rules);
            if (raw) rules = JSON.parse(raw);
          }
        } catch (e) {
          console.warn("onSketchUpSelection: invalid bom_rules JSON", e);
        }
        if (!Array.isArray(rules)) rules = [];
        rules.forEach(function(rule) {
          addItem(ruleToFormValues(rule));
        });
        container.querySelectorAll(".rules-block").forEach(function(block) {
          updateBlockSummary(block);
        });
        if (rules.length === 0) ensureEmptyRulesPlaceholder(container);
        setMeasurementEditorVisible(measurementRulesAllowed());
        if (measurementRulesAllowed() && rules.length > 0) scheduleRulePreview();
      }
    } catch (err) {
      console.error("onSketchUpSelection error:", err);
    }
  };

  function setNoSelectionState(emptyMsg, reason, container, toolbar) {
    if (emptyMsg) {
      emptyMsg.textContent = reason === "none_selected" ? "Nothing selected" :
        reason === "not_a_component" ? "Select a component (not a group, face, or edge)" :
        "Select a single entity";
      emptyMsg.classList.remove("hidden");
      emptyMsg.setAttribute("aria-hidden", "false");
    }
    if (container) container.innerHTML = "";
    if (toolbar) {
      toolbar.setAttribute("aria-hidden", "true");
      toolbar.classList.add("hidden");
    }
    var exportableWrap = document.getElementById("exportable-wrap");
    if (exportableWrap) {
      exportableWrap.classList.add("hidden");
      exportableWrap.setAttribute("aria-hidden", "true");
    }
    setMeasurementEditorVisible(true);
    cancelRulePreview();
  }

  var TRAVERSABLE_ENABLED_TITLE = "Open this component and export the components inside it. This component has no measurement rules.";
  var TRAVERSABLE_DISABLED_TITLE = "Available only when this component contains other components.";

  function applyTraversableFlag(payload) {
    var flag = document.getElementById("traversable-flag");
    var label = document.getElementById("traversable-label");
    if (!flag) return;
    var canTraverse = !!(payload && payload.has_inner_components === true);
    flag.disabled = !canTraverse;
    flag.checked = canTraverse && payload.traversable === true;
    var title = canTraverse ? TRAVERSABLE_ENABLED_TITLE : TRAVERSABLE_DISABLED_TITLE;
    flag.title = title;
    if (label) {
      label.title = title;
      label.classList.toggle("is-disabled", !canTraverse);
    }
  }

  function syncExportableWithTraversable() {
    var exportableFlag = document.getElementById("exportable-flag");
    var exportableLabel = document.getElementById("exportable-label");
    if (!exportableFlag) return;
    if (!measurementRulesAllowed()) {
      if (exportableFlag.dataset.savedChecked == null) {
        exportableFlag.dataset.savedChecked = exportableFlag.checked ? "true" : "false";
      }
      exportableFlag.checked = false;
      exportableFlag.disabled = true;
    } else {
      exportableFlag.disabled = false;
      if (exportableFlag.dataset.savedChecked != null) {
        exportableFlag.checked = exportableFlag.dataset.savedChecked === "true";
        delete exportableFlag.dataset.savedChecked;
      }
    }
    if (exportableLabel) exportableLabel.classList.toggle("is-disabled", exportableFlag.disabled);
  }

  function measurementRulesAllowed() {
    var flag = document.getElementById("traversable-flag");
    return !(flag && !flag.disabled && flag.checked);
  }

  function setMeasurementEditorVisible(visible) {
    var addButton = document.getElementById("btn-add-item");
    var container = document.getElementById("rules-container");
    var note = document.getElementById("traversable-note");
    if (addButton) addButton.classList.toggle("hidden", !visible);
    if (container) container.classList.toggle("hidden", !visible);
    if (note) {
      note.classList.toggle("hidden", visible);
      note.setAttribute("aria-hidden", visible ? "true" : "false");
    }
  }

  function setSelectionState(emptyMsg, container, toolbar) {
    if (emptyMsg) {
      emptyMsg.classList.add("hidden");
      emptyMsg.setAttribute("aria-hidden", "true");
    }
    if (toolbar) {
      toolbar.removeAttribute("aria-hidden");
      toolbar.classList.remove("hidden");
    }
  }

  function formValuesToRule(form) {
    if (!form) return {};
    var rule = {};
    var bom = form.querySelector("[name='bom']");
    var bomLabel = form.querySelector("[name='bom_label']");
    var bomMeasure = form.querySelector("[name='bom_measure']");
    var bomUom = form.querySelector("[name='bom_uom']");
    var bomCategory = form.querySelector("[name='bom_category']");
    var bomMultiplier = form.querySelector("[name='bom_multiplier']");
    var bomRoundingMode = form.querySelector("[name='bom_rounding_mode']");
    var bomRoundingStep = form.querySelector("[name='bom_rounding_step']");
    var bomParamMaterial = form.querySelector("[name='bom_param_material']");
    if (bom && bom.value !== undefined) rule.code = bom.value;
    if (bomLabel && bomLabel.value !== undefined) rule.label = bomLabel.value;
    if (bomMeasure && bomMeasure.value !== undefined) rule.measure = bomMeasure.value;
    if (bomUom && bomUom.value !== undefined) rule.uom = normalizeUom(bomUom.value);
    rule.multiplier = quantityMultiplier(bomMultiplier);
    if (bomCategory && bomCategory.value !== undefined && bomCategory.value !== "") rule.category = bomCategory.value;
    if (bomMeasure && bomMeasure.value === "material_area" && bomParamMaterial && bomParamMaterial.value) {
      rule.params = rule.params || {};
      rule.params.material = bomParamMaterial.value;
    }
    if (bomRoundingMode || bomRoundingStep) {
      rule.rounding = {};
      if (bomRoundingMode && bomRoundingMode.value !== undefined) rule.rounding.mode = bomRoundingMode.value;
      if (bomRoundingStep && bomRoundingStep.value !== undefined) rule.rounding.step = parseFloat(bomRoundingStep.value, 10) || 0.01;
    }
    return rule;
  }

  function collectRulesFromUI() {
    var container = document.getElementById("rules-container");
    if (!container) return { schema_version: "1.0", bom_rules: "[]" };
    var schemaVersion = container.getAttribute("data-schema-version") || "1.0";
    var forms = container.querySelectorAll("form");
    var rules = [];
    for (var i = 0; i < forms.length; i++) {
      rules.push(formValuesToRule(forms[i]));
    }
    return { schema_version: schemaVersion, bom_rules: JSON.stringify(rules) };
  }

  function setDirty(form) {
    if (form) form.classList.add("rules-form--dirty");
    var btn = document.getElementById("btn-save");
    if (btn) btn.classList.remove("hidden");
  }

  function clearDirtyState() {
    var container = document.getElementById("rules-container");
    if (container) {
      container.querySelectorAll("form.rules-form--dirty").forEach(function(f) { f.classList.remove("rules-form--dirty"); });
    }
    var btn = document.getElementById("btn-save");
    if (btn) btn.classList.add("hidden");
  }

  function scheduleAutoSave() {
    if (autoSaveTimer) clearTimeout(autoSaveTimer);
    autoSaveTimer = setTimeout(function() {
      autoSaveTimer = null;
      saveRules();
    }, AUTO_SAVE_DEBOUNCE_MS);
  }

  // Catalog search fills code, label, unit, and measure by assigning values.
  // That does not emit input or change, so persist the rule immediately.
  function onCatalogItemApplied(rowOrFieldset) {
    if (!rowOrFieldset || !rowOrFieldset.querySelector) return;
    var form = rowOrFieldset.tagName === "FORM" ? rowOrFieldset : rowOrFieldset.closest("form");
    var block = rowOrFieldset.closest(".rules-block");
    if (block) updateBlockSummary(block);
    setDirty(form);
    saveRules();
    scheduleRulePreview();
  }

  function saveRules() {
    if (autoSaveTimer) {
      clearTimeout(autoSaveTimer);
      autoSaveTimer = null;
    }
    var payload = collectRulesFromUI();
    var rules = [];
    try {
      var raw = payload.bom_rules;
      if (typeof raw === "string" && raw) rules = JSON.parse(raw);
      else if (Array.isArray(raw)) rules = raw;
    } catch (e) { rules = []; }
    var exportableFlag = document.getElementById("exportable-flag");
    var traversableFlag = document.getElementById("traversable-flag");
    var traversableOn = !!(traversableFlag && !traversableFlag.disabled && traversableFlag.checked);
    if (!traversableOn) {
      var missing = rules.some(function(r) {
        var m = (r && r.measure != null) ? r.measure : "";
        return (typeof m === "string" ? m.trim() : String(m)) === "";
      });
      if (missing) {
        return;
      }
      var missingMaterial = rules.some(function(r) {
        if (!r || (r.measure || "").toString().trim() !== "material_area") return false;
        var mat = (r.params && r.params.material != null) ? r.params.material : "";
        return (typeof mat === "string" ? mat.trim() : String(mat)) === "";
      });
      if (missingMaterial) {
        return;
      }
    }
    payload.exportable = traversableOn ? false : (exportableFlag ? exportableFlag.checked : true);
    payload.traversable = traversableOn;
    if (traversableOn) payload.bom_rules = "[]";
    clearDirtyState();
    sketchup.save_rules(JSON.stringify(payload));
  }

  var FORM_FIELDS = ["bom", "bom_label", "bom_measure", "bom_uom", "bom_category", "bom_multiplier", "bom_rounding_mode", "bom_rounding_step", "bom_param_material"];

  // Older rules stored m2 / mtr / m3, and a schema before that stored m.
  function normalizeUom(uom) {
    if (typeof UnitMap !== "undefined" && UnitMap.canonicalUom) return UnitMap.canonicalUom(uom);
    var u = (uom == null ? "" : String(uom)).trim();
    if (u === "m" || u === "mtr") return "length";
    if (u === "m2") return "area";
    if (u === "m3") return "volume";
    return u;
  }

  function applyQuotationUomLabels(unit) {
    quotationLengthUnit = unit || "m";
    var selects = [];
    var template = document.getElementById("rules-template");
    if (template && template.content) {
      template.content.querySelectorAll("select[name='bom_uom']").forEach(function(sel) { selects.push(sel); });
    }
    document.querySelectorAll("select[name='bom_uom']").forEach(function(sel) { selects.push(sel); });
    selects.forEach(function(sel) {
      Array.prototype.forEach.call(sel.options, function(opt) {
        opt.textContent = (typeof UnitMap !== "undefined" && UnitMap.labelFor)
          ? UnitMap.labelFor(quotationLengthUnit, opt.value)
          : opt.value;
      });
    });
    document.querySelectorAll(".rules-block").forEach(updateBlockSummary);
  }

  window.applyQuotationUomLabels = applyQuotationUomLabels;

  function ruleToFormValues(rule) {
    if (!rule || typeof rule !== "object") return {};
    var v = {};
    FORM_FIELDS.forEach(function(k) {
      if (rule[k] != null) v[k] = rule[k];
    });
    if (v.bom == null && rule.code != null) v.bom = rule.code;
    if (v.bom_label == null && rule.label != null) v.bom_label = rule.label;
    if (v.bom_measure == null && rule.measure != null) v.bom_measure = rule.measure;
    if (v.bom_uom == null && rule.uom != null) v.bom_uom = rule.uom;
    if (v.bom_uom != null) v.bom_uom = normalizeUom(v.bom_uom);
    if (v.bom_category == null && rule.category != null) v.bom_category = rule.category;
    if (v.bom_multiplier == null && rule.multiplier != null && rule.multiplier !== "") v.bom_multiplier = rule.multiplier;
    if (rule.params && typeof rule.params === "object" && rule.params.material != null) {
      v.bom_param_material = rule.params.material;
    }
    if (rule.rounding && typeof rule.rounding === "object") {
      if (v.bom_rounding_mode == null && rule.rounding.mode != null) v.bom_rounding_mode = rule.rounding.mode;
      if (v.bom_rounding_step == null && rule.rounding.step != null) v.bom_rounding_step = rule.rounding.step;
    }
    return v;
  }

  function fillMaterialSelectForForm(form, materials) {
    var sel = form && form.querySelector("[name='bom_param_material']");
    if (!sel) return;
    materials = materials || (window.currentComponentMaterials || []);
    sel.innerHTML = "";
    var empty = document.createElement("option");
    empty.value = "";
    empty.textContent = "Select material";
    sel.appendChild(empty);
    materials.forEach(function(name) {
      var opt = document.createElement("option");
      opt.value = name;
      opt.textContent = name;
      sel.appendChild(opt);
    });
  }

  // Measured quantity is multiplied by this before rounding. Blank or invalid stays 1.
  function quantityMultiplier(input) {
    if (!input || input.value == null || String(input.value).trim() === "") return 1;
    var n = parseFloat(input.value);
    if (!isFinite(n)) return 1;
    return n < 0 ? 0 : n;
  }

  function formatMultiplier(value) {
    var n = Number(value);
    if (!isFinite(n)) return "1";
    if (Math.abs(n - Math.round(n)) < 1e-9) return String(Math.round(n));
    return String(Math.round(n * 10000) / 10000);
  }

  function formatPreviewQuantity(value) {
    var n = Number(value);
    if (!isFinite(n)) return "—";
    if (Math.abs(n - Math.round(n)) < 1e-9) return String(Math.round(n));
    return n.toFixed(4).replace(/\.?0+$/, "");
  }

  function cancelRulePreview() {
    if (previewTimer) {
      clearTimeout(previewTimer);
      previewTimer = null;
    }
    previewRequestId += 1;
  }

  function scheduleRulePreview() {
    if (previewTimer) clearTimeout(previewTimer);
    previewTimer = setTimeout(function() {
      previewTimer = null;
      requestRulePreview();
    }, PREVIEW_DEBOUNCE_MS);
  }

  function previewFieldChanged(target) {
    var name = target && target.getAttribute && target.getAttribute("name");
    return !!(name && PREVIEW_FIELDS[name]);
  }

  function measureDimension(measure) {
    var name = String(measure || "");
    if (name === "count") return "pcs";
    if (name === "bbox_volume" || name === "bbox_dimensions") return "volume";
    if (name === "smart_length" || name === "edge_length" || /perimeter$/.test(name)) return "length";
    if (/area$/.test(name)) return "area";
    return "";
  }

  function previewUnitLabel(block, lengthUnit) {
    var form = getBlockForm(block);
    var uomInput = form && form.querySelector("[name='bom_uom']");
    var measureInput = form && form.querySelector("[name='bom_measure']");
    var uom = uomInput ? uomInput.value : "";
    var key = (typeof UnitMap !== "undefined" && UnitMap.canonicalUom) ? UnitMap.canonicalUom(uom) : String(uom || "");
    if (key === "custom" || !key) key = measureDimension(measureInput && measureInput.value);
    var unit = lengthUnit || quotationLengthUnit || "m";
    if (typeof UnitMap !== "undefined" && UnitMap.labelFor) return UnitMap.labelFor(unit, key || "pcs");
    return key || "";
  }

  function applyPreview(block, preview, lengthUnit) {
    if (!block) return;
    var box = block.querySelector(".rule-preview");
    var valueEl = block.querySelector(".rule-preview-value");
    var qtyEl = block.querySelector(".rules-block-summary-qty");
    if (!valueEl) return;
    if (box) box.classList.remove("is-pending");
    block.removeAttribute("data-preview-state");
    if (!preview || preview.status === "incomplete") {
      valueEl.textContent = preview && preview.reason === "material" ? "Select a material" : "Select a measurement";
      if (qtyEl) qtyEl.textContent = "";
      return;
    }
    if (preview.status !== "ok") {
      valueEl.textContent = "Could not calculate";
      if (qtyEl) qtyEl.textContent = "";
      return;
    }
    var label = previewUnitLabel(block, lengthUnit);
    var unit = label ? (" " + label) : "";
    var one = formatPreviewQuantity(preview.quantity) + unit;
    var count = Number(preview.instance_count) || 1;
    if (count > 1) {
      var total = formatPreviewQuantity(preview.total_quantity) + unit;
      valueEl.textContent = "This component: " + one + "\n" + count + " instances in the model: " + total;
    } else {
      valueEl.textContent = one;
    }
    if (qtyEl) qtyEl.textContent = one;
  }

  function markPreviewPending(block) {
    if (!block) return;
    var box = block.querySelector(".rule-preview");
    var valueEl = block.querySelector(".rule-preview-value");
    var qtyEl = block.querySelector(".rules-block-summary-qty");
    if (box) box.classList.add("is-pending");
    block.setAttribute("data-preview-state", "pending");
    if (valueEl && !(qtyEl && qtyEl.textContent)) valueEl.textContent = "Calculating…";
  }

  function ruleReadyForPreview(rule) {
    var measure = rule && rule.measure != null ? String(rule.measure).trim() : "";
    if (!measure) return false;
    if (measure === "material_area") {
      var material = rule.params && rule.params.material != null ? String(rule.params.material).trim() : "";
      if (!material) return false;
    }
    return true;
  }

  function requestRulePreview() {
    if (!measurementRulesAllowed()) return;
    var container = document.getElementById("rules-container");
    if (!container) return;
    var forms = container.querySelectorAll("form");
    var rules = [];
    var anyComplete = false;
    for (var i = 0; i < forms.length; i++) {
      var rule = formValuesToRule(forms[i]);
      rules.push(rule);
      var block = forms[i].closest(".rules-block");
      if (!ruleReadyForPreview(rule)) {
        applyPreview(block, {
          status: "incomplete",
          reason: rule && rule.measure === "material_area" ? "material" : "measure"
        });
      } else {
        anyComplete = true;
        markPreviewPending(block);
      }
    }
    previewRequestId += 1;
    if (!anyComplete || typeof sketchup === "undefined" || !sketchup.preview_rules) return;
    sketchup.preview_rules(JSON.stringify({ request_id: previewRequestId, rules: rules }));
  }

  window.onRulePreview = function(payload) {
    if (!payload || payload.request_id !== previewRequestId) return;
    var container = document.getElementById("rules-container");
    if (!container) return;
    if (payload.status === "error") {
      container.querySelectorAll(".rules-block").forEach(function(block) {
        if (block.getAttribute("data-preview-state") === "pending") applyPreview(block, { status: "error" });
      });
      return;
    }
    var forms = container.querySelectorAll("form");
    (payload.previews || []).forEach(function(preview) {
      var form = forms[preview.index];
      if (!form) return;
      var block = form.closest(".rules-block");
      if (block && block.getAttribute("data-preview-state") === "pending") applyPreview(block, preview, payload.length_unit);
    });
  };

  function toggleMaterialParamVisibility(form) {
    var measureSelect = form && form.querySelector("[name='bom_measure']");
    var materialRow = form && form.querySelector(".measure-param--material");
    if (!measureSelect || !materialRow) return;
    materialRow.style.display = (measureSelect.value === "material_area") ? "" : "none";
  }

  function flushPendingSave() {
    var container = document.getElementById("rules-container");
    var dirty = container && container.querySelector("form.rules-form--dirty");
    if (!autoSaveTimer && !dirty) return;
    saveRules();
  }

  $(document).ready(function() {
    sketchup.ready();
    window.addEventListener("pagehide", flushPendingSave);
    ["exportable-flag", "traversable-flag"].forEach(function(id) {
      var flag = document.getElementById(id);
      if (!flag) return;
      flag.addEventListener("change", function() {
        if (id === "traversable-flag") {
          syncExportableWithTraversable();
          setMeasurementEditorVisible(measurementRulesAllowed());
          if (measurementRulesAllowed()) scheduleRulePreview();
          else cancelRulePreview();
        }
        setDirty(null);
        scheduleAutoSave();
      });
    });
    var container = document.getElementById("rules-container");
    if (container) {
      container.addEventListener("change", function(e) {
        var form = e.target && e.target.closest && e.target.closest("form");
        if (form) {
          setDirty(form);
          scheduleAutoSave();
          if (e.target && e.target.getAttribute("name") === "bom_measure") {
            toggleMaterialParamVisibility(form);
          }
          if (e.target && e.target.getAttribute("name") === "bom_uom") {
            refillMeasureOptionsForForm(form, { forceDefault: true });
          }
          var block = form.closest(".rules-block");
          if (block) updateBlockSummary(block);
          if (previewFieldChanged(e.target)) scheduleRulePreview();
        }
      });
      container.addEventListener("input", function(e) {
        var form = e.target && e.target.closest && e.target.closest("form");
        if (form) {
          setDirty(form);
          scheduleAutoSave();
          var block = form.closest(".rules-block");
          if (block) updateBlockSummary(block);
          if (previewFieldChanged(e.target)) scheduleRulePreview();
        }
      });
    }
  });