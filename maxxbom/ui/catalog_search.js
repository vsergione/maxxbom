    let catalogDropdownHideTimer = null;
    const MAX_RESULTS = 20;
    const CATALOG_API_RESULT_LIMIT = 10;
    const SEARCH_DEBOUNCE_MS = 250;

    let freeEditMode = false;
    let unitMap = null;
    let catalogConfigured = false;

    window.onCatalogSettings = function(data) {
      if (data) {
        Maxx.configure({ catalog: data.catalog || {} });
        catalogConfigured = !!(data.catalog && (data.catalog.datasource_name || data.catalog.api_adapter_name));
        freeEditMode = data.free_edit_mode === true || data.free_edit_mode === "true";
        unitMap = data.unit_map || null;
        if (typeof window.applyQuotationUomLabels === "function") {
          window.applyQuotationUomLabels(data.quotation_length_unit);
        }
      }
      updateCatalogStatusBanners();
      applyFreeEditMode();
      setCatalogDebugEnabled(!!(data && (data.dev_mode === true || data.dev_mode === "true")));
      renderCatalogDebugStatus();
      logCatalogDebug("settings loaded");
    };

    function applyFreeEditMode() {
      document.body.classList.toggle("free-edit-mode", freeEditMode);
      document.querySelectorAll(".free-edit-only").forEach((el) => {
        el.style.display = freeEditMode ? "" : "none";
      });
    }

    function isCatalogApiConfigured() {
      return Maxx.ready("catalog.search");
    }

    function catalogSettingsMissingMessage() {
      if (Maxx.error("catalog.search")) return Maxx.error("catalog.search");
      if (!catalogConfigured) return "Choose a product lookup data source in Plugin Settings.";
      return "The product lookup data source is missing a required setting.";
    }

    function setCatalogBanner(elId, visible, message) {
      const el = document.getElementById(elId);
      if (!el) return;
      if (visible && message) {
        el.textContent = message;
        el.style.display = "block";
        el.setAttribute("aria-hidden", "false");
      } else {
        el.textContent = "";
        el.style.display = "none";
        el.setAttribute("aria-hidden", "true");
      }
    }

    function updateCatalogStatusBanners() {
      if (freeEditMode) {
        setCatalogBanner("catalog-source-warning", false, "");
        setCatalogBanner("catalog-api-error", false, "");
        return;
      }
      if (!isCatalogApiConfigured()) {
        setCatalogBanner("catalog-source-warning", true, catalogSettingsMissingMessage());
      } else {
        setCatalogBanner("catalog-source-warning", false, "");
      }
    }

    function showCatalogApiError(message) {
      setCatalogBanner("catalog-api-error", true, message || "Catalog API request failed.");
    }

    function clearCatalogApiError() {
      setCatalogBanner("catalog-api-error", false, "");
    }

    let catalogDebugEnabled = false;

    function syncCatalogDebugDock() {
      const root = document.getElementById("catalog-debug");
      if (!root || root.hidden) {
        document.body.style.paddingBottom = "";
        return;
      }
      document.body.style.paddingBottom = (root.offsetHeight + 8) + "px";
    }

    function renderCatalogDebugStatus() {
      const el = document.getElementById("catalog-debug-status");
      if (!el) return;
      el.textContent = [
        "adapter=" + (Maxx.name("catalog.search") || "(none)"),
        "catalog=" + (Maxx.ready("catalog.search") ? "ready" : "not ready"),
        "freeEdit=" + (freeEditMode ? "on" : "off")
      ].join("\n");
      syncCatalogDebugDock();
    }

    function logCatalogDebug(message) {
      if (!catalogDebugEnabled) return;
      const line = new Date().toISOString().slice(11, 19) + "  " + message;
      console.log("[catalog]", message);
      const log = document.getElementById("catalog-debug-log");
      if (!log) return;
      log.textContent += (log.textContent ? "\n" : "") + line;
      log.scrollTop = log.scrollHeight;
      syncCatalogDebugDock();
    }

    function setCatalogDebugEnabled(on) {
      catalogDebugEnabled = !!on;
      const root = document.getElementById("catalog-debug");
      if (root) root.hidden = !catalogDebugEnabled;
      renderCatalogDebugStatus();
      syncCatalogDebugDock();
      if (catalogDebugEnabled) logCatalogDebug("debug on");
    }

    window.addEventListener("resize", syncCatalogDebugDock);

    function clearCatalogDebug() {
      const log = document.getElementById("catalog-debug-log");
      if (log) log.textContent = "";
    }

    window.clearCatalogDebug = clearCatalogDebug;

    function getDropdown(input) {
      const wrap = input.closest(".catalog-search-wrap");
      return wrap ? wrap.querySelector(".catalog-dropdown") : null;
    }

    function showCatalogResults(input, results) {
      const ul = getDropdown(input);
      if (!ul) return;
      ul.innerHTML = "";
      if (results.length === 0) {
        ul.style.display = "none";
        return;
      }
      const limit = results.slice(0, MAX_RESULTS);
      limit.forEach((item) => {
        const li = document.createElement("li");
        li.innerHTML = "<span class=\"item-code\">" + escapeHtml(item.code || "") + "</span>" +
          "<span class=\"item-name\">" + escapeHtml(item.name || "") + "</span>";
        if (String(item.source || "").toLowerCase() === "subgroup") {
          const badge = document.createElement("span");
          badge.className = "item-source";
          badge.textContent = "subgroup";
          li.appendChild(badge);
        }
        li.dataset.code = item.code || "";
        li.dataset.name = item.name || "";
        li.dataset.unit = item.unit || "";
        li.addEventListener("mousedown", (e) => {
          e.preventDefault();
          cancelCatalogSearch();
          selectCatalogItem(input, item);
          ul.style.display = "none";
        });
        ul.appendChild(li);
      });
      ul.style.display = "block";
    }

    function escapeHtml(s) {
      const div = document.createElement("div");
      div.textContent = s;
      return div.innerHTML;
    }

    /**
     * Map an external unit to a plugin UOM using the configured unit map.
     */
    function normalizeApiUnitToFormUom(apiUnit) {
      if (!apiUnit || typeof apiUnit !== "string") return "";
      if (typeof UnitMap === "undefined") return apiUnit.trim();
      return UnitMap.toPlugin(apiUnit, unitMap);
    }

    function selectCatalogItem(input, item, options) {
      const preserveMeasure = !!(options && options.preserveMeasure);
      const rowOrFieldset = input.closest("fieldset") || input.closest("tr");
      if (!rowOrFieldset) return;
      input.value = item.code || "";
      const labelInput = rowOrFieldset.querySelector("input[name=bom_label]");
      if (labelInput) labelInput.value = item.name || "";
      const categoryInput = rowOrFieldset.querySelector("input[name=bom_category]");
      if (categoryInput) categoryInput.value = item.category || "";
      const uomSelect = rowOrFieldset.querySelector("select[name=bom_uom]");
      let appliedUom = "";
      if (uomSelect && item.unit) {
        const formUom = normalizeApiUnitToFormUom(item.unit);
        if (formUom) {
          const opt = [...uomSelect.options].find((o) => o.value === formUom);
          if (opt) {
            uomSelect.value = formUom;
            appliedUom = formUom;
          }
        }
      }
      if (typeof window.refillMeasureOptionsForForm === "function") {
        window.refillMeasureOptionsForForm(rowOrFieldset, { forceDefault: !!appliedUom && !preserveMeasure });
      }
      if (typeof $ !== "undefined") {
        $(rowOrFieldset).find("input[name=bom]").val(item.code || "");
        $(rowOrFieldset).find("input[name=bom_label]").val(item.name || "");
        $(rowOrFieldset).find("input[name=bom_category]").val(item.category || "");
        if (appliedUom) $(rowOrFieldset).find("select[name=bom_uom]").val(appliedUom);
      }
      // Setting these fields does not fire input/change, which is all autosave
      // listens for. Volume has only bbox volume, so the measurement dropdown never
      // changes again and the rule would otherwise stay on the pieces default.
      if (typeof onCatalogItemApplied === "function") onCatalogItemApplied(rowOrFieldset);
    }

    function hideCatalogDropdown() {
      if (catalogDropdownHideTimer) clearTimeout(catalogDropdownHideTimer);
      catalogDropdownHideTimer = setTimeout(() => {
        document.querySelectorAll(".catalog-dropdown").forEach((ul) => { ul.style.display = "none"; });
        catalogDropdownHideTimer = null;
      }, 150);
    }

    function fetchCatalog(query, options) {
      const opts = options || {};
      const q = (query || "").trim();
      if (!q && !(opts.codes && opts.codes.length)) return Promise.resolve({ items: [], error: "" });
      const limit = opts.resultLimit != null ? opts.resultLimit : CATALOG_API_RESULT_LIMIT;
      const payload = { query: q, limit: limit };
      if (opts.codes) payload.codes = opts.codes;
      logCatalogDebug("catalog.search " + JSON.stringify(payload));
      if (!isCatalogApiConfigured()) {
        return Promise.reject(new Error(catalogSettingsMissingMessage()));
      }
      return Maxx.call("catalog.search", payload).then((result) => {
        if (!result.ok) {
          logCatalogDebug("  error " + (result.error || "request failed"));
          throw new Error(result.error || "Catalog request failed.");
        }
        logCatalogDebug("  items=" + result.items.length + (result.error ? " partial=" + result.error : ""));
        if (result.items.length) {
          logCatalogDebug("  " + result.items.slice(0, 8).map((item) => (item.code || "?") + "/" + (item.source || "")).join(", "));
        }
        return { items: result.items, error: result.error || "" };
      });
    }

    /**
     * Search catalog via active source (API or CSV).
     * Kept as searchCatalogViaApi for existing HTML onkeyup/onfocus handlers.
     */
    let catalogSearchTimer = null;
    let catalogSearchSeq = 0;

    function cancelCatalogSearch() {
      if (catalogSearchTimer) {
        clearTimeout(catalogSearchTimer);
        catalogSearchTimer = null;
      }
      catalogSearchSeq += 1;
    }

    function searchCatalogViaApi(input, options) {
      if (freeEditMode) return;
      if (catalogSearchTimer) {
        clearTimeout(catalogSearchTimer);
        catalogSearchTimer = null;
      }
      const query = (input.value || "").trim();
      if (!query) {
        catalogSearchSeq += 1;
        showCatalogResults(input, []);
        return Promise.resolve([]);
      }

      const seq = ++catalogSearchSeq;
      const searchOpts = Object.assign({}, options || {});
      return new Promise((resolve, reject) => {
        catalogSearchTimer = setTimeout(() => {
          catalogSearchTimer = null;
          if (seq !== catalogSearchSeq || (input.value || "").trim() !== query) {
            logCatalogDebug("search ignored: a newer query replaced " + JSON.stringify(query));
            resolve([]);
            return;
          }
          logCatalogDebug("search " + JSON.stringify(query));
          fetchCatalog(query, searchOpts)
            .then((outcome) => {
              if (seq !== catalogSearchSeq || (input.value || "").trim() !== query) {
                logCatalogDebug("results ignored: a newer query replaced " + JSON.stringify(query));
                resolve([]);
                return;
              }
              if (outcome.error) showCatalogApiError(outcome.error);
              else clearCatalogApiError();
              if (document.activeElement === input) {
                showCatalogResults(input, outcome.items);
              } else {
                logCatalogDebug("dropdown not shown: code field is not focused");
              }
              resolve(outcome.items);
            })
            .catch((err) => {
              if (seq !== catalogSearchSeq) {
                resolve([]);
                return;
              }
              console.error("searchCatalogViaApi failed:", err);
              if (document.activeElement === input) showCatalogResults(input, []);
              showCatalogApiError(err && err.message ? err.message : "Catalog API request failed.");
              reject(err);
            });
        }, SEARCH_DEBOUNCE_MS);
      });
    }

    function findExactCatalogMatch(query, results) {
      return (results || []).find((r) => (r.code || "").trim() === query) || null;
    }

    /**
     * Validate that the current code input value exists in the active catalog (exact match).
     * If not found: clear code, label, category and show message. Network errors do not clear.
     */
    function validateCodeWithApi(input) {
      const query = (input.value || "").trim();
      if (!query) return Promise.resolve();

      return fetchCatalog(query, { resultLimit: 50, codes: [query] })
        .then((outcome) => {
          const exact = findExactCatalogMatch(query, outcome.items);
          if (outcome.error) {
            console.error("validateCodeWithApi failed:", outcome.error);
            showCatalogApiError(outcome.error);
            if (exact) selectCatalogItem(input, exact, { preserveMeasure: true });
            return;
          }
          clearCatalogApiError();
          if (exact) {
            selectCatalogItem(input, exact, { preserveMeasure: true });
            return;
          }
          clearCodeAndRelated(input);
          alert("Product code not found. Please select a code from the list.");
        })
        .catch((err) => {
          console.error("validateCodeWithApi failed:", err);
          showCatalogApiError(err && err.message ? err.message : "Catalog API request failed.");
          // Do not clear on network error
        });
    }

    function clearCodeAndRelated(input) {
      const rowOrFieldset = input.closest("fieldset") || input.closest("tr");
      if (!rowOrFieldset) return;
      const codeInput = rowOrFieldset.querySelector("input[name=bom]");
      const labelInput = rowOrFieldset.querySelector("input[name=bom_label]");
      const categoryInput = rowOrFieldset.querySelector("input[name=bom_category]");
      if (codeInput) codeInput.value = "";
      if (labelInput) labelInput.value = "";
      if (categoryInput) categoryInput.value = "";
      const form = rowOrFieldset.closest("form");
      if (form && typeof setDirty === "function") setDirty(form);
      const block = rowOrFieldset.closest(".rules-block");
      if (block && typeof updateBlockSummary === "function") updateBlockSummary(block);
    }

    const VALIDATE_CODE_BLUR_DELAY_MS = 220;

    /**
     * Call from code input onblur: after a short delay (so dropdown click is processed), validate code.
     * Skipped in free edit mode. Otherwise the selected product lookup data source checks the code.
     */
    function validateCodeOnBlur(input) {
      if (freeEditMode) return;
      if (validateCodeBlurTimer) clearTimeout(validateCodeBlurTimer);
      validateCodeBlurTimer = setTimeout(() => {
        validateCodeBlurTimer = null;
        validateCodeWithApi(input);
      }, VALIDATE_CODE_BLUR_DELAY_MS);
    }
    let validateCodeBlurTimer = null;

    window.validateCodeOnBlur = validateCodeOnBlur;
    window.searchCatalogViaApi = searchCatalogViaApi;
    window.hideCatalogDropdown = hideCatalogDropdown;

    (function requestCatalogSettings() {
      if (typeof sketchup !== "undefined" && sketchup.get_catalog_settings) sketchup.get_catalog_settings();
    })();
