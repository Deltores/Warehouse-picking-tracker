# 📦 Picklist Tracker (Android Tablet — Flutter)

[![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white)](https://dart.dev)
[![SQLite](https://img.shields.io/badge/SQLite-003B57?style=for-the-badge&logo=sqlite&logoColor=white)](https://sqlite.org)
[![Android](https://img.shields.io/badge/Platform-Android%20Tablet-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://developer.android.com)
[![Architecture](https://img.shields.io/badge/Architecture-Offline--First%20WAL-FF6F00?style=for-the-badge)](#system-architecture)

An industrial-grade, offline-first Android tablet application engineered for manufacturing facilities and warehouse logistics. **Picklist Tracker** streamlines component picking operations directly from Excel (`.xlsx`) picklists, performs automated department-scoped FIFO (First-In, First-Out) work order allocations, provides rigorous session and return tracking, and exports audit-ready, ERP-compliant spreadsheets.

---

## 📑 Table of Contents

- [Core Purpose & Design Philosophy](#-core-purpose--design-philosophy)
- [Key Features](#-key-features)
  - [1. 3-Step Guided Picker Onboarding Flow](#1-3-step-guided-picker-onboarding-flow)
  - [2. Dual Picking Modes: Accordion Tree & Linear Pick Mode](#2-dual-picking-modes-accordion-tree--linear-pick-mode)
  - [3. Anti-Clear Delta Console & LIFO Returns](#3-anti-clear-delta-console--lifo-returns)
  - [4. Department-Scoped FIFO Work Order Cascade](#4-department-scoped-fifo-work-order-cascade)
  - [5. Earliest Pick Date & Dynamic Urgency Glow](#5-earliest-pick-date--dynamic-urgency-glow)
  - [6. Component Resources vs. Departments (Auto-Issue Rules)](#6-component-resources-vs-departments-auto-issue-rules)
  - [7. 3-Tab Session Export Hub & Lifecycle Progression](#7-3-tab-session-export-hub--lifecycle-progression)
  - [8. 40-Unit Memory Buffer & 30-Day Soft-Delete Retention](#8-40-unit-memory-buffer--30-day-soft-delete-retention)
  - [9. Admin Security, 15-Minute Timeout & Super Admin Logs](#9-admin-security-15-minute-timeout--super-admin-logs)
- [System Architecture & Data Flow](#-system-architecture--data-flow)
- [Project Directory Map](#-project-directory-map)
- [Getting Started](#-getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation & Setup](#installation--setup)
  - [Running Unit & Integration Tests](#running-unit--integration-tests)
  - [Building Release APK](#building-release-apk)
- [Database Schema Highlights](#-database-schema-highlights)
- [Legal Disclaimer & Liability Waiver](#-legal-disclaimer--liability-waiver)

---

## 🎯 Core Purpose & Design Philosophy

Manufacturing picking operations often suffer from paper clutter, transcription errors, inventory latency, and stock discrepancies. Picklist Tracker was engineered from the ground up for warehouse floor reliability:

- **100% Offline Resilience**: Zero dependence on remote servers, APIs, or uninterrupted Wi-Fi. All state transitions, picks, and returns commit instantly to an on-device SQLite database operating in Write-Ahead Logging (`WAL`) mode.
- **Strict Scope Isolation**: Prevents human errors during picking. Work orders and parts are strictly contained within their active department, resource ID, or line boundary.
- **Anti-Clear Data Integrity**: Numeric keypads input additive deltas. Once saved to the database, quantities cannot be cleared or zeroed out accidentally by typing.
- **Ergonomic Tablet UI**: Designed specifically for portrait tablet usage with high-contrast, industrial warehouse aesthetics (OLED dark theme), large touch targets, and clear visual indicators.

---

## 🚀 Key Features

### 1. 3-Step Guided Picker Onboarding Flow
Workers start each picking shift via an intuitive 3-step setup:
1. **Worker Selection**: Pickers tap their profile chip from an Admin-approved standard pickers roster. Manual text entry is locked out to eliminate duplicate or misspelled worker accounts.
2. **Unit Selection**: Choose an existing manufacturing unit from local memory (with live progress indicators and urgency dates) or import a new `.xlsx` picklist via file picker.
3. **Department Selection**: Select the designated destination department. Incomplete departments with the earliest due date are highlighted with an urgency glow to ensure timely part delivery.

### 2. Dual Picking Modes: Accordion Tree & Linear Pick Mode
- **Accordion Tree Mode (`GroupingTreeView`)**:
  - Full structural view displaying the complete assembly hierarchy:
    ```
    Unit (File) ➔ SubUnit ➔ Type (MAIN LINE / SUBASSEMBLY) ➔ Department ➔ Resource ID ➔ Line ➔ Part ID
    ```
  - Displays Part-ID centric metrics (`X / Y parts (Z%)`) at group levels and individual piece counts (`qtyPicked / qtyRequired, Due: qtyDue`) on leaf rows.
  - Direct Quick-Pick triggers (`+1`, `+5`, `+10`, `Match Due`).
- **Linear Pick Mode (`PickModeScreen`)**:
  - Full-screen split view focusing on a single part at a time.
  - Upper console: Part ID, Description, ON_HAND bin/stock location, work order breakdown, metadata chips, and urgency badge.
  - Lower console: Touchpad numeric keypad, confirm pick, match due, return dialog, and navigation.
  - **Strict Group Isolation**: When entering Pick Mode on a Resource ID, Line, or Department, picking is strictly contained to that group. Navigation buttons (`Next`, `Prev`) and auto-advance never cross into other groups.

### 3. Anti-Clear Delta Console & LIFO Returns
- **Additive Delta Picking**: The keypad types the delta quantity to add to the existing pick count, preventing accidental replacement of previous progress.
- **Anti-Clear Keypad**: The `C` (Clear) button resets only the pending keypad input buffer; committed database values cannot be wiped out by typing.
- **Audited LIFO Returns**: Picking returns cannot be executed through the keypad. They require opening the dedicated "Return Picked" dialog, verifying worker identity, entering a minimum 10-character justification note, and are allocated via LIFO (Last-In, First-Out) across Work Orders. Every return is logged in the `pick_returns` audit table.
- **Missing Parts Tracking**: Flagging a part as `MISSING` records an incident in `part_flags` with a bright red status badge. If the missing part is subsequently located and fully picked, the missing flag is automatically cleared.

### 4. Department-Scoped FIFO Work Order Cascade
When picking by Part ID, parts frequently span multiple Work Orders with varying requirements:
- `FifoAllocationEngine` sorts work orders by their original Excel `rowOrder` and distributes entered quantities chronologically across WOs.
- **Department Boundary Enforcement**: Parts sharing the same Part ID in other departments are completely unaffected.

### 5. Earliest Pick Date & Dynamic Urgency Glow
Units and departments dynamically evaluate incomplete pick dates across active departments:
- 🔴 **Past Due (`< 0 days`)**: Vibrant Red Glow (`#FF3B30`).
- 🟡 **Due Soon (`0..2 days`)**: Amber Yellow Glow (`#FFB300`).
- 🔵 **Normal (`> 2 days`)**: Blue Accent.
- 🟢 **Complete**: Bright Green Badge once all parts are picked or flagged as missing.
- **Dynamic Recalculation**: Once the most urgent department is finished, the card automatically recalculates urgency for the next incomplete department.

### 6. Component Resources vs. Departments (Auto-Issue Rules)
- **Departments (Assembly Destinations)**: Only have picking permissions (`Allow` / `Block` picking on the tablet). Auto-issue is never applied to departments.
- **Component Resource IDs (Part Origins)**: Represent the source shop floor or supplier. Supports:
  1. `Allowed for Pick` (Allow / Block on device).
  2. `Auto-Issue 100%` (Automatically marks parts 100% picked on export and hides them from the picking floor).
- **Dependency Invariant**: If a Component Resource ID is blocked, its Auto-Issue setting is automatically deactivated.
- **Blank / Unassigned Support**: Parts with missing Resource IDs are categorized as `(Empty / Unassigned)` with independent permission and auto-issue support.

### 7. 3-Tab Session Export Hub & Lifecycle Progression
The dedicated `SessionExportScreen` provides a central logistics hub sorted in **LIFO order** (newest sessions first) across 3 lifecycle stages:
1. **Closed**: Sessions concluded by workers, queued for spreadsheet export.
2. **Exported**: Picklists written to `.xlsx` with audit timestamps, picker names, and ERP columns.
3. **Issued**: Confirmed as issued into the company ERP system (protected by Admin PIN verification).

Each session card clearly displays:
- Unit Name & Department
- Monotonic Session Sequence `#`
- Picker Name
- **Start Time** and **End Time**
- Total items and parts picked
- Export destination & action buttons (Export, Re-Export, Mark as Issued)

### 8. 40-Unit Memory Buffer & 30-Day Soft-Delete Retention
- Local SQLite storage maintains an active capacity limit of **40 units**.
- Importing unit #41 triggers the `StorageManager` to automatically prune the oldest completed unit.
- **30-Day Session Retention**: Deleted units are soft-deleted (`deleted_at = timestamp`). While hidden from picker views, their session history and export files remain retained for 30 days in the Export Hub before permanent purging.

### 9. Admin Security, 15-Minute Timeout & Super Admin Logs
- **15-Minute Admin Authorization Window**: Entering the Admin Panel requires the Admin PIN (default `1234`). Any subsequent admin operation is guarded by a 15-minute activity window. If 15 minutes elapse without re-authentication or when interacting with an expired session, the app immediately revokes credentials and redirects to `HomeScreen`.
- **Admin-Managed Pickers**: Standard picker accounts can only be created or removed by admins in Settings.
- **Super Admin Audit Logging (`LogService`)**:
  - Gated by a dedicated Super Admin PIN (default `9999`).
  - Strict **49.00 MB** circular storage cap (oldest logs auto-pruned to prevent disk overflow).
  - Searchable by log level (`ALL`, `CRASH`, `ERROR`, `WARN`, `INFO`), tag, or message.
  - Interactive stack trace inspector.
  - **RFC 4180 CSV Export**: Formats all system logs into a standard CSV file saved to the export directory.

---

## 🏗 System Architecture & Data Flow

```mermaid
flowchart TD
    A[Excel Picklist .xlsx] -->|ColumnMapper & Parse| B[ExcelService]
    B -->|Capacity Check max 40| C[StorageManager]
    C -->|Save Unit & Items| D[(SQLite Database - WAL Mode)]
    
    D --> E[PickerFlowScreen]
    E -->|Worker + Unit + Dept| F[PickingScreen]
    
    F -->|Accordion Tree Mode| G[GroupingTreeView]
    F -->|Linear Isolated Mode| H[PickModeScreen]
    
    G & H -->|Additive Delta / Returns| I[FifoAllocationEngine]
    I -->|Batch Update Transaction| D
    
    F -->|Close & Export| J[ExcelService]
    J -->|Write Backup .xlsx| K[Safety Backup]
    J -->|Write Audit Columns| L[Exported Picklist .xlsx]
    L --> M[SessionExportScreen]
    M -->|Admin PIN Gate| N[ERP Mark as Issued]
```

---

## 📂 Project Directory Map

```
lib/
├── main.dart                          # App initialization, orientation lock & service injection
├── engine/
│   ├── column_mapper.dart             # Dynamic Excel header aliasing & normalizer
│   ├── fifo_allocation_engine.dart    # Department-scoped FIFO cascade distribution
│   └── grouping_engine.dart          # Accordion tree builder & metric aggregations
├── models/
│   ├── grouping_preset.dart           # Tree hierarchy definitions & GroupLevel enum
│   ├── part_summary.dart              # Unique Part ID aggregation model
│   ├── picklist_item.dart             # Core picklist item & piece quantities
│   ├── session_metadata.dart          # Worker picking session & audit model
│   ├── unit_pick_date_urgency.dart    # Multi-format date parser & urgency glow evaluator
│   └── unit_record.dart              # Unit storage container & soft-delete properties
├── services/
│   ├── database_service.dart          # SQLite WAL operations, schema migrations & CRUD
│   ├── excel_service.dart             # Fast Excel reader, in-place exporter & backup generator
│   ├── log_service.dart              # 49 MB circular logger & RFC 4180 CSV exporter
│   └── storage_manager.dart          # 40-unit capacity enforcement & FIFO pruning
└── ui/
    ├── screens/
    │   ├── home_screen.dart           # Application entry point, role gate & legal disclaimer
    │   ├── picker_flow_screen.dart    # 3-step picker onboarding flow (Worker ➔ Unit ➔ Dept)
    │   ├── picking_screen.dart        # Main picking dashboard & view orchestrator
    │   ├── pick_mode_screen.dart      # Full-screen isolated linear FIFO picking console
    │   ├── session_export_screen.dart # 3-tab session export hub (Closed / Exported / Issued)
    │   ├── admin_screen.dart          # PIN-gated 7-tab admin panel & device settings
    │   └── crash_recovery_screen.dart # Graceful error recovery screen with auto-retry
    ├── theme/
    │   └── app_theme.dart            # Warehouse dark theme, status colors & typography
    └── widgets/
        ├── export_summary_dialog.dart # Pre-export audit check & anti-empty safeguard
        ├── grouping_tree_view.dart    # Accordion tree widget with badge indicators
        └── tablet_header.dart         # Live shift timer, unit metadata & export triggers
```

---

## 🛠 Getting Started

### Prerequisites
- **Flutter SDK**: `>= 3.24.0`
- **Dart SDK**: `>= 3.0.0 < 4.0.0`
- **Android SDK**: API Level 26+ (Android 8.0 Oreo or higher recommended)
- **Target Device**: Android tablet (e.g., Samsung Galaxy Tab, Google Pixel Tablet, or Android Tablet Emulator)

### Installation & Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-org/picklist-tracker.git
   cd picklist-tracker
   ```

2. **Install Flutter dependencies**:
   ```bash
   flutter pub get
   ```

3. **Verify Flutter environment**:
   ```bash
   flutter doctor
   ```

4. **Launch on connected tablet or emulator**:
   ```bash
   flutter run
   ```

---

## 🧪 Running Unit & Integration Tests

The project includes an extensive test suite covering FIFO allocation accuracy, column aliasing, hierarchy projection, date urgency evaluation, monotonic sequencing, and CSV formatting:

```bash
# Run all project test suites
flutter test

# Run the comprehensive standalone verification runner
flutter test test/run_tests.dart
```

### Key Verification Cases Passed:
- ✅ **FIFO Work Order Cascade**: Accurate distribution of piece quantities across work orders.
- ✅ **Strict Department Isolation**: Verification that identical Part IDs in other departments are untouched.
- ✅ **Dynamic Column Mapper**: Robust parsing of varied Excel headers (e.g., `Part #`, `Component`, `Due Qty`).
- ✅ **Grouping Engine**: Hierarchy projection for both `MAIN LINE` and `SUBASSEMBLY` workflows.
- ✅ **Monotonic Sequencing**: Sequential session numbering (`1..9999`) with high-water mark retention.
- ✅ **Log Export RFC 4180 Compliance**: Accurate escaping of delimiters, newlines, and quotes in CSV output.

---

## 📦 Building Release APK

To generate an optimized, signed release APK ready for sideloading or MDM deployment onto warehouse tablets:

```bash
flutter build apk --release
```

The output file will be generated at:
```
build/app/outputs/flutter-apk/app-release.apk
```

> **Note on JNI Engine Logs**: When running in `--release` mode, Flutter automatically strips verbose Android `FlutterJNI` viewport metric logs, ensuring maximum runtime efficiency and minimal battery consumption.

---

## 🗄 Database Schema Highlights

The local SQLite database (`picklist_tracker.db`) uses Write-Ahead Logging (`PRAGMA journal_mode=WAL;`) with the following primary tables:

| Table Name | Description |
|---|---|
| `units` | Stored picklist containers, file metadata, completion metrics, and `deleted_at` timestamp. |
| `picklist_items` | Individual rows containing department, line, WO, part ID, required, picked, and due quantities. |
| `sessions` | Worker shift sessions with unique sequential IDs, start/end timestamps, and export statuses. |
| `pick_returns` | Complete audit trail of returned parts, worker IDs, timestamps, and required return reasons. |
| `part_flags` | Tracking for parts flagged as `MISSING` with automated resolution upon completion. |
| `admin_config` | Key-value store for Tablet ID, active export directory, high-water sequence marks, and security PINs. |
| `system_logs` | Circular buffer storing diagnostic logs, errors, and uncaught exceptions up to 49 MB. |

---

## ⚖️ Legal Disclaimer & Liability Waiver

```
========================================================================================
IMPORTANT LEGAL NOTICE & OPERATIONAL DISCLAIMER
========================================================================================
This software application is provided on an strictly "AS-IS" and "AS-AVAILABLE" basis 
for operational workflow assistance and picking organization only. 

The software developers, maintainers, and contributors make no representations or 
warranties of any kind, express or implied, regarding physical count accuracy, 
tolerance thresholds, or synchronization with third-party ERP systems.

The operating facility and system operators assume sole and absolute responsibility for:
1. Validating physical inventory counts against warehouse stocks.
2. Confirming that exported picklists comply with production and ERP tolerances.
3. Reviewing return logs and part flags prior to final assembly.

Under no circumstances shall the developers or contributors be held liable for any 
inventory discrepancies, physical shortages, production delays, operational downtime, 
or consequential damages arising out of the use of this application.
========================================================================================
```
