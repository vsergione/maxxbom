# ui/adapters.rb — Adapter plugins
# ------------------------------------------------------------------------------
# An adapter is a folder with adapter.json and a script. Settings installs the
# manifest. The script implements MaxxAdapter.execute(request). A loaded adapter
# keeps its original path. Configured instances live in DataSources.
# ------------------------------------------------------------------------------
require "json"
require "base64"

module Logimaxx
  module MaxxBOM
    module UI
      module Adapters
        PREF_KEY_LOADED = "loaded_api_adapters".freeze
        PREF_KEY_ACTIVE = "active_api_adapter".freeze
        PREF_KEY_VALUES = "api_adapter_settings".freeze
        PREF_KEY_PATHS = "api_adapter_paths".freeze
        ID_RE = /\A[a-z][a-z0-9_]{0,31}\z/
        FIELD_KEY_RE = /\A[a-z][a-z0-9_]{0,40}\z/
        ACTIONS = %w[catalog.search orders.load orders.export].freeze
        FIELD_TYPES = %w[url text password file column].freeze

        def self.pref_namespace
          Settings::PREF_NAMESPACE
        end

        def self.setting_values(manifest)
          stored = all_settings[manifest["id"]]
          stored = {} unless stored.is_a?(Hash)
          manifest["settings"].each_with_object({}) do |field, result|
            result[field["key"]] = stored[field["key"]].to_s
          end
        end

        def self.ready_map(manifest, values)
          manifest["actions"].each_with_object({}) do |action, result|
            missing = manifest["settings"].any? do |field|
              required = field["required_for"] || []
              required.include?(action) && values[field["key"]].to_s.strip.empty?
            end
            result[action] = !missing
          end
        end

        def self.script_source_for(manifest)
          path = adapter_paths[manifest["id"]]
          return "" if path.nil? || path.strip.empty?
          script = File.join(File.dirname(path), manifest["script"].to_s)
          return "" unless File.file?(script)
          File.read(script, encoding: "UTF-8").sub(/\A\xEF\xBB\xBF/, "")
        rescue StandardError
          ""
        end

        # HtmlDialog callbacks cannot open a file dialog directly: SketchUp swallows it.
        # The caller defers this with UI.start_timer.
        def self.pick_path
          picked = ::UI.openpanel("Load API adapter", "", "Adapter|adapter.json|JSON|*.json||")
          picked = picked.first if picked.is_a?(Array)
          return nil unless picked.is_a?(String)
          picked = picked.strip
          return nil if picked.empty?
          return picked if File.file?(picked)
          json = File.join(picked, "adapter.json")
          raise ArgumentError, "That folder has no adapter.json." unless File.file?(json)
          json
        end

        # plugins/ next to the extension checkout, and plugins/ inside it.
        def self.plugin_roots
          roots = []
          if defined?(Logimaxx::MaxxBOM::ROOT) && Logimaxx::MaxxBOM::ROOT
            root = Logimaxx::MaxxBOM::ROOT.to_s
            roots << File.expand_path("../plugins", root)
            roots << File.join(root, "plugins")
          end
          roots.uniq
        end

        def self.discover
          found = []
          seen = {}
          plugin_roots.each do |root|
            next unless File.directory?(root)
            Dir.foreach(root) do |name|
              next if name == "." || name == ".." || name.start_with?(".")
              json = File.join(root, name, "adapter.json")
              next unless File.file?(json)
              begin
                manifest = load_manifest_file(json)
              rescue StandardError
                next
              end
              next if seen[manifest["id"]]
              seen[manifest["id"]] = true
              found << {
                "id" => manifest["id"],
                "name" => manifest["name"],
                "version" => manifest["version"].to_s,
                "description" => manifest["description"].to_s,
                "path" => json
              }
            end
          end
          found
        end

        def self.available_for_ui
          loaded = loaded_ids
          discover.reject { |item| loaded.include?(item["id"]) }.map do |item|
            {
              "id" => item["id"],
              "name" => item["name"],
              "version" => item["version"],
              "description" => item["description"]
            }
          end
        end

        def self.install_discovered(id)
          found = discover.find { |item| item["id"] == id.to_s }
          raise ArgumentError, "That adapter is not available." unless found
          install(found["path"])
        end

        # Remembers the adapter.json path. The plugin stays where it was found.
        # Returns the normalized manifest.
        def self.install(path)
          path = File.expand_path(path.to_s)
          raise ArgumentError, "Adapter file was not found." unless File.file?(path)
          manifest = load_manifest_file(path)
          id = manifest["id"]
          paths = adapter_paths
          paths[id] = path
          write_paths(paths)
          ids = loaded_ids
          unless ids.include?(id)
            ids << id
            write_ids(ids)
          end
          begin
            seed_settings(id)
          rescue StandardError => e
            puts "[#{Logimaxx::MaxxBOM::DISPLAY_NAME}] Could not copy the previous connection: #{e.message}"
          end
          manifest
        end

        def self.remove(id)
          id = id.to_s
          raise ArgumentError, "The CSV adapter stays installed." if id == "csv"
          raise ArgumentError, "Unknown adapter." unless loaded_ids.include?(id)
          write_ids(loaded_ids - [id])
          paths = adapter_paths
          paths.delete(id)
          write_paths(paths)
          set_active("") if stored_active_id == id
          id
        end

        def self.set_active(id)
          id = id.to_s.strip
          id = "" unless id.empty? || valid_id?(id)
          write_pref(PREF_KEY_ACTIVE, id)
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
          parsed = read_json(PREF_KEY_LOADED)
          return [] unless parsed.is_a?(Array)
          parsed.map(&:to_s).select { |id| valid_id?(id) }.uniq
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
          actions = normalize_actions(data)
          settings = data.key?("settings") ? data["settings"] : data[:settings]
          settings = [] if settings.nil?
          raise ArgumentError, "Adapter settings must be a list." unless settings.is_a?(Array)
          {
            "id" => id,
            "name" => name,
            "version" => value_of(data, "version").strip,
            "description" => value_of(data, "description").strip,
            "script" => normalize_script(data),
            "actions" => actions,
            "settings" => normalize_settings(settings, actions)
          }
        end

        def self.valid_id?(id)
          !!(id.to_s =~ ID_RE)
        end

        def self.load_manifest_file(path)
          path = path.to_s
          raise ArgumentError, "Choose an adapter.json file." unless File.file?(path)
          raw = File.read(path, encoding: "UTF-8").sub(/\A\xEF\xBB\xBF/, "")
          manifest = normalize_manifest(JSON.parse(raw))
          script = File.join(File.dirname(path), manifest["script"])
          unless File.file?(script)
            raise ArgumentError, "Adapter script \"#{manifest["script"]}\" was not found."
          end
          manifest
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
                values[field["key"]] = current[field["key"]].to_s
              end
            end
            result[id] = values
          end
        end

        def self.read_installed(id)
          path = adapter_paths[id.to_s]
          return nil if path.nil? || path.strip.empty? || !File.file?(path)
          manifest = load_manifest_file(path)
          return nil unless manifest["id"] == id.to_s
          manifest
        rescue StandardError
          nil
        end

        def self.active_manifest
          id = active_id
          return nil if id.empty?
          read_installed(id)
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
              "actions" => [],
              "settings" => []
            }
          end
          {
            "id" => manifest["id"],
            "name" => manifest["name"],
            "version" => manifest["version"].to_s,
            "description" => manifest["description"].to_s,
            "missing" => false,
            "actions" => manifest["actions"],
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
          result["headers_from"] = field["headers_from"] if field["headers_from"]
          result["required_for"] = field["required_for"] if field["required_for"]
          result
        end

        def self.seed_settings(id)
          all = all_settings
          return if all.key?(id)
          raw = id == "filemaker" ? Settings.legacy_filemaker_settings : {}
          clean = {}
          raw.each { |key, value| clean[key.to_s] = utf8(value) }
          all[id] = clean
          write_settings(all)
        end

        def self.all_settings
          parsed = read_json(PREF_KEY_VALUES)
          return {} unless parsed.is_a?(Hash)
          parsed.each_with_object({}) do |(id, values), result|
            next unless valid_id?(id)
            next unless values.is_a?(Hash)
            current = {}
            values.each { |key, value| current[key.to_s] = value.to_s }
            result[id.to_s] = current
          end
        end

        def self.adapter_paths
          parsed = read_json(PREF_KEY_PATHS)
          return {} unless parsed.is_a?(Hash)
          parsed.each_with_object({}) do |(id, path), result|
            next unless valid_id?(id)
            result[id.to_s] = path.to_s
          end
        end

        def self.write_paths(paths)
          write_json(PREF_KEY_PATHS, paths)
        end

        def self.write_settings(values)
          write_json(PREF_KEY_VALUES, values)
        end

        def self.write_ids(ids)
          write_json(PREF_KEY_LOADED, ids)
        end

        # SketchUp's preference store drops or escapes double quotes, so raw JSON
        # does not round-trip. Base64 is only letters, digits, and + / =.
        def self.write_json(key, obj)
          payload = Base64.strict_encode64(utf8(JSON.generate(obj)))
          write_pref(key, payload)
          stored = utf8(Sketchup.read_default(pref_namespace, key)).strip.delete("\0")
          unless stored == payload
            raise ArgumentError, "Could not save the adapter (SketchUp returned #{stored.inspect})."
          end
          pref_cache[key] = JSON.parse(JSON.generate(obj))
          obj
        end

        def self.read_json(key)
          return pref_cache[key] if pref_cache.key?(key)
          parsed = decode_json_pref(Sketchup.read_default(pref_namespace, key))
          pref_cache[key] = parsed unless parsed.nil?
          parsed
        end

        def self.decode_json_pref(raw)
          return nil if raw.nil?
          text = utf8(raw).strip
          return nil if text.empty?
          decoded = decode_base64(text)
          return JSON.parse(utf8(decoded)) if decoded
          JSON.parse(text)
        rescue StandardError
          nil
        end

        def self.decode_base64(text)
          return nil unless text =~ /\A[A-Za-z0-9+\/]*={0,2}\z/
          return nil unless (text.length % 4).zero?
          Base64.strict_decode64(text)
        rescue StandardError
          nil
        end

        def self.pref_cache
          @pref_cache ||= {}
        end

        def self.write_pref(key, value)
          text = utf8(value)
          result = Sketchup.write_default(pref_namespace, key, text)
          raise ArgumentError, "SketchUp could not store the adapter." if result == false
          text
        end

        def self.utf8(value)
          text = value.to_s
          copy = text.dup
          copy.force_encoding("UTF-8")
          return copy if copy.valid_encoding?
          text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        rescue StandardError
          text.dup.force_encoding("ASCII-8BIT").encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        end

        def self.stored_active_id
          Sketchup.read_default(pref_namespace, PREF_KEY_ACTIVE).to_s.strip
        end

        def self.normalize_actions(data)
          raw = data.key?("actions") ? data["actions"] : data[:actions]
          raise ArgumentError, "Adapter must list its actions." unless raw.is_a?(Array) && !raw.empty?
          cleaned = []
          raw.each do |action|
            name = action.to_s.strip
            raise ArgumentError, "Unknown adapter action \"#{name}\"." unless ACTIONS.include?(name)
            raise ArgumentError, "Action \"#{name}\" is listed more than once." if cleaned.include?(name)
            cleaned << name
          end
          cleaned
        end

        def self.normalize_script(data)
          raw = value_of(data, "script").strip
          raw = "adapter.js" if raw.empty?
          base = File.basename(raw)
          if base.empty? || base != raw || base == "." || base == ".." || !base.end_with?(".js")
            raise ArgumentError, "Adapter script must be a .js file in the adapter folder."
          end
          base
        end

        def self.normalize_settings(settings, actions)
          cleaned = []
          seen_keys = {}
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
            entry = { "key" => key, "label" => label, "type" => type }
            placeholder = value_of(field, "placeholder")
            hint = value_of(field, "hint")
            entry["placeholder"] = placeholder unless placeholder.empty?
            entry["hint"] = hint unless hint.empty?
            required = field.key?("required_for") ? field["required_for"] : field[:required_for]
            entry["required_for"] = normalize_required(key, required, actions) if required
            headers_from = value_of(field, "headers_from").strip
            entry["headers_from"] = headers_from unless headers_from.empty?
            cleaned << entry
          end
          file_keys = cleaned.select { |field| field["type"] == "file" }.map { |field| field["key"] }
          cleaned.each do |field|
            next unless field["type"] == "column"
            source = field["headers_from"].to_s
            if source.empty? || !file_keys.include?(source)
              raise ArgumentError, "Column \"#{field["key"]}\" must name a file setting in headers_from."
            end
          end
          cleaned
        end

        def self.normalize_required(key, required, actions)
          raise ArgumentError, "required_for on \"#{key}\" must be a list." unless required.is_a?(Array)
          cleaned = []
          required.each do |action|
            name = action.to_s.strip
            raise ArgumentError, "Setting \"#{key}\" requires an unknown action." unless ACTIONS.include?(name)
            unless actions.include?(name)
              raise ArgumentError, "Setting \"#{key}\" requires \"#{name}\", which this adapter does not provide."
            end
            cleaned << name unless cleaned.include?(name)
          end
          cleaned
        end

        def self.value_of(hash, key)
          value = hash.key?(key) ? hash[key] : hash[key.to_sym]
          value.nil? ? "" : value.to_s
        end

        def self.field_key?(key)
          !!(key.to_s =~ FIELD_KEY_RE)
        end
      end
    end
  end
end
