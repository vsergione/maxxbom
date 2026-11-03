# ui/settings.rb — Plugin settings dialog
# ------------------------------------------------------------------------------
# Persists settings via Sketchup.write_default / read_default (local machine).
# API connections come from adapter plugins loaded in this dialog (see adapters.rb).
# Older FileMaker URL and key preferences are read once, when that plugin is loaded.
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
        PREF_KEY_CATALOG_VALIDATE_CODES = "catalog_validate_codes".freeze
        PREF_KEY_CATALOG_SOURCE = "catalog_source".freeze
        PREF_KEY_FREE_EDIT_MODE = "free_edit_mode".freeze
        PREF_KEY_UNIT_MAP = "unit_map".freeze
        PREF_KEY_QUOTATION_LENGTH_UNIT = "quotation_length_unit".freeze
        PREF_KEY_CATALOG_CSV_PATH = "catalog_csv_path".freeze
        PREF_KEY_CATALOG_CSV_FIELDS = "catalog_csv_fields".freeze
        PLUGIN_UOMS = %w[pcs m2 mtr m3 custom].freeze
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
          "m" => { "m2" => "m2", "mtr" => "mtr", "m3" => "m3" },
          "cm" => { "m2" => "cm2", "mtr" => "cm", "m3" => "cm3" },
          "mm" => { "m2" => "mm2", "mtr" => "mm", "m3" => "mm3" },
          "ft" => { "m2" => "ft2", "mtr" => "ft", "m3" => "ft3" },
          "in" => { "m2" => "in2", "mtr" => "in", "m3" => "in3" }
        }.freeze
        CSV_PRODUCT_FIELDS = %w[code name unit category].freeze
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
          dialog.add_action_callback('remove_api_adapter') { |_ctx, adapter_id| on_remove_api_adapter(dialog, adapter_id) }
          dialog.add_action_callback('pick_catalog_csv') { |*_| on_pick_catalog_csv(dialog) }
          dialog.add_action_callback('preview_catalog_csv') { |_ctx, path| on_preview_catalog_csv(dialog, path) }
          dialog.add_action_callback('close_dialog') { dialog.close }
        end

        def self.on_get_settings(dialog)
          csv_status = csv_header_status(resolved_catalog_csv_path)
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsLoaded", adapters_dialog_state.merge(
            catalog_validate_codes: stored_catalog_validate_codes,
            catalog_source: stored_catalog_source,
            free_edit_mode: stored_free_edit_mode,
            unit_map: stored_unit_map,
            quotation_length_unit: stored_quotation_length_unit,
            catalog_csv_path: stored_catalog_csv_path,
            catalog_csv_fields: stored_catalog_csv_fields,
            catalog_csv_headers: csv_status[:headers],
            catalog_csv_header_error: csv_status[:error]
          ))
        end

        def self.on_load_api_adapter(dialog)
          path = Adapters.pick_path
          return if path.nil? || path.to_s.strip.empty?
          manifest = Adapters.install(path)
          deliver_adapters(dialog, {
            loaded_id: manifest["id"],
            message: "#{manifest["name"]} loaded."
          })
        rescue StandardError => e
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onAdaptersChanged", { error: true, message: e.message })
        end

        def self.on_remove_api_adapter(dialog, adapter_id)
          adapter_id = adapter_id[0] if adapter_id.is_a?(Array)
          removed = Adapters.remove(adapter_id)
          deliver_adapters(dialog, { removed_id: removed, message: "Adapter removed." })
        rescue StandardError => e
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onAdaptersChanged", { error: true, message: e.message })
        end

        def self.deliver_adapters(dialog, extra)
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onAdaptersChanged", adapters_dialog_state.merge(extra))
        end

        def self.adapters_dialog_state
          Adapters.ui_state.merge(legacy_filemaker_pending: legacy_filemaker_pending?)
        end

        def self.on_pick_catalog_csv(dialog)
          path = ::UI.openpanel("Select catalog CSV", "", "CSV|*.csv||")
          return if path.nil? || path.to_s.strip.empty?
          deliver_csv_preview(dialog, path.to_s.strip)
        end

        def self.on_preview_catalog_csv(dialog, path)
          path = path[0] if path.is_a?(Array)
          deliver_csv_preview(dialog, path.to_s.strip)
        end

        def self.deliver_csv_preview(dialog, stored_path)
          status = csv_header_status(stored_path)
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onCatalogCsvPicked", {
            path: stored_path,
            headers: status[:headers],
            error: status[:error]
          })
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
          val = data["catalog_validate_codes"] || data[:catalog_validate_codes]
          catalog_validate_codes = val
          raw_source = (data["catalog_source"] || data[:catalog_source] || CATALOG_SOURCE_API).to_s.strip.downcase
          catalog_source = (raw_source == CATALOG_SOURCE_CSV) ? CATALOG_SOURCE_CSV : CATALOG_SOURCE_API
          free_edit_val = data.key?("free_edit_mode") ? data["free_edit_mode"] : data[:free_edit_mode]
          free_edit_mode = (free_edit_val == true || free_edit_val.to_s.downcase == "true")
          csv_path = if data.key?("catalog_csv_path") || data.key?(:catalog_csv_path)
            (data["catalog_csv_path"] || data[:catalog_csv_path]).to_s.strip
          else
            stored_catalog_csv_path
          end
          begin
            raw_unit = data.key?("quotation_length_unit") ? data["quotation_length_unit"] : data[:quotation_length_unit]
            quotation_length_unit = raw_unit.nil? ? stored_quotation_length_unit : normalize_quotation_length_unit(raw_unit)
            unit_map_value = data.key?("unit_map") ? data["unit_map"] : data[:unit_map]
            mapped_units = unit_map_value.nil? ? stored_unit_map : normalize_unit_map(unit_map_value)
            mapped_units = apply_quotation_export_names(mapped_units, quotation_length_unit)
            unit_map = JSON.generate(normalize_unit_map(mapped_units))
            csv_fields_value = data.key?("catalog_csv_fields") ? data["catalog_csv_fields"] : data[:catalog_csv_fields]
            csv_fields_hash = csv_fields_value.nil? ? stored_catalog_csv_fields : normalize_catalog_csv_fields(csv_fields_value)
            if catalog_source == CATALOG_SOURCE_CSV && csv_fields_hash["code"].to_s.strip.empty?
              raise ArgumentError, "Choose the CSV column for the product code."
            end
            csv_fields = JSON.generate(csv_fields_hash)
            if data.key?("api_adapter_values") || data.key?(:api_adapter_values)
              Adapters.save_values(data["api_adapter_values"] || data[:api_adapter_values])
            end
            if data.key?("active_api_adapter") || data.key?(:active_api_adapter)
              Adapters.set_active(data["active_api_adapter"] || data[:active_api_adapter])
            end
          rescue StandardError => e
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", { error: true, message: "Invalid settings: #{e.message}" })
            return
          end
          begin
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_CATALOG_VALIDATE_CODES, catalog_validate_codes ? "true" : "false")
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_CATALOG_SOURCE, catalog_source)
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_FREE_EDIT_MODE, free_edit_mode ? "true" : "false")
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_UNIT_MAP, unit_map)
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_QUOTATION_LENGTH_UNIT, quotation_length_unit)
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_CATALOG_CSV_PATH, csv_path)
            Sketchup.write_default(PREF_NAMESPACE, PREF_KEY_CATALOG_CSV_FIELDS, csv_fields)
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", {})
          rescue StandardError => e
            Logimaxx::MaxxBOM::UI.inject_json(dialog, "onSettingsSaved", { error: true, message: e.message })
          end
        end

        def self.stored_import_api_url
          Adapters.connection[:import_url].to_s
        end

        def self.stored_offer_lines_api_url
          Adapters.connection[:offer_lines_url].to_s
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

        def self.stored_import_api_key
          Adapters.connection[:api_key].to_s
        end

        def self.stored_catalog_api_url
          Adapters.connection[:catalog_url].to_s
        end

        def self.stored_catalog_api_key
          Adapters.connection[:api_key].to_s
        end

        def self.stored_api_adapter_name
          Adapters.connection[:name].to_s
        end

        def self.stored_catalog_api_profile
          Adapters.connection[:catalog_profile]
        end

        def self.stored_import_api_profile
          Adapters.connection[:orders_profile]
        end

        # Default true: validate product codes against catalog API on blur.
        def self.stored_catalog_validate_codes
          v = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_CATALOG_VALIDATE_CODES)
          return true if v.nil?
          v.to_s.downcase != "false"
        end

        # "api" uses the active adapter. "csv" reads the catalog file. Orders stay on the adapter.
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

        def self.stored_catalog_csv_path
          Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_CATALOG_CSV_PATH).to_s.strip
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
          raw = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_CATALOG_CSV_FIELDS)
          return empty_catalog_csv_fields if raw.nil? || raw.to_s.strip.empty?
          normalize_catalog_csv_fields(raw)
        rescue StandardError
          empty_catalog_csv_fields
        end

        # { headers:, error: } for the first row. error is "missing", "invalid", or nil.
        def self.csv_header_status(path)
          path = path.to_s.strip
          return { headers: [], error: nil } if path.empty?
          unless File.file?(path)
            return { headers: [], error: "missing" }
          end
          raw = File.read(path).sub(/\A\xEF\xBB\xBF/, "")
          rows = Attributes.parse_csv(raw)
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

        # Replaces m2 / mtr / m3 export names that are still a standard label
        # (m2, cm, ft2, …) with the label for this quotation unit. Custom names stay.
        def self.apply_quotation_export_names(unit_map, unit)
          names = QUOTATION_EXPORT_NAMES[normalize_quotation_length_unit(unit)]
          unit_map.each_with_object({}) do |(uom, entry), result|
            export_name = entry["export"].to_s
            export_name = names[uom] if names[uom] && standard_quotation_export_name?(uom, export_name)
            result[uom] = { "export" => export_name, "accept" => entry["accept"] }
          end
        end

        def self.standard_quotation_export_name?(uom, name)
          text = name.to_s.strip
          return true if text.empty?
          QUOTATION_EXPORT_NAMES.each_value.any? do |names|
            standard = names[uom]
            standard && standard.casecmp(text).zero?
          end
        end

        # Plugin UOM => { "export" => external name written on BOM lines,
        #                 "accept" => extra names read from catalog and offer lines }.
        # The plugin UOM itself is always accepted. export defaults to that UOM.
        def self.default_unit_map
          {
            "pcs" => { "export" => "pcs", "accept" => ["stuks", "stuk", "pieces"] },
            "m2" => { "export" => "m2", "accept" => ["m²"] },
            "mtr" => { "export" => "mtr", "accept" => ["mtr.", "m", "meter", "meters", "linear meter"] },
            "m3" => { "export" => "m3", "accept" => ["m³", "m3.", "cubic meter", "cubic meters"] },
            "custom" => { "export" => "custom", "accept" => [] }
          }
        end

        def self.normalize_unit_map(value)
          raw = value.is_a?(String) ? JSON.parse(value) : value
          raw = {} unless raw.is_a?(Hash)
          result = {}
          seen = {}
          PLUGIN_UOMS.each do |uom|
            entry = raw[uom] || raw[uom.to_sym] || {}
            entry = {} unless entry.is_a?(Hash)
            export_name = (entry["export"] || entry[:export] || uom).to_s.strip
            export_name = uom if export_name.empty?
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
            ([uom, export_name] + names).each do |token|
              key = token.downcase
              if seen[key] && seen[key] != uom
                raise ArgumentError, %(Unit alias "#{token}" is used by both #{seen[key]} and #{uom}.)
              end
              seen[key] = uom
            end
            result[uom] = { "export" => export_name, "accept" => names }
          end
          result
        end

        def self.stored_unit_map
          raw = Sketchup.read_default(PREF_NAMESPACE, PREF_KEY_UNIT_MAP)
          return default_unit_map if raw.nil? || raw.to_s.strip.empty?
          normalize_unit_map(raw)
        rescue StandardError
          default_unit_map
        end
      end
    end
  end
end
