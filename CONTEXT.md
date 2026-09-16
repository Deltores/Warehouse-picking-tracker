# Domain Context — Pick List Tracker

Business and technical glossary. Read this before writing any logic.

---

## Roles

- **Picker (Worker):** Warehouse worker who physically picks components.
  Authenticates by entering their name (not a PIN). Selects a Unit/file, selects their
  Department, then starts picking. Cannot delete data or access Admin settings.
- **Admin:** Supervisor/engineer. Authenticates via PIN (default `1234`).
  Can import files, toggle department visibility, edit column aliases, manage storage,
  change grouping presets, and manually delete units.

---

## Core Domain Terms

- **Unit:** One manufacturing unit being assembled (e.g. "Unit #42", "ASSY-7B").
  One Unit corresponds to one imported Excel file. All picklist items belong to a Unit.
- **Pick List (Picklist):** The Excel (.xlsx) file containing all components to be picked
  for one Unit. Each row = one Work Order line for one Part.
- **Session:** A worker's picking activity for a specific Unit from start to finish.
  Identified by `Session ID` = `SESS-YYYYMMDD-INITIALS-XXX`.
- **Session ID:** Auto-generated unique identifier. Format: `SESS-20260912-JD-342`.
- **Pick Date:** Calendar date the session was started (`YYYY-MM-DD`).
- **Start Timestamp / End Timestamp:** Unix millisecond timestamps of session begin/end.
- **Issued Status:** ERP posting flag. Two states: `Pending Issue` (not yet posted) or `Issued` (posted in ERP).

---

## Picklist Item Fields

- **Unit:** Top-level assembly unit name. Always present. Groups all items in a file.
- **Department:** Area/department responsible for picking the item (e.g. "Hardware", "Assembly", "Paint").
  Unit and Department are always present — they define FIFO scope boundaries.
- **Line:** Production line within a department (optional but supported).
- **Work Order (WO):** Production work order that requires the part. Multiple WOs can need the same Part ID.
- **Part ID:** The component identifier (part number / SKU). One Part ID can appear in multiple WOs.
- **Part Description:** Human-readable name/description of the part.
- **Qty Required:** Total quantity needed for this WO line.
- **Qty Due:** Remaining quantity still needed (= Required − Picked so far).
- **Qty Picked:** Quantity actually picked and confirmed by the worker.

---

## FIFO Logic Summary

- At the **Part ID level** (collapsed view): worker enters total `Qty Picked` for that part within one Department.
- The engine distributes this total across Work Orders of that Part + Department sorted by `rowOrder`.
- WOs are filled sequentially: WO-1 fully → WO-2 fully → WO-3 partially → WO-4+ = 0.
- At the **Work Order level** (expanded view): manual override per WO row is allowed.
- **Hard rule:** FIFO never crosses department boundaries for the same Part ID.

---

## Status Colors (UI)

| Color  | Condition                          |
|--------|------------------------------------|
| Green  | `qtyPicked >= qtyRequired` (≥ 1)  |
| Yellow | `0 < qtyPicked < qtyRequired`      |
| Grey   | `qtyPicked == 0`                   |
| Red    | Error state / danger action        |

---

## Grouping Presets

Named hierarchy configurations for the accordion tree view:
- **Preset 1:** `Unit → Department → Part ID` *(default)*
- **Preset 2:** `Unit → Department → Line → Part ID`
- **Preset 3:** `Unit → Department → Line → Work Order → Part ID`

Presets are switched live from the header dropdown without reloading data.

---

## Storage Constraints

- **Max 40 Units** in SQLite at a time. Auto-FIFO prune on unit #41 import.
- Auto-prune target: oldest `COMPLETED` unit by `completedAt`. Fallback: oldest `createdAt`.
- Only Admins can manually delete units. Workers see no delete button.

---

## File Handling & Excel Export

- One Excel file = One Unit.
- File path is stored in `units.file_path`.
- Before overwrite: backup created as `[OriginalName]_backup.xlsx` in the same directory.
- **Export Filters to Picked / Auto-Issued Rows Only**: Items with `qtyPicked == 0` (and not auto-issued) or blocked items are omitted from the export. The exported Excel contains only items that were physically picked or auto-issued.
- **One-Time Auto-Issue Export per Unit**: Auto-issue items are exported only once per unit (during its initial batch export). Subsequent batch exports omit auto-issue items to prevent re-issuing or duplicated accounting.
- **Direct SQLite Source of Truth**: All quantities (`qtyPicked`, `qtyDue`), session states, and returns are fetched directly from SQLite DB.
- **ON-HAND Display**: ON-HAND location is displayed side-by-side with Part Description across all screens (Grouping Tree, Pick Mode upper panel, and Confirm Pick dialog).
- **Duration Format**: Session and batch durations are formatted as `X min` or `Xh Ymin` (e.g. `30 min`, `1h 24min`, `< 1 min`) to explicitly denote working time elapsed per session/worker.
- **Batch Super Export (Tab 1)**: Consolidates all unexported sessions for a unit with 1-click execution (no popup selection dialog), setting ERP status to `Pending Issue`.
- **MAIN LINE Whole Resource Mode (Admin Tab 5)**: Filtered strictly to MAIN LINE resources. Supports both Combined (All Depts, skipping Department level) and By Department modes, configurable per individual resource ID in Admin Tab 5 and switchable live via worker toggle.

---

## Column Aliases (Default Sets)

| Canonical Key    | Auto-detected Excel Headers                              |
|------------------|----------------------------------------------------------|
| `unit`           | Unit, Unit#, Unit Number, Unit ID                        |
| `department`     | Department, Dept, Area, Section                          |
| `line`           | Line, Prod Line, Production Line, Line Number            |
| `work_order`     | Work Order, WO, WO#, Order, Order Number                 |
| `part_id`        | Part ID, Part, Part#, Part Number, Item Number, SKU      |
| `part_description`| Part Description, Description, Desc, Part Desc          |
| `qty_required`   | Qty Required, Required Qty, Req Qty, Qty Req, Required   |
| `qty_due`        | Qty Due, Due Qty, Due, Remaining, Balance                |
| `qty_picked`     | Qty Picked, Picked Qty, Picked, Qty Issued, Collected    |

Custom aliases added via Admin → Column Mapper are persisted in `admin_config` table.

---

## App Navigation Flow

```
HomeScreen
├── [Admin] → PIN Dialog → AdminScreen (4-tab panel)
│     └── Tab 1: Department Filter (per unit)
│     └── Tab 2: Column Mapper (alias editor)
│     └── Tab 3: Grouping Presets (view/default)
│     └── Tab 4: Storage Manager (40-unit limit, admin delete)
└── [Picker] → PickerFlowScreen
      └── Step 1: Enter Worker Name
      └── Step 2: Select Unit (from loaded files in DB)
             └── [If none] → Import new Excel file first
      └── Step 3: Select Department (filtered to is_active=1)
      └── → PickingScreen (accordion + FIFO + quick controls)
```

---

## MSP Project Control Pattern

This project uses **AGENTS.md** (architecture map) + **CONTEXT.md** (domain glossary)
for AI agent context loading per the MSP Project Control pattern.

### When to call these files
Say at the start of a new chat session:
> "Read AGENTS.md and CONTEXT.md and keep the architecture in mind."

Update AGENTS.md after adding any:
- New screen, service, model, or engine module
- New business rule or data constraint
- Changes to navigation flow or DB schema

Update CONTEXT.md when:
- A new domain term is introduced
- A business rule definition changes
- A new status/state type is added
