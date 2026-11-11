# bom/exporter.rb — BOM export: traverse model, collect components, compute quantities from bom_rules
# ----------------------------------------------------------------------------------------------
# Traversal: recurse into Groups. A ComponentInstance is a leaf unless its definition
# has traversable=true and itself contains component instances. Then the definition is
# opened and the instance itself is not a BOM row. Report: one row per (definition, rule).
#
# Units: SketchUp's API returns lengths in INCHES internally (areas in in², volumes in in³).
# Quotation quantities are converted to the plugin quotation unit (Settings), then rounded.
# That unit is independent of Model Info. Piece dimensions stay in the model's display unit.
# Area is the square of the length factor and volume is its cube.
# ----------------------------------------------------------------------------------------------

module Logimaxx
  module MaxxBOM
    module BOM
      class Exporter
        BOM_RULES_DICT = "Cialona_BOM_Rules".freeze
        DEFAULT_BOM_RULES_JSON = "[]".freeze

        # Model length unit codes (OptionsManager UnitsOptions LengthUnit)
        LENGTH_UNIT_INCHES = 0
        LENGTH_UNIT_FEET = 1
        LENGTH_UNIT_MILLIMETER = 2
        LENGTH_UNIT_CENTIMETER = 3
        LENGTH_UNIT_METER = 4

        # Set to true to log top_area details to Ruby Console (Window > Ruby Console).
        DEBUG_TOP_AREA = false

        # A component together with its transformation from definition space all
        # the way to model (world) space. ancestor_group_ids is used to identify
        # groups that contain BOM components without walking SketchUp parents.
        Occurrence = Struct.new(:instance, :transformation, :ancestor_group_ids, :ancestor_tags, :ancestor_group_names, :visible) do
          def definition
            instance.definition
          end
        end

        attr_reader :model

        def initialize(model)
          @model = model
        end

        # Traverse model iteratively: open groups, and open component definitions
        # marked traversable. Depth, the instance cap, and the definition path
        # stop a cyclic or corrupted hierarchy.
        MAX_TRAVERSAL_DEPTH = 500
        MAX_INSTANCES = 500_000

        # Returns [occurrences, groups]: component instances with their cumulative
        # world transformations, and all groups seen. Traversable components are
        # containers: their nested instances are collected, they are not.
        def collect_component_instances_and_groups(entities = nil)
          entities = entities || model.entities
          @visible_group_ids = {}
          out_occurrences = []
          out_groups = []
          identity = Geom::Transformation.new
          stack = [[entities, identity, [], [], [], true, [], 0]]
          while stack.any?
            ents, parent_tr, ancestor_group_ids, ancestor_tags, ancestor_group_names, ancestors_visible, ancestor_definition_ids, depth = stack.pop
            next if depth > MAX_TRAVERSAL_DEPTH
            next unless ents.respond_to?(:each)
            ents.each do |e|
              case e
              when Sketchup::Group
                next unless e.respond_to?(:entities)
                out_groups << e
                child = e.entities
                child_tr = parent_tr * e.transformation
                child_ancestors = ancestor_group_ids + [e.object_id]
                child_tags = ancestor_tags + [entity_tag_name(e)]
                child_group_names = ancestor_group_names + [group_name(e)]
                child_visible = ancestors_visible && entity_and_tag_visible?(e)
                # A group reached through several placements counts as visible if any of them is.
                visible_group_ids[e.object_id] = true if child_visible
                stack << [child, child_tr, child_ancestors, child_tags, child_group_names, child_visible, ancestor_definition_ids, depth + 1] if child
              when Sketchup::ComponentInstance
                definition = e.definition
                next if definition.nil?
                next if definition.group?
                if open_traversable_component?(definition, ancestor_definition_ids)
                  child = definition.entities
                  child_tr = parent_tr * e.transformation
                  child_tags = ancestor_tags + [entity_tag_name(e)]
                  child_names = ancestor_group_names + [group_name(e)]
                  child_visible = ancestors_visible && entity_and_tag_visible?(e)
                  child_definitions = ancestor_definition_ids + [definition.object_id]
                  stack << [child, child_tr, ancestor_group_ids, child_tags, child_names, child_visible, child_definitions, depth + 1]
                else
                  world_tr = parent_tr * e.transformation
                  occurrence_visible = ancestors_visible && entity_and_tag_visible?(e)
                  out_occurrences << Occurrence.new(e, world_tr, ancestor_group_ids, ancestor_tags, ancestor_group_names, occurrence_visible)
                  return [out_occurrences, out_groups] if out_occurrences.size >= MAX_INSTANCES
                end
              else
                # Face, Edge, etc. — skip
              end
            end
          end
          [out_occurrences, out_groups]
        end

        def collect_component_instances(entities = nil)
          collect_component_instances_and_groups(entities).first
        end

        # object_id => true for groups seen visible during the last traversal.
        def visible_group_ids
          @visible_group_ids ||= {}
        end

        # Groups that contain at least one of the given component instances (ancestor chain).
        def group_ids_containing_instances(occurrences)
          ids = {}
          occurrences.each do |occurrence|
            occurrence.ancestor_group_ids.each { |id| ids[id] = true }
          end
          ids
        end

        # Groups that contain no component instance (only geometry and possibly nested geometry-only groups).
        def geometry_only_groups(all_groups, instances)
          containing_ids = group_ids_containing_instances(instances)
          all_groups.reject { |g| containing_ids[g.object_id] }
        end

        # Group instances by their definition. Returns Hash: definition => [instance, ...]
        def group_by_definition(occurrences)
          occurrences.group_by(&:definition)
        end

        # Load bom_rules (array of rule hashes) from a component definition. Returns [] if none.
        def bom_rules_for_definition(definition)
          dict = definition.respond_to?(:attribute_dictionaries) && definition.attribute_dictionaries &&
                 definition.attribute_dictionary(BOM_RULES_DICT)
          return [] unless dict
          raw = dict["bom_rules"]
          return [] if raw.to_s.strip.empty?
          rules = JSON.parse(raw.to_s)
          return [] unless rules.is_a?(Array)
          rules.each do |rule|
            next unless rule.is_a?(Hash)
            raw_uom = rule.key?("uom") ? rule["uom"] : rule[:uom]
            next if raw_uom.nil?
            rule["uom"] = Logimaxx::MaxxBOM::UI::Settings.normalize_plugin_uom(raw_uom)
          end
          rules
        end

        # True only when dict["traversable"] == "true". Absent means a BOM leaf.
        # Cached per definition: the same definition is tested once per instance.
        def traversable_definition?(definition)
          return false unless definition
          @traversable_definitions ||= {}
          id = definition.object_id
          return @traversable_definitions[id] if @traversable_definitions.key?(id)

          dict = definition.respond_to?(:attribute_dictionaries) && definition.attribute_dictionaries &&
                 definition.attribute_dictionary(BOM_RULES_DICT)
          @traversable_definitions[id] = !!(dict && dict["traversable"].to_s.downcase == "true")
        end

        # Open a traversable component unless this descent already passed through
        # the same definition. A flagged definition with no inner components stays
        # a leaf, so its own geometry is not dropped from the BOM.
        def open_traversable_component?(definition, ancestor_definition_ids)
          return false unless definition.respond_to?(:entities) && definition.entities
          return false if ancestor_definition_ids.include?(definition.object_id)
          return false unless traversable_definition?(definition)
          contains_component_instances?(definition)
        end

        def contains_component_instances?(definition)
          return false unless definition
          @contains_component_instances ||= {}
          id = definition.object_id
          return @contains_component_instances[id] if @contains_component_instances.key?(id)
          @contains_component_instances[id] = self.class.contains_component_instances?(definition)
        end

        # True when a component instance exists in the definition, including
        # inside groups. Nested component definitions are not opened: the
        # instance itself is enough.
        def self.contains_component_instances?(definition)
          return false unless definition.respond_to?(:entities) && definition.entities
          stack = [[definition.entities, 0]]
          visited = {}
          while stack.any?
            entities, depth = stack.pop
            next if depth > MAX_TRAVERSAL_DEPTH
            next unless entities.respond_to?(:each)
            next if visited[entities.object_id]
            visited[entities.object_id] = true
            entities.each do |entity|
              case entity
              when Sketchup::Group
                child = entity.entities if entity.respond_to?(:entities)
                stack << [child, depth + 1] if child
              when Sketchup::ComponentInstance
                next if entity.definition.nil? || entity.definition.group?
                return true
              end
            end
          end
          false
        end

        # True unless dict["exportable"] == "false". Default is exportable.
        def exportable_for_definition(definition)
          dict = definition.respond_to?(:attribute_dictionaries) && definition.attribute_dictionaries &&
                 definition.attribute_dictionary(BOM_RULES_DICT)
          return true unless dict
          dict["exportable"].to_s.downcase != "false"
        end

        # Build report: { rows: [...], rows_without_rules: [...], rows_geometry_only: [...] }.
        # rows = components that have bom_rules (one row per rule).
        # rows_without_rules = components with no bom_rules, one row per definition, count only.
        # rows_geometry_only = groups that contain no component instances (geometry only), one row per group.
        #
        # Hidden occurrences are left out: an instance that is hidden, sits on a
        # hidden tag (or tag folder), or lies inside a hidden group/component.
        def build_report(instances_by_definition = nil)
          all_instances, all_groups = collect_component_instances_and_groups
          instances = all_instances.select(&:visible)
          instances_by_definition ||= group_by_definition(instances)
          rows = []
          rows_without_rules = []
          instances_by_definition.each do |definition, insts|
            definition_name = definition.name.to_s.strip
            definition_name = definition.entityID.to_s if definition_name.empty?
            first_instance = insts&.first&.instance
            rules = bom_rules_for_definition(definition)
            if rules.empty?
              rows_without_rules << report_row_without_rules(definition, definition_name, insts.size, first_instance)
            else
              rules.each do |rule|
                qty = compute_quantity(insts, rule)
                rows << report_row(definition, definition_name, rule, qty, first_instance)
              end
            end
          end
          # A hidden group is not listed. A group whose components are all hidden
          # still holds components, so it is not geometry-only either.
          visible_groups = all_groups.select { |g| visible_group_ids[g.object_id] }.uniq
          geometry_only = geometry_only_groups(visible_groups, all_instances)
          rows_geometry_only = geometry_only.map { |g| report_row_geometry_only(g) }
          {
            rows: rows,
            rows_without_rules: rows_without_rules,
            rows_geometry_only: rows_geometry_only,
            model_length_unit: model_length_unit_name
          }
        end

        # Production-oriented parts list. Unlike the quotation BOM above, this
        # keeps the physical size and assigned SketchUp tag of every occurrence.
        # Equal occurrences are grouped into one row with a piece count.
        def build_piece_report(occurrences)
          grouped = {}
          occurrences.each do |occurrence|
            next unless occurrence.visible
            dimensions = occurrence_dimensions(occurrence)
            next unless dimensions

            definition = occurrence.definition
            name = definition.name.to_s.strip
            name = definition.entityID.to_s if name.empty?
            tag = effective_tag_name(occurrence)
            parent_group = (occurrence.ancestor_group_names || []).last.to_s
            rounded_dimensions = dimensions.map { |value| value.round(4) }
            key = [name, parent_group, tag, rounded_dimensions]
            row = grouped[key]
            if row
              row[:quantity] += 1
              row[:entity_ids] << occurrence.instance.entityID if occurrence.instance.respond_to?(:entityID)
            else
              entity_id = occurrence.instance.respond_to?(:entityID) ? occurrence.instance.entityID : nil
              grouped[key] = {
                tag: tag,
                group_name: parent_group,
                definition_name: name,
                definition_id: definition.entityID,
                select_entity_id: entity_id,
                length: rounded_dimensions[0],
                width: rounded_dimensions[1],
                thickness: rounded_dimensions[2],
                quantity: 1,
                entity_ids: entity_id ? [entity_id] : []
              }
            end
          end

          grouped.values.sort_by do |row|
            [row[:definition_name].to_s.downcase, row[:group_name].to_s.downcase, row[:tag].to_s.downcase, -row[:length], -row[:width], -row[:thickness]]
          end
        end

        # Dimensions along the component's own axes, including instance scale.
        # Sorting makes groups stable when otherwise identical parts are rotated.
        def occurrence_dimensions(occurrence)
          bounds = occurrence.definition.bounds
          return nil unless bounds && bounds.valid?
          tr = occurrence.transformation
          origin = Geom::Point3d.new(0, 0, 0).transform(tr)
          axis_points = [
            Geom::Point3d.new(bounds.width, 0, 0),
            Geom::Point3d.new(0, bounds.height, 0),
            Geom::Point3d.new(0, 0, bounds.depth)
          ]
          values = axis_points.map { |point| origin.distance(point.transform(tr)) * native_length_unit_factor }
          values.sort.reverse
        end

        def entity_tag_name(entity)
          layer = entity.respond_to?(:layer) ? entity.layer : nil
          name = layer.respond_to?(:name) ? layer.name.to_s.strip : ""
          name.empty? ? "Untagged" : name
        end

        # A drawing element is shown only when both the element itself and its
        # assigned SketchUp tag/layer are visible. Ancestor visibility is
        # accumulated during traversal and stored on each occurrence.
        def entity_and_tag_visible?(entity)
          entity_visible = !entity.respond_to?(:visible?) || entity.visible?
          layer = entity.respond_to?(:layer) ? entity.layer : nil
          entity_visible && layer_effectively_visible?(layer)
        rescue StandardError
          false
        end

        def layer_effectively_visible?(layer)
          return true unless layer
          return false if layer.respond_to?(:visible?) && !layer.visible?

          folder = layer.respond_to?(:folder) ? layer.folder : nil
          visited = {}
          while folder && !visited[folder.object_id]
            visited[folder.object_id] = true
            return false if folder.respond_to?(:visible?) && !folder.visible?
            folder = folder.respond_to?(:folder) ? folder.folder : nil
          end
          true
        end

        def effective_tag_name(occurrence)
          direct_tag = entity_tag_name(occurrence.instance)
          return direct_tag unless direct_tag == "Untagged"
          inherited = (occurrence.ancestor_tags || []).reverse.find { |tag| tag && tag != "Untagged" }
          inherited || direct_tag
        end

        def group_name(group)
          name = group.respond_to?(:name) ? group.name.to_s.strip : ""
          if name.empty? && group.respond_to?(:definition) && group.definition
            name = group.definition.name.to_s.strip
          end
          name = group.entityID.to_s if name.empty? && group.respond_to?(:entityID)
          name
        end

        def report_row_without_rules(definition, definition_name, count, first_instance = nil)
          {
            definition_name: definition_name,
            definition_id: definition.entityID,
            select_entity_id: first_instance.respond_to?(:entityID) ? first_instance.entityID : nil,
            code: "",
            label: "",
            measure: "count",
            uom: "pcs",
            quantity: count.to_f,
            category: "",
            section: "without_rules",
            exportable: exportable_for_definition(definition)
          }
        end

        def report_row_geometry_only(group)
          name = group.respond_to?(:name) ? group.name.to_s.strip : ""
          name = group.entityID.to_s if name.empty?
          {
            definition_name: name,
            definition_id: group.respond_to?(:entityID) ? group.entityID : nil,
            select_entity_id: group.respond_to?(:entityID) ? group.entityID : nil,
            code: "",
            label: "",
            measure: "count",
            uom: "pcs",
            quantity: 1.0,
            category: "",
            section: "geometry_only"
          }
        end

        def report_row(definition, definition_name, rule, quantity, first_instance = nil)
          {
            definition_name: definition_name,
            definition_id: definition.entityID,
            select_entity_id: first_instance.respond_to?(:entityID) ? first_instance.entityID : nil,
            code: (rule["code"] || rule[:code]).to_s,
            label: (rule["label"] || rule[:label]).to_s,
            measure: (rule["measure"] || rule[:measure]).to_s,
            uom: (rule["uom"] || rule[:uom]).to_s,
            quantity: quantity,
            category: (rule["category"] || rule[:category]).to_s,
            section: "with_rules",
            exportable: exportable_for_definition(definition)
          }
        end

        def length_unit_enum
          (model.options["UnitsOptions"] && model.options["UnitsOptions"]["LengthUnit"]) rescue nil
        end

        # Plugin setting. The model's LengthUnit is only the drawing unit.
        def quotation_length_unit
          Logimaxx::MaxxBOM::UI::Settings.stored_quotation_length_unit
        end

        # Multiplier: inches → quotation length unit.
        def length_unit_factor
          Logimaxx::MaxxBOM::UI::Settings.quotation_length_factor(quotation_length_unit)
        end

        # Multiplier: sq inches → quotation area unit.
        def area_unit_factor
          length_unit_factor ** 2
        end

        # Multiplier: cubic inches → quotation volume unit.
        def volume_unit_factor
          length_unit_factor ** 3
        end

        # Symbol of the quotation unit (m, cm, mm, ft, in), shared by length, area and volume.
        def model_length_unit_name
          quotation_length_unit
        end

        # Native model units are more useful for physical piece dimensions than
        # the quotation units, where every metric model is intentionally in m.
        def native_length_unit_factor
          case length_unit_enum
          when LENGTH_UNIT_INCHES then 1.0
          when LENGTH_UNIT_FEET then 1.0 / 12.0
          when LENGTH_UNIT_MILLIMETER then 25.4
          when LENGTH_UNIT_CENTIMETER then 2.54
          when LENGTH_UNIT_METER then 0.0254
          else 1.0
          end
        end

        def model_native_length_unit_name
          case length_unit_enum
          when LENGTH_UNIT_INCHES then "in"
          when LENGTH_UNIT_FEET then "ft"
          when LENGTH_UNIT_MILLIMETER then "mm"
          when LENGTH_UNIT_CENTIMETER then "cm"
          when LENGTH_UNIT_METER then "m"
          else "in"
          end
        end

        # Compute quantity for a list of instances and a single rule (measure type).
        # Length/area/volume measures are converted to the quotation unit, then rounded.
        def compute_quantity(instances, rule)
          measure = (rule["measure"] || rule[:measure]).to_s
          raw = case measure
                when "count" then compute_count(instances)
                when "bbox_volume" then compute_bbox_volume(instances)
                when "bbox_dimensions" then compute_bbox_dimensions(instances)
                when "total_area" then compute_total_area(instances)
                when "material_area" then compute_material_area(instances, rule)
                when *FACE_SIDE_AREAS
                  compute_face_area(instances, *FACE_SIDES[measure.sub(/_area\z/, "")])
                when *FACE_SIDE_PERIMETERS
                  compute_face_perimeter(instances, *FACE_SIDES[measure.sub(/_perimeter\z/, "")])
                when "edge_length" then compute_edge_length(instances)
                when "smart_length" then compute_smart_length(instances)
                else compute_count(instances)
                end
          apply_rounding(raw.to_f * multiplier_for(rule), rule)
        end

        # Schema default is 1. Negative values are clamped to 0.
        def multiplier_for(rule)
          m = rule["multiplier"] || rule[:multiplier]
          return 1.0 if m.nil? || m.to_s.strip.empty?
          f = m.to_f
          f < 0 ? 0.0 : f
        end

        def compute_count(instances)
          instances.size.to_f
        end

        def compute_bbox_volume(instances)
          total = 0.0
          instances.each do |occurrence|
            b = transformed_bounds(occurrence)
            next unless b.valid?
            total += b.width * b.height * b.depth
          end
          total * volume_unit_factor
        end

        def compute_bbox_dimensions(instances)
          return 0.0 if instances.empty?
          b = Geom::BoundingBox.new
          instances.each { |occurrence| add_bounds(b, transformed_bounds(occurrence)) }
          return 0.0 unless b.valid?
          (b.width * b.height * b.depth) * volume_unit_factor
        end

        def compute_total_area(instances)
          total = 0.0
          instances.each do |occurrence|
            tr = occurrence.transformation
            occurrence.definition.entities.grep(Sketchup::Face).each do |face|
              total += face.area(tr)
            end
          end
          total * area_unit_factor
        end

        # Faces within this of the extreme plane (inches). The normal must be
        # nearly parallel to the side axis (either sign); 0.99 keeps it square.
        Z_TOL_TOP_AREA = 0.004 # ~0.1 mm in inches
        UP_TOL_TOP_AREA = 0.99

        # Outer face on one side of the world-aligned bounds.
        # front = min Y, back = max Y, left = min X, right = max X,
        # bottom = min Z, top = max Z. The third value is the conventional
        # outward normal sign; side_faces ignores it so mirrored instances
        # still measure.
        FACE_SIDES = {
          "top" => [:z, :max, 1],
          "bottom" => [:z, :min, -1],
          "front" => [:y, :min, -1],
          "back" => [:y, :max, 1],
          "left" => [:x, :min, -1],
          "right" => [:x, :max, 1]
        }.freeze
        FACE_SIDE_AREAS = FACE_SIDES.keys.map { |side| "#{side}_area" }.freeze
        FACE_SIDE_PERIMETERS = FACE_SIDES.keys.map { |side| "#{side}_perimeter" }.freeze

        def compute_face_area(instances, axis, extreme, _normal_sign = nil)
          total = 0.0
          instances.each_with_index do |occurrence, idx|
            selected = side_faces(occurrence, axis, extreme)
            next unless selected
            faces, tr, target = selected
            area_sq_in = faces.sum { |face| face.area(tr) }
            total += area_sq_in

            if DEBUG_TOP_AREA && idx == 0 && axis == :z && extreme == :max
              puts "\n[BOM top_area DEBUG] #{occurrence.definition.name} max_z=#{target} top_faces=#{faces.size} area_sq_in=#{area_sq_in}\n"
            end
          end
          total * area_unit_factor
        end

        # Area of faces that have the selected material (rule["params"]["material"] = material name).
        def compute_material_area(instances, rule)
          material_name = (rule["params"] || rule[:params]) && ((rule["params"] || rule[:params])["material"] || (rule["params"] || rule[:params])[:material])
          material_name = material_name.to_s.strip
          return 0.0 if material_name.empty?

          total = 0.0
          instances.each do |occurrence|
            tr = occurrence.transformation
            occurrence.definition.entities.grep(Sketchup::Face).each do |face|
              next unless face.material
              next unless face.material.name.to_s == material_name
              total += face.area(tr)
            end
          end
          total * area_unit_factor
        end

        # Faces on the outer plane of one world-aligned side. The normal must
        # be nearly parallel to that axis; either sign is accepted so a
        # mirrored instance still contributes. Returns
        # [faces, transformation, plane coordinate], or nil when empty.
        def side_faces(occurrence, axis, extreme, _normal_sign = nil)
          bounds = transformed_bounds(occurrence)
          return nil unless bounds.valid?
          tr = occurrence.transformation
          target = (extreme == :max ? bounds.max : bounds.min).send(axis)
          faces = occurrence.definition.entities.grep(Sketchup::Face).select do |face|
            normal = transformed_face_normal(face, tr)
            next false unless normal
            next false if normal.send(axis).abs < UP_TOL_TOP_AREA
            face_on_plane?(face, tr, axis, target, Z_TOL_TOP_AREA)
          end
          [faces, tr, target]
        end

        # Perimeter of one outer side: length of edges that belong to exactly one selected face.
        def compute_face_perimeter(instances, axis, extreme, _normal_sign = nil)
          total = 0.0
          instances.each do |occurrence|
            selected = side_faces(occurrence, axis, extreme)
            next unless selected
            faces, tr, = selected
            next if faces.empty?

            selected_set = faces.map { |face| [face, true] }.to_h
            boundary_edges = []
            faces.each do |face|
              face.edges.each do |edge|
                adjacent = edge.faces.count { |other| selected_set[other] }
                boundary_edges << edge if adjacent == 1
              end
            end
            total += boundary_edges.uniq.sum { |edge| edge_length_in_world(edge, tr) }
          end
          total * length_unit_factor
        end

        def edge_length_in_world(edge, tr)
          p1 = edge.start.position.transform(tr)
          p2 = edge.end.position.transform(tr)
          p1.distance(p2)
        end

        # Edge length = length of edges in world space.
        def compute_edge_length(instances)
          total = 0.0
          instances.each do |occurrence|
            tr = occurrence.transformation
            occurrence.definition.entities.grep(Sketchup::Edge).each do |edge|
              total += edge_length_in_world(edge, tr)
            end
          end
          total * length_unit_factor
        end

        # Length of a curve (arc/polyline) in world space (inches).
        def curve_length_in_inches(curve, tr)
          curve.edges.sum { |e| edge_length_in_world(e, tr) }
        end

        # Max curve length in component (recursive into nested instances/groups). Returns inches.
        def dominant_curve_length_in_inches(occurrence, recursive: true)
          best_len_in = 0.0
          walker = lambda do |entities, tr_acc|
            entities.grep(Sketchup::Edge).each do |e|
              c = e.curve
              next unless c
              len_in = curve_length_in_inches(c, tr_acc)
              best_len_in = len_in if len_in > best_len_in
            end
            return unless recursive
            entities.each do |ent|
              case ent
              when Sketchup::ComponentInstance
                walker.call(ent.definition.entities, tr_acc * ent.transformation)
              when Sketchup::Group
                walker.call(ent.entities, tr_acc * ent.transformation)
              end
            end
          end
          walker.call(occurrence.definition.entities, occurrence.transformation)
          best_len_in
        end

        # Per-instance length: dominant curve length, or max bbox dimension in world (inches).
        def smart_length_single_in_inches(occurrence)
          len_in = dominant_curve_length_in_inches(occurrence, recursive: true)
          return len_in if len_in > 0.0
          bb = transformed_bounds(occurrence)
          return 0.0 unless bb.valid?
          [bb.width, bb.depth, bb.height].max.to_f
        end

        def compute_smart_length(instances)
          total_in = instances.sum { |occurrence| smart_length_single_in_inches(occurrence) }
          total_in * length_unit_factor
        end

        def transformed_bounds(occurrence)
          result = Geom::BoundingBox.new
          add_entities_to_bounds(
            occurrence.definition.entities,
            occurrence.transformation,
            result,
            0
          )
          result
        end

        # Build a tight world-space bounding box from transformed geometry.
        # Transforming a definition bounding box is only conservative after a
        # rotation and can put max/min Z where no actual face exists.
        def add_entities_to_bounds(entities, tr, bounds, depth)
          return bounds if depth > MAX_TRAVERSAL_DEPTH

          entities.each do |entity|
            case entity
            when Sketchup::Face
              entity.vertices.each { |vertex| bounds.add(vertex.position.transform(tr)) }
            when Sketchup::Edge
              bounds.add(entity.start.position.transform(tr))
              bounds.add(entity.end.position.transform(tr))
            when Sketchup::Group
              add_entities_to_bounds(entity.entities, tr * entity.transformation, bounds, depth + 1)
            when Sketchup::ComponentInstance
              next if entity.definition.nil?
              add_entities_to_bounds(entity.definition.entities, tr * entity.transformation, bounds, depth + 1)
            end
          end

          bounds
        end

        def add_bounds(target, source)
          return target unless source.valid?
          8.times { |index| target.add(source.corner(index)) }
          target
        end

        def face_at_z?(face, tr, target_z, tolerance)
          face_on_plane?(face, tr, :z, target_z, tolerance)
        end

        def face_on_plane?(face, tr, axis, target, tolerance)
          face.vertices.all? do |vertex|
            (vertex.position.transform(tr).send(axis) - target).abs <= tolerance
          end
        end

        # Build the normal from transformed geometry. This remains correct for
        # non-uniform scales, unlike transforming the original normal as a vector.
        def transformed_face_normal(face, tr)
          points = face.vertices.first(3).map { |vertex| vertex.position.transform(tr) }
          return nil if points.size < 3
          normal = (points[1] - points[0]) * (points[2] - points[0])
          return nil unless normal.valid? && normal.length > 0.0
          normal.normalize
        end

        def apply_rounding(value, rule)
          rnd = rule["rounding"] || rule[:rounding]
          return value.to_f unless rnd.is_a?(Hash)
          mode = (rnd["mode"] || rnd[:mode]).to_s
          step = (rnd["step"] || rnd[:step]).to_f
          step = 0.01 if step <= 0
          case mode
          when "ceil" then (value.to_f / step).ceil * step
          when "floor" then (value.to_f / step).floor * step
          when "round" then (value.to_f / step).round * step
          else value.to_f
          end
        end

        # Find a Group or ComponentInstance in the model by entityID (for selection from UI).
        def self.find_entity_by_id(model, entity_id)
          return nil if model.nil? || entity_id.nil?
          id_str = entity_id.to_s
          return nil if id_str.empty?
          visited = {}
          stack = [model.entities]
          while stack.any?
            ents = stack.pop
            next if visited[ents.object_id]
            visited[ents.object_id] = true
            next unless ents.respond_to?(:each)
            ents.each do |e|
              if e.respond_to?(:entityID) && e.entityID.to_s == id_str
                return e
              end
              if e.is_a?(Sketchup::Group) && e.respond_to?(:entities)
                child = e.entities
                stack << child if child && !visited[child.object_id]
              elsif e.is_a?(Sketchup::ComponentInstance) && e.definition && !e.definition.group? && e.definition.respond_to?(:entities)
                child = e.definition.entities
                stack << child if child && !visited[child.object_id]
              end
            end
          end
          nil
        end

        # Convenience: run full export and return report rows.
        def self.export(model)
          new(model).build_report
        end


        def self.export_pieces(model)
          exporter = new(model)
          occurrences = exporter.collect_component_instances
          {
            piece_rows: exporter.build_piece_report(occurrences),
            piece_length_unit: exporter.model_native_length_unit_name
          }
        end
      end
    end
  end
end
