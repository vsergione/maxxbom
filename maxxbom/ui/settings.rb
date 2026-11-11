# ui/settings.rb — Plugin settings dialog
# ------------------------------------------------------------------------------
# Persists settings via Sketchup.write_default / read_default (local machine).
# API and CSV connections are data sources: named instances of an installed
# adapter (see datasources.rb). Older FileMaker URL and key preferences are
# read once, when that plugin is loaded.
# ------------------------------------------------------------------------------
require "base64"

module Logimaxx
  module MaxxBOM
    module UI
      module Settings
        DIALOG_ID = :settings
        PREF_NAMESPACE = "Logimaxx_CialonaBOMExporter".freeze
        PREF_KEY_IMPORT_API_URL = "import_api_url".freeze
        PREF_KEY_OFFER_LINES_API_URL = "offer_lines_api_url".freeze
        PREF_KEY_IMPORT_API_KEY = "import_api_key".freeze
        PREF_KEY_CATALOG_API_URL = "catalog_api_url".freeze
        PREF_KEY_CATALOG_API_KEY = "catalog_api_key".freeze
        PREF_KEY_CATALOG_SOURCE = "catalog_source".freeze
        PREF_KEY_FREE_EDIT_MODE = "free_edit_mode".freeze
        PREF_KEY_DEBUG_FACILITY = "debug_facility".freeze
        PREF_KEY_UNIT_MAP = "unit_map".freeze
        PREF_KEY_QUOTATION_LENGTH_UNIT = "quotation_length_unit".freeze
        PREF_KEY_CATALOG_CSV_PATH = "catalog_csv_path".freeze
        PREF_KEY_CATALOG_CSV_FIELDS = "catalog_csv_fields".freeze
        PLUGIN_UOMS = %w[pcs area length volume custom].freeze
        # Rules saved before quantity kinds. First match wins; "mtr" precedes "m".
        LEGACY_UOM_KEYS = {
          "area" => %w[m2],
          "length" => %w[mtr m],
          "volume" => %w[m3]
        }.freeze
        QUANTITY_LABELS = {
          "pcs" => "Pieces",
          "area" => "Area",
          "length" => "Length",
          "volume" => "Volume",
          "custom" => "Custom"
        }.freeze
        QUOTATION_LENGTH_UNITS = %w[m cm mm ft in].freeze
        DEFAULT_QUOTATION_LENGTH_UNIT = "m".freeze
        # Inches (SketchUp internal length) → one quotation length unit.
        QUOTATION_LENGTH_FACTORS = {
          "in" => 1.0,
          "ft" => 1.0 / 12.0,
          "mm" => 25.4,
          "cm" => 2.54,
          "m" => 0.0254
        }.freeze
        # Written on export for area / length / volume when the name is still a standard one.
        QUOTATION_EXPORT_NAMES = {
          "m" => { "area" => "m2", "length" => "mtr", "volume" => "m3" },
          "cm" => { "area" => "cm2", "length" => "cm", "volume" => "cm3" },
          "mm" => { "area" => "mm2", "length" => "mm", "volume" => "mm3" },
          "ft" => { "area" => "ft2", "length" => "ft", "volume" => "ft3" },
          "in" => { "area" => "in2", "length" => "in", "volume" => "in3" }
        }.freeze
        # Extra catalog names. The export name is accepted on its own.
        # The meter list is the historical default, so an untouched map still matches it.
        QUOTATION_ACCEPT = {
          "m" => {
            "area" => ["m²"],
            "length" => ["mtr.", "m", "meter", "meters", "linear meter"],
            "volume" => ["m³", "m3.", "cubic meter", "cubic meters"]
          },
          "cm" => {
            "area" => ["cm²"],
            "length" => ["centimeter", "centimeters"],
            "volume" => ["cm³", "cubic centimeter", "cubic centimeters"]
          },
          "mm" => {
            "area" => ["mm²"],
            "length" => ["millimeter", "millimeters"],
            "volume" => ["mm³", "cubic millimeter", "cubic millimeters"]
          },
          "ft" => {
            "area" => ["ft²", "sq ft", "sqft", "square foot", "square feet"],
            "length" => ["lf", "foot", "feet", "linear ft", "linear feet"],
            "volume" => ["ft³", "cu ft", "cuft", "cubic foot", "cubic feet"]
          },
          "in" => {
            "area" => ["in²", "sq in", "sqin", "square inch", "square inches"],
            "length" => ["inch", "inches"],
            "volume" => ["in³", "cu in", "cuin", "cubic inch", "cubic inches"]
          }
        }.freeze
        CSV_PRODUCT_FIELDS = %w[code name unit category price].freeze
        CATALOG_SOURCE_API = "api".freeze
        CATALOG_SOURCE_CSV = "csv".freeze

        def self.template_path
          File.join(UI::UI_DIR, "settings.html")
        end

        def self.opts
          { width: 560, height: 720, title: "#{Logimaxx::MaxxBOM::DISPLAY_NAME} — Settings" }
        end

        def self.register(dialog)
          dialog.add_action_callback('get_settings') { |*_| on_get_settings(dialog) }
          dialog.add_action_callback('save_settings') { |_ctx, b64_str| on_save_settings(dialog, b64_str) }
          dialog.add_action_callback('load_api_adapter') { |*_| on_load_api_adapter(dialog) }
          dialog.add_action_callback('load_bundled_api_adapter') { |*args| on_load_bundled_api_adapter(dialog, args) }
          dialog.add_action_callback('remove_api_adapter') { |*args| on_remove_api_adapter(dialog, args) }
          dialog.add_action_callback('add_data_source') { |_ctx, payload| on_add_data_source(dialog, payload) }
          dialog.add_action_callback('remove_data_source') { |*args| on_remove_data_source(dialog, args) }
          dialog.add_action_callback('pick_datasource_file') { |*args| on_pick_datasource_file(dialog, args) }
          dialog.add_action_callback('close_dialog') { dialog.close }
          dialog.add_action_callback('open_external') { |*args| on_open_external(args) }
        end

        # About tab links. Only these open, in the system browser or mail client.
        EXTERNAL_LINKS = {
          "product" => "https://logimaxx.ro/ro/products/maxxbom",
          "website" => "https://logimaxx.ro",
          "contact" => "mailto:contact@logimaxx.ro",
          "erp_quote" => "mailto:contact@logimaxx.ro?subject=MaxxBOM%20%E2%80%94%20ERP%20integration&body=" \
                         "Hello%2C%0A%0AWe%20would%20like%20MaxxBOM%20connected%20to%20our%20system.%0A%0A" \
                         "System%20%2F%20ERP%3A%20%0AWhat%20should%20it%20do%20(catalog%2C%20offers%2C%20orders)%3A%20%0A" \
                         "Contact%20person%20and%20phone%3A%20%0A"
        }.freeze

        def self.on_open_external(args)
          url = EXTERNAL_LINKS[callback_string(args)]
          ::UI.openURL(url) if url
          nil
        end

        def self.extension_version
          defined?(Logimaxx::MaxxBOM::VERSION) ? Logimaxx::MaxxBOM::VERSION.to_s : ""
        end

        def self.on_get_settings(dialog)
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsLoaded", dialog_state.merge(
            free_edit_mode: stored_free_edit_mode,
            dev_mode: Logimaxx::MaxxBOM.dev_mode?,
            version: extension_version,
            sketchup_version: Sketchup.version.to_s,
            debug_facility: stored_debug_facility,
            unit_map: stored_unit_map,
            quotation_length_unit: stored_quotation_length_unit
          ))
        rescue StandardError => e
          report_adapter_error(dialog, e)
        end

        # File dialogs and message boxes must not run inside an HtmlDialog callback.
        # execute_script right after openpanel is also dropped, so UI updates wait
        # for a second timer once the file dialog has closed.
        def self.on_load_api_adapter(dialog)
          ::UI.start_timer(0, false) do
            begin
              path = Adapters.pick_path
              if path.nil? || path.to_s.strip.empty?
                post_to_dialog(dialog) { deliver_adapters(dialog, { cancelled: true }) }
                next
              end
              manifest = Adapters.install(path)
              post_to_dialog(dialog) do
                deliver_adapters(dialog, {
                  loaded_id: manifest["id"],
                  message: "#{manifest["name"]} loaded."
                })
              end
            rescue StandardError => e
              report_adapter_error(dialog, e)
            end
          end
          nil
        end

        def self.on_load_bundled_api_adapter(dialog, args)
          adapter_id = callback_string(args)
          ::UI.start_timer(0, false) do
            begin
              raise ArgumentError, "Missing adapter id." if adapter_id.empty?
              manifest = Adapters.install_discovered(adapter_id)
              deliver_adapters(dialog, {
                loaded_id: manifest["id"],
                message: "#{manifest["name"]} loaded."
              })
            rescue StandardError => e
              report_adapter_error(dialog, e)
            end
          end
          nil
        end

        def self.on_remove_api_adapter(dialog, args)
          adapter_id = callback_string(args)
          ::UI.start_timer(0, false) do
            begin
              raise ArgumentError, "Missing adapter id." if adapter_id.empty?
              removed = Adapters.remove(adapter_id)
              DataSources.drop_adapter(adapter_id)
              deliver_adapters(dialog, { removed_id: removed, message: "Adapter removed." })
            rescue StandardError => e
              report_adapter_error(dialog, e)
            end
          end
          nil
        end

        # SketchUp passes the dialog context plus the JS arguments. Older builds
        # pass only the JS arguments. Keep the first plain string.
        def self.callback_string(args)
          Array(args).flatten.each do |value|
            next if value.nil?
            text = value.to_s.strip
            next if text.empty? || text.start_with?("#<") || text.include?("HtmlDialog")
            return text.gsub(/\A["']|["']\z/, "")
          end
          ""
        end

        def self.post_to_dialog(dialog)
          ::UI.start_timer(0, false) { yield }
        end

        def self.deliver_adapters(dialog, extra)
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onAdaptersChanged", dialog_state.merge(extra))
          BOMExporter.push_adapter_state
          push_catalog_to_open_rules
        end

        def self.report_adapter_error(dialog, error)
          message = error.message.to_s
          detail = Array(error.backtrace).first(8).join("\n")
          puts "[#{Logimaxx::MaxxBOM::DISPLAY_NAME}] #{message}\n#{detail}"
          post_to_dialog(dialog) do
            begin
              Logimaxx::MaxxBOM::UI.inject_json(dialog, "onAdaptersChanged", { error: true, message: message })
            rescue StandardError
              nil
            end
            ::UI.messagebox("#{Logimaxx::MaxxBOM::DISPLAY_NAME}\n\n#{message}")
          end
        end

        def self.dialog_state
          DataSources.ui_state.merge(legacy_filemaker_pending: legacy_filemaker_pending?)
        end

        def self.on_add_data_source(dialog, raw)
          raw = raw.is_a?(Array) ? (raw[0] || raw) : raw
          data = JSON.parse(Base64.strict_decode64(raw.to_s.strip))
          ds = DataSources.create(data["name"] || data[:name], data["adapter_id"] || data[:adapter_id])
          deliver_adapters(dialog, { added_id: ds["id"], message: "#{ds["name"]} added." })
        rescue StandardError => e
          report_adapter_error(dialog, e)
        end

        def self.on_remove_data_source(dialog, args)
          id = callback_string(args)
          ::UI.start_timer(0, false) do
            begin
              raise ArgumentError, "Missing data source." if id.empty?
              DataSources.remove(id)
              deliver_adapters(dialog, { removed_datasource_id: id, message: "Data source removed." })
            rescue StandardError => e
              report_adapter_error(dialog, e)
            end
          end
          nil
        end

        def self.on_pick_datasource_file(dialog, args)
          encoded = callback_string(args)
          ::UI.start_timer(0, false) do
            begin
              spec = JSON.parse(Base64.strict_decode64(encoded))
              id = (spec["id"] || spec[:id]).to_s
              key = (spec["key"] || spec[:key]).to_s
              path = ::UI.openpanel("Select file", "", "CSV|*.csv||")
              path = path.first if path.is_a?(Array)
              next if path.nil? || path.to_s.strip.empty?
              stored = normalize_catalog_csv_path(path)
              status = csv_header_status(stored)
              post_to_dialog(dialog) do
                Logimaxx::MaxxBOM::UI.inject_json(dialog, "onDatasourceFilePicked", {
                  id: id,
                  key: key,
                  path: stored,
                  headers: status[:headers],
                  error: status[:error]
                })
              end
            rescue StandardError => e
              report_adapter_error(dialog, e)
            end
          end
          nil
        end

        def self.on_save_settings(dialog, b64_str)
          # JS sends Base64-encoded JSON so the SketchUp bridge doesn't eval the string as Ruby.
          raw = b64_str.is_a?(Array) ? (b64_str[0] || b64_str) : b64_str
          raw = raw.to_s.strip
          if raw.empty?
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", { error: true, message: "No data received." })
            return
          end
          begin
            json_str = Base64.strict_decode64(raw)
            data = JSON.parse(json_str)
          rescue StandardError => e
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", { error: true, message: "Invalid data: #{e.message}" })
            return
          end
          free_edit_val = data.key?("free_edit_mode") ? data["free_edit_mode"] : data[:free_edit_mode]
          free_edit_mode = (free_edit_val == true || free_edit_val.to_s.downcase == "true")
          debug_facility = nil
          if data.key?("debug_facility") || data.key?(:debug_facility)
            debug_val = data.key?("debug_facility") ? data["debug_facility"] : data[:debug_facility]
            debug_facility = (debug_val == true || debug_val.to_s.downcase == "true")
          end
          begin
            raw_unit = data.key?("quotation_length_unit") ? data["quotation_length_unit"] : data[:quotation_length_unit]
            quotation_length_unit = raw_unit.nil? ? stored_quotation_length_unit : normalize_quotation_length_unit(raw_unit)
            unit_map_value = data.key?("unit_map") ? data["unit_map"] : data[:unit_map]
            mapped_units = unit_map_value.nil? ? stored_unit_map : normalize_unit_map(unit_map_value)
            mapped_units = apply_quotation_names(mapped_units, quotation_length_unit)
            unit_map = encode_pref_json(normalize_unit_map(mapped_units))
            source_values = data.key?("data_source_values") ? data["data_source_values"] : data[:data_source_values]
            catalog_role = data.key?("catalog_data_source") ? data["catalog_data_source"] : data[:catalog_data_source]
            DataSources.apply_form(source_values, catalog_role, enforce_required: !free_edit_mode)
          rescue StandardError => e
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", { error: true, message: "Invalid settings: #{e.message}" })
            return
          end
          begin
            write_free_edit_mode(free_edit_mode)
            if !debug_facility.nil? && Logimaxx::MaxxBOM.dev_mode?
              Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_DEBUG_FACILITY, debug_facility ? "true" : "false")
            end
            write_pref_string(PREF_KEY_UNIT_MAP, unit_map)
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_QUOTATION_LENGTH_UNIT, quotation_length_unit)
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", {})
            push_catalog_to_open_rules
            BOMExporter.push_adapter_state
          rescue StandardError => e
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", { error: true, message: e.message })
          end
        end

        # Values written by builds that stored the FileMaker connection in the extension.
        # Read when the FileMaker plugin is loaded for the first time.
        def self.legacy_filemaker_settings
          {
            "catalog_api_url" => legacy_catalog_api_url,
            "import_api_url" => legacy_import_api_url.strip,
            "offer_lines_api_url" => legacy_offer_lines_api_url,
            "api_key" => legacy_filemaker_api_key
          }
        end

        def self.legacy_filemaker_pending?
          return false if Adapters.loaded_ids.include?("filemaker")
          legacy_filemaker_settings.values.any? { |value| !value.to_s.strip.empty? }
        end

        def self.legacy_import_api_url
          Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_IMPORT_API_URL).to_s
        end

        def self.legacy_catalog_api_url
          Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_CATALOG_API_URL).to_s
        end

        def self.legacy_offer_lines_api_url
          raw = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_OFFER_LINES_API_URL)
          return raw.to_s.strip unless raw.nil?
          derive_offer_lines_url(legacy_import_api_url)
        end

        def self.legacy_filemaker_api_key
          import_key = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_IMPORT_API_KEY).to_s.strip
          return import_key unless import_key.empty?
          Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_CATALOG_API_KEY).to_s.strip
        end

        def self.derive_offer_lines_url(import_url)
          url = import_url.to_s.strip
          return "" if url.empty? || !url.include?("import-sketch")
          url.sub("import-sketch", "get-offer-lines")
        end

        def self.stored_api_adapter_name
          DataSources.role_name(:orders)
        end

        # Read once, when data sources are created from an older settings file.
        # An unset choice stays on the API when an older FileMaker connection or a loaded adapter exists.
        def self.stored_catalog_source
          v = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_CATALOG_SOURCE).to_s.strip.downcase
          return CATALOG_SOURCE_CSV if v == CATALOG_SOURCE_CSV
          return CATALOG_SOURCE_API if v == CATALOG_SOURCE_API
          return CATALOG_SOURCE_API if legacy_filemaker_pending? || Adapters.active_manifest
          CATALOG_SOURCE_CSV
        end

        def self.stored_free_edit_mode
          Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_FREE_EDIT_MODE).to_s.downcase == "true"
        end

        def self.write_free_edit_mode(value)
          Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_FREE_EDIT_MODE, value ? "true" : "false")
        end

        # Debug docks on the rules window and the export dialog.
        # Shown only while the extension is loaded from a checkout. Default on.
        def self.stored_debug_facility
          v = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_DEBUG_FACILITY)
          return true if v.nil? || v.to_s.strip.empty?
          v.to_s.downcase != "false"
        end

        def self.debug_facility_visible?
          Logimaxx::MaxxBOM.dev_mode? && stored_debug_facility
        end

        # SketchUp.read_default evals the stored string. A Windows path such as
        # C:\Users\...\catalog.csv is then read as escapes: \c becomes a control
        # character and the file is reported missing. Forward slashes survive
        # that eval, and Windows opens them.
        def self.normalize_catalog_csv_path(path)
          path.to_s.strip.delete("\0").tr("\\", "/")
        end

        # True when read_default already ate the backslashes (control characters,
        # or a drive letter no longer followed by a separator).
        def self.catalog_csv_path_damaged?(path)
          text = normalize_catalog_csv_path(path)
          return false if text.empty?
          return true if text.match?(/[\x00-\x1f\x7f]/)
          text.match?(/\A[A-Za-z]:[^\/]/)
        end

        # A raw path from an older build is still accepted. New saves store
        # {"path":...} as Base64. SketchUp.write_default refuses an empty string
        # and leaves the previous file in place, so a cleared path has to be a
        # non-empty payload that reads back as blank.
        def self.stored_catalog_csv_path
          raw = read_pref(PREF_KEY_CATALOG_CSV_PATH)
          decoded = decode_pref_json(raw)
          if decoded.is_a?(Hash) && (decoded.key?("path") || decoded.key?(:path))
            return normalize_catalog_csv_path(decoded["path"] || decoded[:path])
          end
          normalize_catalog_csv_path(raw)
        rescue ScriptError
          ""
        end

        def self.write_catalog_csv_path(path)
          write_pref_string(PREF_KEY_CATALOG_CSV_PATH, encode_pref_json({ "path" => path.to_s }))
        end

        def self.push_catalog_to_open_rules
          rules = Logimaxx::MaxxBOM.dialogs[:rules]
          Rules.on_get_catalog_settings(rules) if rules
        rescue StandardError
          nil
        end

        def self.resolved_catalog_csv_path
          stored_catalog_csv_path
        end

        def self.empty_catalog_csv_fields
          CSV_PRODUCT_FIELDS.each_with_object({}) { |field, map| map[field] = "" }
        end

        def self.normalize_catalog_csv_fields(value)
          raw = value.is_a?(String) ? JSON.parse(value) : value
          raw = {} unless raw.is_a?(Hash)
          result = {}
          CSV_PRODUCT_FIELDS.each do |field|
            column = raw.key?(field) ? raw[field] : raw[field.to_sym]
            result[field] = column.to_s.strip
          end
          result
        end

        def self.stored_catalog_csv_fields
          parsed = decode_pref_json(read_pref(PREF_KEY_CATALOG_CSV_FIELDS))
          return empty_catalog_csv_fields if parsed.nil?
          normalize_catalog_csv_fields(parsed)
        rescue StandardError
          empty_catalog_csv_fields
        end

        # { headers:, error: } for the first row.
        # error is "damaged", "missing", "invalid", or nil.
        def self.csv_header_status(path)
          path = normalize_catalog_csv_path(path)
          return { headers: [], error: nil } if path.empty?
          if catalog_csv_path_damaged?(path)
            return { headers: [], error: "damaged" }
          end
          unless File.file?(path)
            return { headers: [], error: "missing" }
          end
          raw = File.read(path).sub(/\A\xEF\xBB\xBF/, "")
          rows = Rules.parse_csv(raw)
          headers = []
          seen = {}
          (rows.shift || []).each do |header|
            name = header.to_s.strip
            next if name.empty? || seen[name]
            seen[name] = true
            headers << name
          end
          { headers: headers, error: nil }
        rescue StandardError
          { headers: [], error: "invalid" }
        end

        def self.normalize_quotation_length_unit(value)
          unit = value.to_s.strip.downcase
          return DEFAULT_QUOTATION_LENGTH_UNIT if unit.empty?
          return unit if QUOTATION_LENGTH_UNITS.include?(unit)
          raise ArgumentError, "Unknown quotation unit."
        end

        def self.stored_quotation_length_unit
          unit = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_QUOTATION_LENGTH_UNIT).to_s.strip.downcase
          QUOTATION_LENGTH_UNITS.include?(unit) ? unit : DEFAULT_QUOTATION_LENGTH_UNIT
        end

        def self.quotation_length_factor(unit = nil)
          key = unit.nil? ? stored_quotation_length_unit : normalize_quotation_length_unit(unit)
          QUOTATION_LENGTH_FACTORS[key]
        end

        # m2 / mtr / m3 and the bare "m" used by an older schema become quantity kinds.
        def self.normalize_plugin_uom(value)
          uom = value.to_s.strip
          return uom if uom.empty?
          key = uom.downcase
          LEGACY_UOM_KEYS.each do |quantity, legacy|
            return quantity if legacy.any? { |old| old.casecmp(key).zero? }
          end
          return key if PLUGIN_UOMS.include?(key)
          uom
        end

        def self.quantity_label(uom)
          QUANTITY_LABELS[normalize_plugin_uom(uom)] || uom.to_s
        end

        # Replaces area / length / volume export names and accepted catalog names
        # that are still a standard set with the set for this quotation unit.
        # A custom export name or a custom accepted list stays. Pieces and custom do not move.
        def self.apply_quotation_names(unit_map, unit)
          proposed = rewrite_quotation_names(unit_map, unit, true)
          return proposed if unit_map_safe?(proposed)
          exports_only = rewrite_quotation_names(unit_map, unit, false)
          return exports_only if unit_map_safe?(exports_only)
          unit_map
        end

        def self.rewrite_quotation_names(unit_map, unit, replace_accept)
          key = normalize_quotation_length_unit(unit)
          names = QUOTATION_EXPORT_NAMES[key]
          accepts = QUOTATION_ACCEPT[key]
          unit_map.each_with_object({}) do |(uom, entry), result|
            export_name = entry["export"].to_s
            accept = Array(entry["accept"])
            export_name = names[uom] if names[uom] && standard_quotation_export_name?(uom, export_name)
            if replace_accept && accepts[uom] && standard_quotation_accept?(uom, accept)
              accept = accepts[uom].dup
            end
            result[uom] = { "export" => export_name, "accept" => accept }
          end
        end

        def self.unit_map_safe?(unit_map)
          normalize_unit_map(unit_map)
          true
        rescue ArgumentError
          false
        end

        def self.standard_quotation_export_name?(uom, name)
          text = name.to_s.strip
          return true if text.empty?
          QUOTATION_EXPORT_NAMES.each_value.any? do |names|
            standard = names[uom]
            standard && standard.casecmp(text).zero?
          end
        end

        def self.standard_quotation_accept?(uom, names)
          keys = Array(names).map { |name| name.to_s.strip }.reject(&:empty?).map(&:downcase).uniq.sort
          QUOTATION_ACCEPT.each_value.any? do |lists|
            standard = lists[uom]
            next false unless standard
            keys == standard.map { |name| name.downcase }.uniq.sort
          end
        end

        # Quantity kind => { "export" => external name written on BOM lines,
        #                    "accept" => extra names read from catalog and offer lines }.
        # The quantity kind itself is always accepted. Export defaults to the meter name.
        def self.default_unit_map
          {
            "pcs" => { "export" => "pcs", "accept" => ["stuks", "stuk", "pieces"] },
            "area" => { "export" => "m2", "accept" => ["m²"] },
            "length" => { "export" => "mtr", "accept" => ["mtr.", "m", "meter", "meters", "linear meter"] },
            "volume" => { "export" => "m3", "accept" => ["m³", "m3.", "cubic meter", "cubic meters"] },
            "custom" => { "export" => "custom", "accept" => [] }
          }
        end

        def self.unit_map_entry(raw, uom)
          entry = raw[uom] || raw[uom.to_sym]
          if entry.nil?
            Array(LEGACY_UOM_KEYS[uom]).each do |old|
              entry = raw[old] || raw[old.to_sym]
              break unless entry.nil?
            end
          end
          entry.is_a?(Hash) ? entry : default_unit_map[uom]
        end

        def self.normalize_unit_map(value)
          raw = value.is_a?(String) ? JSON.parse(value) : value
          raw = {} unless raw.is_a?(Hash)
          result = {}
          seen = {}
          fallback = default_unit_map
          PLUGIN_UOMS.each do |uom|
            entry = unit_map_entry(raw, uom)
            export_name = (entry["export"] || entry[:export] || fallback[uom]["export"]).to_s.strip
            export_name = fallback[uom]["export"] if export_name.empty? || export_name.casecmp(uom).zero?
            accept = entry["accept"] || entry[:accept] || []
            accept = accept.to_s.split(",") unless accept.is_a?(Array)
            names = []
            accept.each do |name|
              text = name.to_s.strip
              next if text.empty?
              next if text.casecmp(uom).zero? || text.casecmp(export_name).zero?
              next if names.any? { |existing| existing.casecmp(text).zero? }
              names << text
            end
            label = quantity_label(uom)
            ([uom, export_name] + names).each do |token|
              key = token.downcase
              if seen[key] && seen[key] != uom
                raise ArgumentError, %(Unit alias "#{token}" is used by both #{quantity_label(seen[key])} and #{label}.)
              end
              seen[key] = uom
            end
            result[uom] = { "export" => export_name, "accept" => names }
          end
          result
        end

        def self.stored_unit_map
          parsed = decode_pref_json(read_pref(PREF_KEY_UNIT_MAP))
          map = parsed.nil? ? default_unit_map : normalize_unit_map(parsed)
          apply_quotation_names(map, stored_quotation_length_unit)
        rescue StandardError
          apply_quotation_names(default_unit_map, DEFAULT_QUOTATION_LENGTH_UNIT)
        end

        # read_default evals the stored text and drops or unescapes quotes, so a
        # JSON object does not round-trip. Base64 is letters, digits, and + / =.
        def self.encode_pref_json(obj)
          Base64.strict_encode64(JSON.generate(obj))
        end

        def self.decode_pref_json(raw)
          return raw if raw.is_a?(Hash)
          text = raw.to_s.delete("\0").strip
          return nil if text.empty?
          if pref_base64?(text)
            return JSON.parse(Base64.strict_decode64(text))
          end
          JSON.parse(text)
        rescue StandardError, ScriptError
          nil
        end

        def self.pref_base64?(text)
          !text.empty? && (text.length % 4).zero? && text.match?(/\A[A-Za-z0-9+\/]*={0,2}\z/)
        end

        def self.read_pref(key)
          Sketchup.read_default(PREF_NAMESPACE, key)
        rescue ScriptError
          nil
        end

        def self.write_pref_string(key, text)
          written = Sketchup.write_default(PREF_NAMESPACE, key, text)
          raise ArgumentError, "SketchUp could not store settings." if written == false
          stored = read_pref(key).to_s.delete("\0").strip
          return text if stored == text
          raise ArgumentError, "SketchUp could not store settings."
        end
      end
    end
  end
end
