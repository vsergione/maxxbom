# ui/adapters.rb — API adapter plugins
# ------------------------------------------------------------------------------
# An adapter is a folder with adapter.json. Settings → API loads that folder.
# The file declares the connection fields and the catalog / orders profiles
# executed by ui/api_adapter.js. The extension ships with no API connection.
# Installed copies live under the user data folder, keyed by adapter id.
# ------------------------------------------------------------------------------
require "json"
require "fileutils"

module Logimaxx
  module MaxxBOM
    module UI
      module Adapters
        PREF_KEY_LOADED = "loaded_api_adapters".freeze
        PREF_KEY_ACTIVE = "active_api_adapter".freeze
        PREF_KEY_VALUES = "api_adapter_settings".freeze
        ID_RE = /\A[a-z][a-z0-9_]{0,31}\z/
        FIELD_KEY_RE = /\A[a-z][a-z0-9_]{0,40}\z/
        ROLES = %w[catalog_url import_url offer_lines_url api_key].freeze
        FIELD_TYPES = %w[url text password].freeze

        def self.pref_namespace
          Settings::PREF_NAMESPACE
        end

        def self.ui_state
          {
            adapters: summaries,
            active_api_adapter: active_id,
            api_adapter_values: values_for_ui
          }
        end

        # Connection the catalog and order dialogs use. Empty when nothing active is readable.
        def self.connection
          manifest = active_manifest
          return empty_connection unless manifest
          roles = role_values(manifest)
          {
            id: manifest["id"],
            name: manifest["name"].to_s,
            catalog_url: roles["catalog_url"].to_s,
            import_url: roles["import_url"].to_s,
            offer_lines_url: roles["offer_lines_url"].to_s,
            api_key: roles["api_key"].to_s,
            catalog_profile: JSON.generate(manifest["catalog"] || {}),
            orders_profile: JSON.generate(manifest["orders"] || {})
          }
        end

        def self.empty_connection
          {
            id: "",
            name: "",
            catalog_url: "",
            import_url: "",
            offer_lines_url: "",
            api_key: "",
            catalog_profile: "{}",
            orders_profile: "{}"
          }
        end

        def self.pick_path
          if ::UI.respond_to?(:select_directory)
            picked = ::UI.select_directory(title: "Load API adapter")
            return manifest_path_from_directory(picked)
          end
          picked = ::UI.openpanel("Load API adapter", "", "JSON|*.json||")
          picked = picked.first if picked.is_a?(Array)
          return nil unless picked.is_a?(String)
          picked = picked.strip
          return nil if picked.empty?
          picked
        end

        def self.manifest_path_from_directory(picked)
          picked = picked.first if picked.is_a?(Array)
          return nil unless picked.is_a?(String)
          picked = picked.strip
          return nil if picked.empty?
          json = File.join(picked, "adapter.json")
          raise ArgumentError, "That folder has no adapter.json." unless File.file?(json)
          json
        end

        # Copies the plugin into the user folder and registers its id.
        # Returns the normalized manifest.
        def self.install(path)
          manifest = load_manifest_file(path)
          dest = install_dir_for(manifest["id"])
          copy_plugin(File.dirname(File.expand_path(path.to_s)), dest, manifest)
          ids = loaded_ids
          unless ids.include?(manifest["id"])
            ids << manifest["id"]
            write_ids(ids)
          end
          seed_settings(manifest["id"])
          set_active(manifest["id"]) if stored_active_id.empty?
          manifest
        end

        def self.remove(id)
          id = id.to_s
          raise ArgumentError, "Unknown adapter." unless loaded_ids.include?(id)
          write_ids(loaded_ids - [id])
          set_active("") if stored_active_id == id
          dest = install_dir_for(id)
          FileUtils.rm_rf(dest) if File.directory?(dest)
          id
        end

        def self.set_active(id)
          id = id.to_s.strip
          id = "" unless loaded_ids.include?(id)
          Sketchup.write_default(pref_namespace, PREF_KEY_ACTIVE, id)
          id
        end

        def self.save_values(payload)
          return unless payload.is_a?(Hash)
          all = all_settings
          loaded_ids.each do |id|
            raw = payload.key?(id) ? payload[id] : payload[id.to_sym]
            next if raw.nil?
            raise ArgumentError, "Adapter settings must be a JSON object." unless raw.is_a?(Hash)
            manifest = read_installed(id)
            next unless manifest
            current = all[id].is_a?(Hash) ? all[id].dup : {}
            manifest["settings"].each do |field|
              key = field["key"]
              next unless raw.key?(key) || raw.key?(key.to_sym)
              value = (raw[key] || raw[key.to_sym]).to_s.strip
              raise ArgumentError, "A setting value is too long." if value.length > 8000
              current[key] = value
            end
            all[id] = current
          end
          write_settings(all)
        end

        def self.loaded_ids
          raw = Sketchup.read_default(pref_namespace, PREF_KEY_LOADED)
          return [] if raw.nil? || raw.to_s.strip.empty?
          parsed = JSON.parse(raw.to_s)
          return [] unless parsed.is_a?(Array)
          parsed.map(&:to_s).select { |id| valid_id?(id) }.uniq
        rescue StandardError
          []
        end

        def self.active_id
          id = stored_active_id
          loaded_ids.include?(id) ? id : ""
        end

        def self.normalize_manifest(data)
          raise ArgumentError, "Adapter manifest must be a JSON object." unless data.is_a?(Hash)
          id = value_of(data, "id").strip
          raise ArgumentError, "Adapter id must be a short lowercase name." unless valid_id?(id)
          name = value_of(data, "name").strip
          raise ArgumentError, "Adapter name is required." if name.empty?
          settings = data.key?("settings") ? data["settings"] : data[:settings]
          settings = [] if settings.nil?
          raise ArgumentError, "Adapter settings must be a list." unless settings.is_a?(Array)
          catalog = section_of(data, "catalog")
          orders = section_of(data, "orders")
          if catalog.nil? && orders.nil?
            raise ArgumentError, "Adapter must define a catalog profile, an orders profile, or both."
          end
          raise ArgumentError, "Catalog profile must be a JSON object." unless catalog.nil? || catalog.is_a?(Hash)
          raise ArgumentError, "Orders profile must be a JSON object." unless orders.nil? || orders.is_a?(Hash)

          cleaned_settings = normalize_settings(settings)
          manifest = {
            "id" => id,
            "name" => name,
            "version" => value_of(data, "version").strip,
            "description" => value_of(data, "description").strip,
            "settings" => cleaned_settings
          }
          manifest["catalog"] = json_object(catalog) unless catalog.nil?
          manifest["orders"] = json_object(orders) unless orders.nil?
          files = data.key?("files") ? data["files"] : data[:files]
          manifest["files"] = normalize_files(files)
          manifest
        end

        def self.valid_id?(id)
          !!(id.to_s =~ ID_RE)
        end

        def self.load_manifest_file(path)
          path = path.to_s
          raise ArgumentError, "Choose an adapter.json file." unless File.file?(path)
          raw = File.read(path, encoding: "UTF-8").sub(/\A\xEF\xBB\xBF/, "")
          normalize_manifest(JSON.parse(raw))
        rescue JSON::ParserError
          raise ArgumentError, "adapter.json is not valid JSON."
        end

        def self.summaries
          loaded_ids.map { |id| summary_for(id) }
        end

        def self.values_for_ui
          stored = all_settings
          loaded_ids.each_with_object({}) do |id, result|
            manifest = read_installed(id)
            values = {}
            if manifest
              current = stored[id].is_a?(Hash) ? stored[id] : {}
              manifest["settings"].each do |field|
                values[field["key"]] = display_value(manifest, field, current)
              end
            end
            result[id] = values
          end
        end

        def self.display_value(manifest, field, stored, seen = {})
          key = field["key"]
          return stored[key].to_s if stored.key?(key)
          return "" if seen[key]
          seen[key] = true
          rule = field["when_unset"]
          return "" unless rule.is_a?(Hash)
          source = (manifest["settings"] || []).find { |item| item["key"] == rule["from"] }
          source_value = source ? display_value(manifest, source, stored, seen) : ""
          apply_replace(source_value, rule["replace"])
        end

        def self.user_dir
          root = support_root
          raise ArgumentError, "Cannot find a user folder for adapters." if root.empty?
          File.join(root, "MaxxBOM", "adapters")
        end

        def self.support_root
          platform = defined?(Sketchup) && Sketchup.respond_to?(:platform) ? Sketchup.platform : nil
          home = ENV["HOME"].to_s
          home = ENV["USERPROFILE"].to_s if home.empty?
          windows = platform == :platform_win || (platform.nil? && !!(RUBY_PLATFORM =~ /mswin|mingw|cygwin/i))
          mac = platform == :platform_osx || (platform.nil? && !!(RUBY_PLATFORM =~ /darwin/i))
          if windows
            base = ENV["APPDATA"].to_s
            base = File.join(home, "AppData", "Roaming") if base.empty? && !home.empty?
            return base
          end
          return "" if home.empty?
          return File.join(home, "Library", "Application Support") if mac
          File.join(home, ".local", "share")
        end

        def self.install_dir_for(id)
          raise ArgumentError, "Invalid adapter id." unless valid_id?(id)
          root = File.expand_path(user_dir)
          dest = File.expand_path(File.join(root, id))
          prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
          raise ArgumentError, "Invalid adapter id." unless dest.start_with?(prefix)
          dest
        end

        def self.read_installed(id)
          path = File.join(install_dir_for(id), "adapter.json")
          return nil unless File.file?(path)
          load_manifest_file(path)
        rescue StandardError
          nil
        end

        def self.active_manifest
          id = active_id
          return nil if id.empty?
          read_installed(id)
        end

        def self.role_values(manifest)
          stored = all_settings[manifest["id"]]
          stored = {} unless stored.is_a?(Hash)
          manifest["settings"].each_with_object({}) do |field, result|
            role = field["role"].to_s
            next if role.empty?
            result[role] = display_value(manifest, field, stored)
          end
        end

        def self.summary_for(id)
          manifest = read_installed(id)
          unless manifest
            return {
              "id" => id,
              "name" => id,
              "version" => "",
              "description" => "",
              "missing" => true,
              "settings" => []
            }
          end
          {
            "id" => manifest["id"],
            "name" => manifest["name"],
            "version" => manifest["version"].to_s,
            "description" => manifest["description"].to_s,
            "missing" => false,
            "settings" => manifest["settings"].map { |field| public_field(field) }
          }
        end

        def self.public_field(field)
          result = {
            "key" => field["key"],
            "label" => field["label"],
            "type" => field["type"]
          }
          result["placeholder"] = field["placeholder"] if field["placeholder"]
          result["hint"] = field["hint"] if field["hint"]
          result
        end

        def self.seed_settings(id)
          all = all_settings
          return if all.key?(id)
          all[id] = id == "filemaker" ? Settings.legacy_filemaker_settings : {}
          write_settings(all)
        end

        def self.all_settings
          raw = Sketchup.read_default(pref_namespace, PREF_KEY_VALUES)
          return {} if raw.nil? || raw.to_s.strip.empty?
          parsed = JSON.parse(raw.to_s)
          return {} unless parsed.is_a?(Hash)
          parsed.each_with_object({}) do |(id, values), result|
            next unless valid_id?(id)
            next unless values.is_a?(Hash)
            current = {}
            values.each { |key, value| current[key.to_s] = value.to_s }
            result[id.to_s] = current
          end
        rescue StandardError
          {}
        end

        def self.write_settings(values)
          Sketchup.write_default(pref_namespace, PREF_KEY_VALUES, JSON.generate(values))
        end

        def self.write_ids(ids)
          Sketchup.write_default(pref_namespace, PREF_KEY_LOADED, JSON.generate(ids))
        end

        def self.stored_active_id
          Sketchup.read_default(pref_namespace, PREF_KEY_ACTIVE).to_s.strip
        end

        def self.copy_plugin(source_dir, dest, manifest)
          source_dir = File.expand_path(source_dir)
          dest = File.expand_path(dest)
          return if source_dir == dest
          FileUtils.mkdir_p(dest)
          manifest["files"].each do |name|
            from = File.join(source_dir, name)
            raise ArgumentError, "Plugin is missing #{name}." unless File.file?(from)
            FileUtils.cp(from, File.join(dest, name))
          end
        end

        def self.normalize_settings(settings)
          cleaned = []
          seen_keys = {}
          seen_roles = {}
          settings.each do |field|
            raise ArgumentError, "Each setting must be a JSON object." unless field.is_a?(Hash)
            key = value_of(field, "key").strip
            raise ArgumentError, "Each setting needs a key." unless field_key?(key)
            raise ArgumentError, "Duplicate setting \"#{key}\"." if seen_keys[key]
            seen_keys[key] = true
            label = value_of(field, "label").strip
            raise ArgumentError, "Setting \"#{key}\" needs a label." if label.empty?
            type = value_of(field, "type").strip
            type = "text" if type.empty?
            raise ArgumentError, "Setting \"#{key}\" has an unknown type." unless FIELD_TYPES.include?(type)
            role = value_of(field, "role").strip
            unless role.empty?
              raise ArgumentError, "Setting \"#{key}\" has an unknown role." unless ROLES.include?(role)
              raise ArgumentError, "Role \"#{role}\" is used more than once." if seen_roles[role]
              seen_roles[role] = true
            end
            entry = { "key" => key, "label" => label, "type" => type }
            entry["role"] = role unless role.empty?
            placeholder = value_of(field, "placeholder")
            hint = value_of(field, "hint")
            entry["placeholder"] = placeholder unless placeholder.empty?
            entry["hint"] = hint unless hint.empty?
            rule = field.key?("when_unset") ? field["when_unset"] : field[:when_unset]
            entry["when_unset"] = normalize_when_unset(key, rule) if rule
            cleaned << entry
          end
          cleaned.each do |entry|
            rule = entry["when_unset"]
            next unless rule
            unless seen_keys[rule["from"]]
              raise ArgumentError, "Setting \"#{entry["key"]}\" derives from an unknown field."
            end
            if rule["from"] == entry["key"]
              raise ArgumentError, "Setting \"#{entry["key"]}\" cannot derive from itself."
            end
          end
          cleaned
        end

        def self.normalize_when_unset(key, rule)
          raise ArgumentError, "when_unset on \"#{key}\" must be a JSON object." unless rule.is_a?(Hash)
          from = value_of(rule, "from").strip
          raise ArgumentError, "when_unset on \"#{key}\" needs a source field." unless field_key?(from)
          cleaned = { "from" => from }
          replace = rule.key?("replace") ? rule["replace"] : rule[:replace]
          if replace
            unless replace.is_a?(Array) && replace.length == 2
              raise ArgumentError, "when_unset on \"#{key}\" needs two replace strings."
            end
            cleaned["replace"] = [replace[0].to_s, replace[1].to_s]
          end
          cleaned
        end

        def self.normalize_files(files)
          names = files.is_a?(Array) && !files.empty? ? files : ["adapter.json"]
          cleaned = []
          names.each do |name|
            base = File.basename(name.to_s)
            if base.empty? || base != name.to_s || base == "." || base == ".."
              raise ArgumentError, "Invalid plugin file name."
            end
            cleaned << base unless cleaned.include?(base)
          end
          unless cleaned.include?("adapter.json")
            raise ArgumentError, "Plugin files must include adapter.json."
          end
          cleaned
        end

        def self.section_of(data, key)
          return data[key] if data.key?(key)
          return data[key.to_sym] if data.key?(key.to_sym)
          nil
        end

        def self.value_of(hash, key)
          value = hash.key?(key) ? hash[key] : hash[key.to_sym]
          value.nil? ? "" : value.to_s
        end

        def self.field_key?(key)
          !!(key.to_s =~ FIELD_KEY_RE)
        end

        def self.json_object(value)
          parsed = JSON.parse(JSON.generate(value))
          raise ArgumentError, "Profile must be a JSON object." unless parsed.is_a?(Hash)
          parsed
        end

        def self.apply_replace(value, replace)
          text = value.to_s
          return text unless replace.is_a?(Array)
          from = replace[0].to_s
          return "" if text.empty? || from.empty? || !text.include?(from)
          text.sub(from, replace[1].to_s)
        end
      end
    end
  end
end
