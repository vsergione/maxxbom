# ui/rules.rb — Rules dialog
# ------------------------------------------------------------------------------
# Saved on the component definition as schema_version, bom_rules, exportable
# and traversable. bom_rules holds code, label, uom, measure, category,
# multiplier (default 1), rounding{mode, step}, params.material.
# traversable defaults to false: the component is a BOM leaf. "true" opens it
# during traversal only when the definition contains component instances.
# A traversable component is not measurable and is not exported: its bom_rules
# are stored empty and exportable is false.
# ------------------------------------------------------------------------------
module Logimaxx
  module MaxxBOM
    module UI
      module Rules
        DIALOG_ID = :rules
        BOM_RULES_DICT = "Cialona_BOM_Rules".freeze
        UOM_OPTIONS = %w[pcs area length volume custom].freeze
        MEASURE_OPTIONS = %w[
          count top_area bottom_area front_area back_area left_area right_area
          total_area material_area
          top_perimeter bottom_perimeter front_perimeter back_perimeter
          left_perimeter right_perimeter edge_length smart_length
          bbox_volume bbox_dimensions
        ].freeze
        ROUNDING_MODES = %w[none ceil floor round].freeze

        def self.template_path
          File.join(UI::UI_DIR, 'rules.html')
        end

        # Unique key so SketchUp saves/restores position and size in the tray.
        PREFERENCES_KEY = "Logimaxx_CialonaBOMExporter_Attributes".freeze

        # Show this dialog in the right-side inspector tray (Windows Tray) instead of a floating window.
        USE_INSPECTOR = false

        def self.opts
          {
            width: 720,
            height: 520,
            title: "#{Logimaxx::MaxxBOM::DISPLAY_NAME} — Rules",
            preferences_key: PREFERENCES_KEY,
            style: ::UI::HtmlDialog::STYLE_DIALOG  # Required for Tray / show_inspector
          }
        end

        def self.register(dialog)
          dialog.add_action_callback('ready') { |*_| on_ready }
          dialog.add_action_callback('test') { |*_| on_test }
          dialog.add_action_callback('save_rules') { |_ctx, json| on_save_rules(json) }
          dialog.add_action_callback('preview_rules') { |_ctx, json| on_preview_rules(dialog, json) }
          dialog.add_action_callback('get_catalog_settings') { |*_| on_get_catalog_settings(dialog) }
          if dialog.respond_to?(:set_on_closed)
            dialog.set_on_closed { on_closed }
          end
        end

        def self.on_get_catalog_settings(dialog)
          settings = Logimaxx::MaxxBOM::UI::Settings
          free_edit_mode = settings.stored_free_edit_mode
          catalog = DataSources.slot(
            DataSources.catalog_id,
            expose_script: !free_edit_mode,
            concern: :catalog
          )
          payload = {
            catalog: catalog,
            free_edit_mode: free_edit_mode,
            unit_map: settings.stored_unit_map,
            quotation_length_unit: settings.stored_quotation_length_unit,
            dev_mode: settings.debug_facility_visible?
          }
          Logimaxx::MaxxBOM::UI.inject_json(dialog, "onCatalogSettings", payload)
        end

        # SketchUp's Ruby can accidentally activate native gems from the user's
        # GEM_PATH. Requiring Ruby's csv library also requires the native date
        # extension, so keep this parser self-contained. It reads offer CSV files
        # and adapter file headers: quoted fields, doubled quotes, commas and
        # newlines inside quotes, and CRLF/LF line endings.
        def self.parse_csv(text)
          rows = []
          row = []
          field = +""
          quoted = false
          index = 0

          while index < text.length
            char = text[index]
            if quoted
              if char == '"'
                if text[index + 1] == '"'
                  field << '"'
                  index += 1
                else
                  quoted = false
                end
              else
                field << char
              end
            else
              case char
              when '"'
                raise ArgumentError, "unexpected quote in CSV field" unless field.empty?
                quoted = true
              when ','
                row << field
                field = +""
              when "\n"
                row << field
                rows << row unless row.length == 1 && row[0].empty?
                row = []
                field = +""
              when "\r"
                # Ignore CR; LF completes a Windows line ending.
              else
                field << char
              end
            end
            index += 1
          end

          raise ArgumentError, "unterminated quoted CSV field" if quoted
          unless row.empty? && field.empty?
            row << field
            rows << row
          end
          rows
        end

        def self.on_ready
          ns = Logimaxx::MaxxBOM
          # Attach selection observer only while this dialog is open; it pushes current selection.
          ns.ensure_selection_observer_for_model(Sketchup.active_model)
        end

        def self.on_closed
          ns = Logimaxx::MaxxBOM
          ns.remove_selection_observer
          ns.dialogs.delete(DIALOG_ID)
        end

        def self.on_test
          ::UI.messagebox("Test button clicked")
        end

        def self.on_save_rules(json)
          return ::UI.messagebox("No data to save.") if json.nil? || json.to_s.strip.empty?
          payload = JSON.parse(json)
          schema_version = (payload["schema_version"] || "1.0").to_s
          bom_rules = payload["bom_rules"]
          bom_rules = bom_rules.is_a?(String) ? bom_rules : JSON.generate(bom_rules)
          bom_rules = canonical_bom_rules_json(bom_rules)
          exportable = (payload["exportable"] == true || payload["exportable"].to_s.downcase == "true")
          traversable = (payload["traversable"] == true || payload["traversable"].to_s.downcase == "true")

          model = Sketchup.active_model
          return ::UI.messagebox("No active model.") unless model
          selection = model.selection.to_a
          return ::UI.messagebox("Select a single component to save rules.") unless selection.size == 1

          entity = selection.first
          unless entity.is_a?(Sketchup::ComponentInstance) && entity.definition && !entity.definition.group?
            return ::UI.messagebox("Selection must be a component instance (not a group, face, or edge).")
          end

          definition = entity.definition
          traversable = false unless Logimaxx::MaxxBOM::BOM::Exporter.contains_component_instances?(definition)
          exportable = false if traversable
          bom_rules = "[]" if traversable
          dict = definition.attribute_dictionary(BOM_RULES_DICT, true)
          dict["schema_version"] = schema_version
          dict["bom_rules"] = bom_rules
          dict["exportable"] = exportable ? "true" : "false"
          dict["traversable"] = traversable ? "true" : "false"

          category = last_ruleset_category(bom_rules)
          if category && category.to_s.strip != ""
            tag = model.layers[category] || model.layers.add(category)
            entity.layer = tag
          end
          # ::UI.messagebox("Rules saved.")
        end

        # Live quantity for the rules dialog. Uses the same measurement and
        # rounding as the BOM export: one number for the selected instance,
        # and the definition total when the model contains more copies.
        def self.on_preview_rules(dialog, json)
          request_id = nil
          begin
            payload = JSON.parse(json.to_s)
            request_id = payload["request_id"]
            rules = payload["rules"]
            rules = [] unless rules.is_a?(Array)
            result = build_rule_preview(rules)
            result[:request_id] = request_id
            UI.inject_json(dialog, "onRulePreview", result)
          rescue StandardError => e
            puts "[MaxxBOM] rule preview failed: #{e.class}: #{e.message}"
            begin
              UI.inject_json(dialog, "onRulePreview", { request_id: request_id, status: "error", previews: [] })
            rescue StandardError
              nil
            end
          end
        end

        def self.build_rule_preview(rules)
          model = Sketchup.active_model
          raise "No active model." unless model
          selection = model.selection.to_a
          raise "Select a single component." unless selection.size == 1
          entity = selection.first
          unless Logimaxx::MaxxBOM.component_instance?(entity)
            raise "Selection must be a component."
          end

          exporter = BOM::Exporter.new(model)
          occurrences = exporter.collect_component_instances
          selected, counted = preview_occurrences(model, entity, occurrences)

          previews = rules.each_with_index.map do |rule, index|
            preview_one_rule(exporter, selected, counted, rule, index)
          end
          {
            status: "ok",
            length_unit: UI::Settings.stored_quotation_length_unit,
            previews: previews
          }
        end

        def self.preview_one_rule(exporter, selected, counted, rule, index)
          rule = {} unless rule.is_a?(Hash)
          measure = (rule["measure"] || rule[:measure]).to_s.strip
          return { index: index, status: "incomplete", reason: "measure" } if measure.empty?
          if measure == "material_area"
            params = rule["params"] || rule[:params] || {}
            material = (params["material"] || params[:material]).to_s.strip
            return { index: index, status: "incomplete", reason: "material" } if material.empty?
          end

          quantity = exporter.compute_quantity(selected, rule)
          total = counted.equal?(selected) ? quantity : exporter.compute_quantity(counted, rule)
          {
            index: index,
            status: "ok",
            quantity: quantity,
            total_quantity: total,
            instance_count: counted.size
          }
        rescue StandardError => e
          puts "[MaxxBOM] rule preview #{index} failed: #{e.class}: #{e.message}"
          { index: index, status: "error" }
        end

        # One placement for "this component", and every collected placement of
        # the same definition for the sum. Copies that live inside one parent
        # definition share a single entityID, so the selected placement is the
        # one whose world transform matches the selection.
        def self.preview_occurrences(model, entity, occurrences)
          definition = entity.definition
          same = occurrences.select { |occurrence| occurrence.definition == definition }
          target = world_transformation(model, entity)
          matches = same.select { |occurrence| occurrence.instance.entityID == entity.entityID }
          chosen = if matches.size == 1
            matches.first
          else
            matches.find { |occurrence| same_transformation?(occurrence.transformation, target) }
          end
          chosen ||= BOM::Exporter::Occurrence.new(entity, target, [], [], [], true)
          # The total matches the quantity export, which skips hidden placements.
          counted = same.empty? ? [chosen] : same.select(&:visible)
          [[chosen], counted]
        end

        def self.same_transformation?(left, right)
          return false unless left.respond_to?(:to_a) && right.respond_to?(:to_a)
          left.to_a.zip(right.to_a).all? { |a, b| (a.to_f - b.to_f).abs < 1.0e-6 }
        end

        # World transform for a selected instance that the BOM walk did not
        # collect (for example while editing inside a component). Containers
        # already listed in the active path are not applied twice.
        def self.world_transformation(model, entity)
          tr = Geom::Transformation.new
          Array(model.active_path).each do |container|
            tr *= container.transformation if container.respond_to?(:transformation)
          end

          chain = []
          current = entity
          64.times do
            break unless current.respond_to?(:transformation)
            chain << current
            entities = current.respond_to?(:parent) ? current.parent : nil
            break unless entities.respond_to?(:parent)
            owner = entities.parent
            break if owner.nil? || owner.is_a?(Sketchup::Model) || owner.is_a?(Sketchup::ComponentDefinition)
            break if owner.is_a?(Sketchup::Group) && model.active_path && model.active_path.include?(owner)
            current = owner
          end
          chain.reverse_each { |item| tr *= item.transformation }
          tr
        end

        # Persist quantity kinds. A rule saved as m2, mtr, m or m3 is rewritten on the next save.
        def self.canonical_bom_rules_json(bom_rules)
          text = bom_rules.to_s
          rules = JSON.parse(text)
          return text unless rules.is_a?(Array)
          rules.each do |rule|
            next unless rule.is_a?(Hash)
            raw = rule.key?("uom") ? rule["uom"] : rule[:uom]
            next if raw.nil?
            rule["uom"] = Logimaxx::MaxxBOM::UI::Settings.normalize_plugin_uom(raw)
          end
          JSON.generate(rules)
        rescue JSON::ParserError
          text
        end

        def self.last_ruleset_category(bom_rules_json)
          return nil if bom_rules_json.to_s.strip.empty?
          rules = JSON.parse(bom_rules_json)
          return nil unless rules.is_a?(Array) && rules.any?
          last_rule = rules.last
          last_rule.is_a?(Hash) ? last_rule["category"] : nil
        end
      end
    end
  end
end
