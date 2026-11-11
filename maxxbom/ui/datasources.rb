# ui/datasources.rb — Configured adapter instances
# ------------------------------------------------------------------------------
# A data source is a named instance of an installed adapter. Product lookup
# points at one instance. Offer calls use that same instance when its adapter
# implements orders.load and orders.export. The CSV adapter only searches.
# ------------------------------------------------------------------------------
require "securerandom"

module Logimaxx
  module MaxxBOM
    module UI
      module DataSources
        PREF_KEY_LIST = "data_sources".freeze
        PREF_KEY_CATALOG = "catalog_data_source".freeze
        PREF_KEY_ORDERS = "orders_data_source".freeze
        ID_RE = /\Ads_[a-f0-9]{8}\z/
        CATALOG_ACTIONS = %w[catalog.search].freeze
        ORDER_ACTIONS = %w[orders.load orders.export].freeze

        def self.ui_state
          ensure!
          {
            data_sources: summaries,
            installed: Adapters.summaries,
            available: Adapters.available_for_ui,
            catalog_data_source: catalog_id,
            orders_data_source: orders_id,
            file_headers: file_headers
          }
        end

        def self.catalog_id
          ensure!
          stored_role(PREF_KEY_CATALOG)
        end

        def self.orders_id
          ensure!
          orders_for(catalog_id, list)
        end

        def self.role_name(role)
          ds = find(role == :orders ? orders_id : catalog_id)
          ds ? ds["name"].to_s : ""
        end

        # Category stays on the quantity export unless this catalog has a category
        # column and it is blank. Price is on only when a price column is chosen.
        def self.catalog_flags
          ensure!
          ds = find(catalog_id)
          manifest = ds && Adapters.read_installed(ds["adapter_id"])
          values = ds ? ds["settings"] : {}
          category_field = manifest && manifest["settings"].any? { |field| field["key"] == "category" }
          price_field = manifest && manifest["settings"].any? { |field| field["key"] == "price" }
          {
            category_mapped: !category_field || !values["category"].to_s.strip.empty?,
            price_mapped: !!(price_field && !values["price"].to_s.strip.empty?)
          }
        end

        # What a dialog needs to call one data source. file_text is added for the
        # script and is not part of the saved settings. concern is :catalog or
        # :orders, so a missing catalog field does not block offer calls.
        def self.slot(id, expose_script:, concern:)
          state = {
            "api_adapter_name" => "",
            "datasource_name" => "",
            "adapter_actions" => [],
            "adapter_settings" => {},
            "adapter_ready" => {},
            "adapter_script" => "",
            "datasource_error" => ""
          }
          id = id.to_s
          return state if id.empty?
          ds = find(id)
          unless ds
            state["datasource_error"] = "The selected data source is missing."
            return state
          end
          state["datasource_name"] = ds["name"]
          manifest = Adapters.read_installed(ds["adapter_id"])
          unless manifest
            state["datasource_error"] = "The adapter for #{ds["name"]} is missing. Install it again."
            return state
          end
          state["api_adapter_name"] = manifest["name"]
          values = values_for(manifest, ds)
          file_error = file_problem(manifest, values)
          actions = concern == :orders ? ORDER_ACTIONS : CATALOG_ACTIONS
          missing = missing_labels(manifest, values, actions)
          reason = file_error
          reason = "Fill in #{missing.join(", ")} for #{ds["name"]}." if reason.empty? && !missing.empty?
          state["datasource_error"] = reason
          return state unless expose_script
          ready = Adapters.ready_map(manifest, values)
          ready.each_key { |action| ready[action] = false } unless file_error.empty?
          state["adapter_actions"] = manifest["actions"]
          state["adapter_ready"] = ready
          state["adapter_settings"] = reason.empty? ? with_file_text(manifest, values) : values
          state["adapter_script"] = Adapters.script_source_for(manifest)
          state
        end

        def self.create(name, adapter_id)
          ensure!
          name = name.to_s.strip
          raise ArgumentError, "Enter a name for the data source." if name.empty?
          raise ArgumentError, "That name is too long." if name.length > 80
          sources = list
          if sources.any? { |ds| ds["name"].casecmp(name).zero? }
            raise ArgumentError, "A data source named \"#{name}\" already exists."
          end
          manifest = Adapters.read_installed(adapter_id.to_s)
          raise ArgumentError, "Install that adapter before adding a data source." unless manifest
          ds = {
            "id" => fresh_id(sources.map { |item| item["id"] }),
            "name" => name,
            "adapter_id" => manifest["id"],
            "settings" => manifest["settings"].each_with_object({}) { |field, result| result[field["key"]] = "" }
          }
          write_list(sources + [ds])
          ds
        end

        def self.remove(id)
          ensure!
          id = id.to_s
          sources = list
          raise ArgumentError, "Unknown data source." unless sources.any? { |ds| ds["id"] == id }
          write_list(sources.reject { |ds| ds["id"] == id })
          release_roles([id])
          id
        end

        # A removed data source that was the product lookup is replaced by free edit mode.
        def self.release_roles(ids)
          if ids.include?(read_role(PREF_KEY_CATALOG))
            write_role(PREF_KEY_CATALOG, "")
            Settings.write_free_edit_mode(true)
          end
          write_role(PREF_KEY_ORDERS, "") if ids.include?(read_role(PREF_KEY_ORDERS))
        end

        # Drop instances when their adapter plugin is uninstalled.
        def self.drop_adapter(adapter_id)
          ensure!
          adapter_id = adapter_id.to_s
          sources = list
          gone = sources.select { |ds| ds["adapter_id"] == adapter_id }.map { |ds| ds["id"] }
          return if gone.empty?
          write_list(sources.reject { |ds| gone.include?(ds["id"]) })
          release_roles(gone)
        end

        def self.apply_form(payload, catalog_role, enforce_required: true)
          ensure!
          sources = list.map { |ds| ds.merge("settings" => ds["settings"].dup) }
          apply_values(sources, payload)
          catalog_role = normalize_role(catalog_role, sources, CATALOG_ACTIONS, "product lookup")
          orders_role = orders_for(catalog_role, sources)
          if enforce_required
            assert_required(sources, catalog_role, CATALOG_ACTIONS)
            assert_required(sources, orders_role, ORDER_ACTIONS)
          end
          write_list(sources)
          write_role(PREF_KEY_CATALOG, catalog_role)
          write_role(PREF_KEY_ORDERS, orders_role)
        end

        def self.list
          ensure!
          normalize_list(Adapters.read_json(PREF_KEY_LIST))
        end

        def self.find(id)
          list.find { |ds| ds["id"] == id.to_s }
        end

        def self.ensure!
          return if @migrating
          return unless Adapters.read_json(PREF_KEY_LIST).nil?
          @migrating = true
          begin
            migrate!
          ensure
            @migrating = false
          end
        end

        def self.migrate!
          sources = []
          catalog_role = ""
          active = Adapters.active_id
          catalog_was_csv = Settings.stored_catalog_source == Settings::CATALOG_SOURCE_CSV

          Adapters.loaded_ids.each do |adapter_id|
            manifest = Adapters.read_installed(adapter_id)
            next unless manifest
            ds = build_source(manifest, Adapters.setting_values(manifest), sources)
            sources << ds
            next unless adapter_id == active
            catalog_role = ds["id"] if !catalog_was_csv && supports?(manifest, CATALOG_ACTIONS)
          end

          path = Settings.stored_catalog_csv_path
          unless path.to_s.strip.empty?
            install_csv_plugin
            manifest = Adapters.read_installed("csv")
            if manifest
              fields = Settings.stored_catalog_csv_fields
              values = {
                "path" => path.to_s,
                "code" => fields["code"].to_s,
                "name" => fields["name"].to_s,
                "unit" => fields["unit"].to_s,
                "category" => fields["category"].to_s,
                "price" => fields["price"].to_s
              }
              ds = build_source(manifest, values, sources, "CSV catalog")
              sources << ds
              catalog_role = ds["id"] if catalog_was_csv
            end
          end

          write_role(PREF_KEY_CATALOG, catalog_role)
          write_role(PREF_KEY_ORDERS, orders_for(catalog_role, sources))
          write_list(sources)
        end

        def self.install_csv_plugin
          return if Adapters.loaded_ids.include?("csv")
          Adapters.install_discovered("csv")
        rescue StandardError => e
          puts "[#{Logimaxx::MaxxBOM::DISPLAY_NAME}] Could not install the CSV adapter: #{e.message}"
        end

        def self.build_source(manifest, values, sources, name = nil)
          {
            "id" => fresh_id(sources.map { |item| item["id"] }),
            "name" => unique_name(name || manifest["name"], sources),
            "adapter_id" => manifest["id"],
            "settings" => values_for(manifest, { "settings" => values })
          }
        end

        def self.summaries
          list.map do |ds|
            manifest = Adapters.read_installed(ds["adapter_id"])
            {
              "id" => ds["id"],
              "name" => ds["name"],
              "adapter_id" => ds["adapter_id"],
              "adapter_name" => manifest ? manifest["name"] : ds["adapter_id"],
              "missing" => manifest.nil?,
              "actions" => manifest ? manifest["actions"] : [],
              "description" => manifest ? manifest["description"].to_s : "",
              "settings" => manifest ? manifest["settings"].map { |field| Adapters.public_field(field) } : [],
              "values" => manifest ? values_for(manifest, ds) : ds["settings"]
            }
          end
        end

        def self.file_headers
          result = {}
          list.each do |ds|
            manifest = Adapters.read_installed(ds["adapter_id"])
            next unless manifest
            per_field = {}
            manifest["settings"].each do |field|
              next unless field["type"] == "file"
              status = Settings.csv_header_status(ds["settings"][field["key"]])
              per_field[field["key"]] = { "headers" => status[:headers], "error" => status[:error] }
            end
            result[ds["id"]] = per_field unless per_field.empty?
          end
          result
        end

        def self.values_for(manifest, ds)
          stored = ds["settings"].is_a?(Hash) ? ds["settings"] : {}
          manifest["settings"].each_with_object({}) do |field, result|
            result[field["key"]] = stored[field["key"]].to_s
          end
        end

        def self.with_file_text(manifest, values)
          exposed = values.dup
          manifest["settings"].each do |field|
            next unless field["type"] == "file"
            next if exposed.key?("file_text")
            path = Settings.normalize_catalog_csv_path(values[field["key"]])
            next if path.empty? || !File.file?(path)
            exposed["file_text"] = File.read(path, encoding: "UTF-8").sub(/\A\xEF\xBB\xBF/, "")
          end
          exposed
        rescue StandardError
          values.dup
        end

        def self.file_problem(manifest, values)
          manifest["settings"].each do |field|
            next unless field["type"] == "file"
            path = Settings.normalize_catalog_csv_path(values[field["key"]])
            next if path.empty?
            if Settings.catalog_csv_path_damaged?(path)
              return "The file path was damaged by Windows backslashes. Choose the file again in Plugin Settings and save."
            end
            return "File was not found: #{path}" unless File.file?(path)
          end
          ""
        end

        def self.apply_values(sources, payload)
          return unless payload.is_a?(Hash)
          sources.each do |ds|
            raw = payload.key?(ds["id"]) ? payload[ds["id"]] : payload[ds["id"].to_sym]
            next if raw.nil?
            raise ArgumentError, "Data source settings must be a JSON object." unless raw.is_a?(Hash)
            manifest = Adapters.read_installed(ds["adapter_id"])
            next unless manifest
            manifest["settings"].each do |field|
              key = field["key"]
              next unless raw.key?(key) || raw.key?(key.to_sym)
              value = (raw[key] || raw[key.to_sym]).to_s.strip
              raise ArgumentError, "A setting value is too long." if value.length > 8000
              if field["type"] == "file"
                value = Settings.normalize_catalog_csv_path(value)
                if Settings.catalog_csv_path_damaged?(value)
                  raise ArgumentError, "The file path was damaged by Windows backslashes. Choose the file again."
                end
              end
              ds["settings"][key] = value
            end
          end
        end

        def self.orders_for(catalog_role, sources)
          id = catalog_role.to_s
          return "" if id.empty?
          ds = sources.find { |item| item["id"] == id }
          return "" unless ds
          manifest = Adapters.read_installed(ds["adapter_id"])
          return "" unless manifest && supports?(manifest, ORDER_ACTIONS)
          id
        end

        def self.normalize_role(id, sources, actions, label)
          id = id.to_s.strip
          return "" if id.empty?
          ds = sources.find { |item| item["id"] == id }
          raise ArgumentError, "Unknown data source." unless ds
          manifest = Adapters.read_installed(ds["adapter_id"])
          raise ArgumentError, "The adapter for #{ds["name"]} is missing." unless manifest
          raise ArgumentError, "#{ds["name"]} cannot be used for #{label}." unless supports?(manifest, actions)
          id
        end

        def self.assert_required(sources, id, actions)
          return if id.empty?
          ds = sources.find { |item| item["id"] == id }
          manifest = Adapters.read_installed(ds["adapter_id"])
          missing = missing_labels(manifest, ds["settings"], actions)
          return if missing.empty?
          raise ArgumentError, "Fill in #{missing.join(", ")} for #{ds["name"]}."
        end

        def self.missing_labels(manifest, values, actions)
          missing = []
          actions.each do |action|
            manifest["settings"].each do |field|
              required = field["required_for"] || []
              next unless required.include?(action)
              next unless values[field["key"]].to_s.strip.empty?
              missing << field["label"] unless missing.include?(field["label"])
            end
          end
          missing
        end

        def self.supports?(manifest, actions)
          actions.all? { |action| manifest["actions"].include?(action) }
        end

        def self.stored_role(key)
          id = read_role(key)
          list.any? { |ds| ds["id"] == id } ? id : ""
        end

        def self.read_role(key)
          parsed = Adapters.read_json(key)
          return "" unless parsed.is_a?(Hash)
          (parsed["id"] || parsed[:id]).to_s
        end

        def self.write_role(key, id)
          Adapters.write_json(key, { "id" => id.to_s })
        end

        def self.write_list(sources)
          Adapters.write_json(PREF_KEY_LIST, sources)
        end

        def self.normalize_list(raw)
          return [] unless raw.is_a?(Array)
          seen = {}
          raw.filter_map do |item|
            next unless item.is_a?(Hash)
            id = (item["id"] || item[:id]).to_s
            next unless id =~ ID_RE
            next if seen[id]
            seen[id] = true
            adapter_id = (item["adapter_id"] || item[:adapter_id]).to_s
            next unless Adapters.valid_id?(adapter_id)
            name = (item["name"] || item[:name]).to_s.strip
            name = adapter_id if name.empty?
            settings = item["settings"] || item[:settings]
            settings = {} unless settings.is_a?(Hash)
            clean = {}
            settings.each { |key, value| clean[key.to_s] = value.to_s }
            { "id" => id, "name" => name, "adapter_id" => adapter_id, "settings" => clean }
          end
        end

        def self.unique_name(name, sources)
          base = name.to_s.strip
          base = "Data source" if base.empty?
          candidate = base
          number = 2
          while sources.any? { |ds| ds["name"].casecmp(candidate).zero? }
            candidate = "#{base} #{number}"
            number += 1
          end
          candidate
        end

        def self.fresh_id(taken)
          20.times do
            id = "ds_" + SecureRandom.hex(4)
            return id unless taken.include?(id)
          end
          raise ArgumentError, "Could not assign a data source id."
        end
      end
    end
  end
end
