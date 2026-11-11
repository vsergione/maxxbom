# MaxxBOM
## Overview

MaxxBOM is a SketchUp extension that extracts a Bill of Materials (BOM) from a model.

The goal is a deterministic, reproducible BOM. How parts are identified, measured, and aggregated is defined by BOM rules on the model, not by a client-specific convention built into the extension. The product catalog and order exchange come from data sources, each one a named instance of an adapter plugin.

## Scope

### Data sources

Product lookup uses one data source. Offer import and export use that same data source when its adapter implements `orders.load` and `orders.export`. A data source is a named setup of an installed adapter plugin. The same plugin can be used more than once, for example two CSV files or two MaxxOps companies. In **Plugin Settings → General**, **Product lookup** lists data sources that implement `catalog.search`. **Free edit mode** is the choice when no data source is used. Free edit mode allows arbitrary rule values and turns lookup and offer calls off. In **Plugin Settings → Data sources**, **Add** creates one from an installed plugin. Click a card to set that data source up.

The extension ships with no connection of its own. **Plugin Settings → Plugins** lists adapters placed in `plugins/` under Available; **Load** installs that plugin so it can be chosen when adding a data source. **Load plugin…** picks an `adapter.json` from another location. Removing a plugin removes the data sources that use it. The CSV adapter cannot be removed.

An adapter describes the connection fields the dialog shows and the actions its script implements. `plugins/filemaker/` and `plugins/maxxops/` search a catalog and read or update offer lines. `plugins/csv/` only searches a local product file. Loading FileMaker the first time copies a connection saved by an older build. The first time settings open after this change, each previously loaded adapter becomes a data source, and a saved catalog CSV becomes a CSV data source.

### CSV files

The catalog CSV is the `csv` data source, not a separate product-source switch. Quantity and piece files written from Export BOM, and reloading a previous quantity file into the offer review, stay in the extension.

**Catalog.** Add a data source from the CSV catalog adapter, choose the file, and map its header columns to code, name, unit, category, and unit price. Code is required before that data source can search. Category and unit price are optional: the quantity export uses each one only when that column is mapped. Product search and code validation then go through that data source. The first row is the header. Quoted fields, doubled quotes, commas and newlines inside quotes, CRLF or LF line endings, and a leading UTF-8 BOM are accepted. A Windows path is stored with forward slashes, because SketchUp would otherwise treat backslashes in a saved preference as escapes.

**Quantities.** After **Scan Model** with the quantities export, **Export to CSV** writes one row per code, unit, and category. Columns are `code`, `quantity`, `uom`, and `category`. `category` is left out when the product lookup data source has a category column and it is not mapped; those rows are then totaled by code and unit. When unit price is mapped, the file also has `price` and `total`. `price` is that code’s unit price from the lookup data source. `total` is the aggregated quantity times that price. A blank price leaves both cells empty. `uom` is the external unit name from unit mapping. Only components that have BOM rules and are marked exportable are included. The export is refused while an exportable component still has no BOM rule. The file is UTF-8; the suggested name is `bom_export.csv`.

**Offer review.** **Load offer CSV**, shown after a quantities scan, reads a file with `code`, `quantity`, and `uom` (`category` may be absent; `price` and `total` are ignored) and fills the same offer comparison as an API load. Units are matched through the unit map. This does not write the order. Updating an order uses the selected data source when that adapter can read and update offer lines.

**Pieces.** After a pieces scan, **Export pieces to CSV** writes one row per piece: `code`, `group`, `tag/layer`, length, width, thickness, and `quantity`. Length, width, and thickness stay in the model’s length unit. The file is UTF-8; the suggested name is `piece_export.csv`.

The extension is responsible for:
- Reading geometry and metadata from SketchUp models
- Interpreting components, groups, layers, rules, and naming conventions according to the BOM rules on the model
- Applying the transformation and aggregation logic those rules define
- Exporting a BOM in the agreed structure and format
- Anything outside these rules is explicitly out of scope unless documented and agreed upon.

## Key Principles

- **Specification-driven**. Documented BOM rules and the selected data source are the source of truth for a given export.
- **No implicit assumptions.** Any ambiguous or missing rule must be clarified or explicitly documented as an assumption.
- **Deterministic output**. Same input model and same rules → same BOM output, every time.
- **Extensibility over hacks**. Client-specific behavior belongs in BOM rules or an adapter plugin, so the extension stays generic.

## Input Model Assumptions

The extension assumes that SketchUp models:
- Follow the agreed component / group structure
- Use naming conventions and rules as specified
- Represent geometry in real-world units (as defined in the spec)

If a model violates these assumptions, results are undefined unless validation rules are added.

## Output

A quantities export is one row per code, unit, and category: `code`, `quantity`, `uom`, `category`. Category is omitted when the product lookup data source has a category column and it is not mapped. When the unit price column is mapped, the row also has `price` and `total` (quantity × unit price). A pieces export is one row per piece, with definition name, group, tag, length, width, thickness, and quantity. Column names and the files that carry them are described under CSV files.

Exact calculation rules for quantities and dimensions are defined in the specification and test examples.

## Development Workflow

- All code is versioned in this repository
- Changes are tracked via commits and pull requests
- Specification changes must be reflected either in:
  - updated documentation, or
  - test cases demonstrating the new behavior

## Validation

Validation is done by:
- Comparing exported BOMs against real reference models
- Reviewing edge cases explicitly (nested components, mirrored geometry, custom objects, etc.)

If a case is not covered by tests or documentation, behavior should not be assumed.

## Non-Goals

This project does not aim to:
- Replace SketchUp modeling best practices
- Automatically “fix” invalid models
- Guess intent where data is missing
- Hard-code one client’s production or costing rules into the extension

Status

Current phase: Specification alignment & initial implementation
