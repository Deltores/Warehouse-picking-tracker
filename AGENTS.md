# Project: Pick List Tracker (Android Tablet — Flutter)

## Purpose
Offline-first Android tablet application for warehouse/manufacturing picking operations.
Workers scan/pick components from Excel (.xlsx) picklists. The app handles FIFO WO allocation,
session management, and ERP-ready file export. All code comments and UI text must be in English.

---

## Architecture & File Map

```
lib/
├── main.dart                          # App entry, portrait lock, service wiring
├── engine/
│   ├── column_mapper.dart             # Dynamic Excel header aliasing & normalization
│   ├── fifo_allocation_engine.dart    # Department-scoped FIFO cascade algorithm
│   └── grouping_engine.dart          # Accordion tree builder + metric aggregation
├── models/
│   ├── grouping_preset.dart           # Hierarchy preset definition (GroupLevel enum)
│   ├── picklist_item.dart             # Core picklist row model (all qty fields)
│   ├── session_metadata.dart          # Worker session (id, start, end, issued status)
│   ├── unit_pick_date_urgency.dart    # Robust date parser + urgency evaluation (Red/Yellow/Green)
│   └── unit_record.dart              # Unit / file container model
├── services/
│   ├── database_service.dart          # SQLite (WAL mode), all DB ops, schema migrations
│   ├── excel_service.dart             # .xlsx read → PicklistItem list, in-place overwrite + backup
│   ├── log_service.dart              # Super Admin logging, 49 MB cap, RFC 4180 CSV export
│   └── storage_manager.dart          # 40-unit max capacity, FIFO auto-prune, admin delete
└── ui/
    ├── screens/
    │   ├── home_screen.dart           # Launch screen: Picker, Admin, and Export Hub
    │   ├── picker_flow_screen.dart    # 3-step picker onboarding: name → unit selector (+ import) → dept
    │   ├── picking_screen.dart        # Main picking screen with Accordion / Pick Mode toggle
    │   ├── pick_mode_screen.dart      # Full-screen linear FIFO picking mode
    │   ├── session_export_screen.dart # Global export hub for all completed sessions
    │   ├── admin_screen.dart          # Admin panel: dept toggle, mapper, presets, storage, general (tablet ID)
    │   └── session_start_dialog.dart  # (Legacy) Worker name capture; superseded by PickerFlowScreen
    ├── views/
    │   └── department_parts_view.dart # "List Mode" view for Pick Mode toggle
    ├── theme/
    │   └── app_theme.dart            # Dark warehouse theme, status colors (green/yellow/grey)
    └── widgets/
        ├── export_summary_dialog.dart # Pre-export audit card, blocks empty sessions
        ├── grouping_tree_view.dart    # Accordion tree with status badges and NumPad tap
        ├── tablet_header.dart         # Live timer, preset dropdown, session info, action buttons
        └── touch_numpad_dialog.dart   # On-screen numpad: +1 +5 +10, Match Due, digit grid
```

---

### Part-ID Centric Metrics
- Units, departments, and tree hierarchy nodes display progress in unique Part IDs: `X / Y parts (Z%)`.
- Individual Part ID rows/leaves display piece quantities: `qtyPicked / qtyRequired, Due: qtyDue`.
- Work Order level in the tree displays piece quantities for that specific WO.

### Earliest Incomplete Pick Date & Urgency Glow (Unit Highlighting)
- On each unit card, the app identifies and displays the earliest incomplete pick date across active departments.
- **Missing Parts Excluded**: Parts flagged as `MISSING` in `part_flags` do not block a department or unit from being considered complete.
- **Urgency Glow**:
  - **RED Glow** (`#FF3B30`): Past due date (`< 0 days` remaining).
  - **YELLOW Glow** (`#FFB300`): Due in 2 days or less (`0..2 days` remaining).
  - **GREEN Glow** (`#00E676`): Due in more than 2 days (`> 2 days` remaining).
  - **Completed Badge** (Green): All parts picked or flagged missing.
- **Dynamic Recalculation**: Once the burning department is closed or fully picked, the unit's earliest pick date automatically recalculates to the next earliest incomplete department.

### Auto-Export on Session Close & Status Workflow
- Closing a picking session immediately exports the updated picklist to Excel.
- If no export folder is configured, prompts the user to select the export destination folder on first run and persists it in `admin_config`.
- Status lifecycle: `OPEN` → `CLOSED` → `EXPORTED` → `ISSUED` (with distinct status colors).
- Re-export button remains accessible in `SessionExportScreen` for any closed or exported session.

### Monotonic Session Sequencing (1..9999)
- Session numbers strictly increase from 1 up to 9999 and wrap to 1.
- The high-water mark sequence number is persisted in `admin_config` (`last_seq_no_$unitId`). Deleting previous or empty sessions never decrements or reuses sequence numbers.

### Pick Mode Split Screen & Anti-Clear Delta Picking (pick_mode_screen.dart)
- Upper screen: Large Part ID, Description, ON_HAND location/stock info, metadata chips, status badge (red if missing), and stats (Picked, Due, Required).
- Lower screen: Integrated touch console with numeric keypad (0-9, `.`, Backspace, Clear), delta input display, Confirm Pick (+X), Match Due (+N), Return Picked, Missing Part, and nav buttons.
- **Delta Picking**: Keypad inputs the delta to add to SQLite.
- **Anti-Clear Protection**: Clear button resets only the pending keypad input buffer; once saved in SQLite, quantities cannot be zeroed out by typing.
- **Returns**: Strictly performed via the "Return Picked" dialog requiring worker name and a minimum 10-character reason, logged in `pick_returns`.
- **Decimal Support**: Quantities are stored as `double` to support measurement units (m, ft, kg, etc.).
- **Missing Part**: Recorded in SQLite `part_flags` table; displayed in red badge. If the part is subsequently fully picked (`qtyPicked >= qtyRequired`), the `MISSING` flag is automatically cleared from `part_flags` and the red badge is removed.
- **Strict Group Isolation**: Each 3rd-level group (Department, Resource ID, or Line) is completely solid and isolated during linear picking. Next, Previous, and auto-advance never cross boundaries to other Resource IDs, Lines, or Departments.
- **15-Minute Admin Session Window**: Any action in the Admin panel requires admin PIN authorization within the last 15 minutes. Inactivity beyond 15 minutes or any screen interaction after expiry immediately terminates the admin session and returns the user to HomeScreen.
- **Standard Pickers (Admin-Managed)**: Worker names can only be added or removed by admins in AdminScreen Tab 1. In Step 1 of the picker flow, manual worker name typing is disabled to prevent duplicate/typo profiles.

### Departments vs Component Resource IDs & Auto-Issue Rules
- **Departments (Assembly Destinations)**: Represent the destination work areas where parts are assembled. On the tablet, departments only have "Allowed for Pick" permissions (Allow / Block). Auto-issue is **NEVER** applied to departments.
- **Component Resource IDs / Component Departments (Part Sources)**: Represent where parts originate. On the tablet, component resources have:
  1. "Allowed for Pick" (Allow / Block picking on this device).
  2. "Auto-Issue 100%" (auto-marks 100% picked on export and hides from picking).
- **Dependency Rule**: If a Component Resource ID is blocked from picking on this tablet, its Auto-Issue setting is **disabled and inactive**.
- **(Empty / Unassigned) Support**: Parts with missing/blank Resource IDs are explicitly listed as `(Empty / Unassigned)` in Component Resources with both picking permission and auto-issue support.
- **During Picking**: Parts belonging to blocked or Auto-Issue Resource IDs are completely hidden from the tree view and Pick Mode, and excluded from pending pick metrics.
- **On Export**: All Auto-Issue items (including empty resource IDs if configured) are automatically written as 100% picked (`qtyPicked = qtyRequired, qtyDue = 0`) in the exported Excel workbook and ERP columns.

### Tree Hierarchy Specification (Grouping Presets)
The complete hierarchy evaluated by the Grouping Engine:
```
Unit (file)
  └── Unit column value (subUnit)
        └── Type (MAIN LINE / SUBASSEMBLY)
              └── Department
                    └── Resource ID (if MAIN LINE)
                          └── Line (optional, controlled by toggle)
                                └── Grouped by count of unique Part IDs
```

### Optional Line Grouping
- Admin can toggle Line grouping on/off.
- When enabled: MAIN LINE (`Resource ID → Line → Part ID`), SUBASSEMBLY (`Department → Line → Part ID`).
- When disabled: MAIN LINE (`Resource ID → Part ID`), SUBASSEMBLY (`Department → Part ID`).

### Export Destination Folder
- Admin/Picker can select any export destination folder via directory picker.
- The selected folder is persisted in `admin_config` (`last_export_dir`). Defaults to the source picklist folder if unconfigured.

### 30-Day Session Retention after Unit Deletion
- When a unit is deleted (by admin or auto-pruned at the 40-unit capacity limit), the unit is soft-deleted (`deleted_at = now`).
- The unit and its picklist items are hidden from picker screens, but its picking sessions remain retained in SQLite for 30 days.
- Retained sessions remain visible and exportable in `SessionExportScreen`.
- On application launch, `DatabaseService.purgeExpiredDeletedUnits(retentionDays: 30)` permanently purges units soft-deleted more than 30 days ago along with their sessions and items.
- Soft-deleted units do not count towards the 40-unit device storage limit.

### Super Admin Protected System Logging (49 MB Max & CSV Export)
- App-wide logging (`LogService`) records events, warnings, errors, and unhandled Flutter/platform crashes.
- Storage cap: strictly **49 MB** maximum. Oldest logs automatically pruned (circular FIFO buffer) when approaching the cap.
- Protected by a dedicated **Super Admin PIN** (default `7777`, configurable in Admin panel).
- System Logs UI in AdminScreen (Tab 7):
  - Live log count and storage utilization bar (`X / 49.00 MB`).
  - Search filter by tag, message, or stack trace; level filters (`ALL`, `CRASH`, `ERROR`, `WARN`, `INFO`).
  - Stack trace inspector dialog for field debugging.
  - **Export to CSV**: Formats all logs to an RFC 4180 compliant CSV file saved to the chosen export folder.

---

## App Navigation Flow

```
main.dart
  └── HomeScreen (launch root — role selector)
       ├── [Admin button] ─────────────────────────────────────────────────────────┐
       │      → AdminScreen (PIN gate: default 1234)                               │
       │            ├── Tab 1: General Settings (Tablet ID, auto-advance, line group)  │
       │            ├── Tab 2: Department Filter (Allow / Block picking per dept)     │
       │            ├── Tab 3: Component Resources (Allow / Block + Auto-Issue 100%)  │
       │            ├── Tab 4: Column Mapper (add/view header aliases)             │
       │            ├── Tab 5: Grouping Presets (view built-in presets)            │
       │            ├── Tab 6: Storage Manager (view / soft-delete units)          │
       │            └── Tab 7: System Logs (Super Admin PIN 7777: view, CSV export, delete >30d) │
       ├── [Export Sessions button] ───────────────────────────────────────────────┤
       │      → SessionExportScreen (Global hub for closed/finished sessions)      │
       │            └── Overwrites/creates new file as {TabletID}_{SessionID}_{Unit}.xlsx
        └── [Picker button] ────────────────────────────────────────────────────────┘
              → PickerFlowScreen (3-step guided onboarding)
                    ├── Step 1: Enter Worker Name (chips for standard pickers + live active picker indicator)
                    ├── Step 2: Select Unit from DB list  ─OR─ import new Excel file
                    │          (shows progress bar + status per unit)
                    └── Step 3: Select Department (only is_active=1 shown; locked ones listed grey)
                           → Creates SessionMetadata in SQLite
                           → Navigates to PickingScreen (pushReplacement)
                                 ├── Dept badge strip (shows active dept name, Pick Date, Prod Date)
                                 ├── TabletHeader (Mode Toggle: Accordion / Pick Mode)
                                 ├── Mode: GroupingTreeView (Accordion)
                                 └── Mode: DepartmentPartsView → PickModeScreen (Linear)
```

---

## Data Flow

```
Excel File (.xlsx)
      │
      ▼
ExcelService.parseExcelFile()
  - ColumnMapper identifies columns
  - Rows → List<PicklistItem>
      │
      ▼
StorageManager.enforceCapacityLimit()  ← auto-prune if ≥ 40 units
      │
      ▼
DatabaseService.insertUnit()
DatabaseService.savePicklistItems()
DatabaseService.saveDepartments()
      │
      ▼
PickerFlowScreen → selects unit + department
      │
      ▼
PickingScreen (accordion tree, FIFO, quick buttons)
      │
      ▼
DatabaseService.batchUpdateItems()  ← on every pick (instant WAL commit)
      │
      ▼
ExcelService.exportAndOverwrite()   ← on session finish
  - Backup: [FileName]_backup.xlsx
  - Overwrites original with Qty Picked, Qty Due + ERP audit columns
```

---

## Coding Rules

- **Language:** Dart/Flutter strictly. All comments and UI strings in English.
- **State Management:** Manual setState + dependency injection (no Provider/Riverpod for now).
  Services are instantiated in `main.dart` and passed down via constructors.
- **DB Access:** Always go through `DatabaseService` — never access SQLite directly from UI.
- **FIFO:** Only modify `FifoAllocationEngine` for allocation changes.
  Never embed allocation logic in widget callbacks.
- **Models:** All models have `toMap()`, `fromMap()`, and `copyWith()` — use them.
- **Don't break:** `DatabaseService._onCreate()` schema — add new columns via migration only.
- **File naming:** snake_case. Widget files must match their class name.
- **Excel writes:** Always create backup before overwriting. Never skip the backup step.

---

## When to Update This File

Update `AGENTS.md` whenever:
- A new screen, service, engine, or model is added.
- A new business rule or constraint is introduced.
- The data flow changes (e.g. new export format, new DB table).
- A column alias or naming convention is modified.

---

## How to Use (for AI Agents)

At the start of a new session, read AGENTS.md and CONTEXT.md before making changes:
> "Read AGENTS.md and CONTEXT.md and keep the architecture in mind."

Before adding a feature, check:
1. Does a method already exist in `DatabaseService` for this DB operation?
2. Does `ColumnMapper` already handle the new column variant?
3. Does the change touch the FIFO engine? If yes, run `dart run test/run_tests.dart` after.
4. Is the 40-unit limit enforced before any `insertUnit()` call?
