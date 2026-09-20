import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../engine/column_mapper.dart';
import '../models/picklist_item.dart';
import '../models/session_metadata.dart';
import '../models/unit_pick_date_urgency.dart';
import '../models/unit_record.dart';
import 'log_service.dart';

class DatabaseService implements LogDatabase {
  static Database? _database;
  static DatabaseFactory? _ffiFactory;

  /// Allows injecting a mock or in-memory Database for tests.
  static void setDatabaseForTesting(Database? db) {
    _database = db;
  }

  /// Initializes database factory for desktop/test platforms if needed
  static void initializeFfi() {
    if (kIsWeb) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      _ffiFactory = databaseFactoryFfi;
    }
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    initializeFfi();

    String dbPath;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final appSupportDir = await getApplicationSupportDirectory();
      dbPath = p.join(appSupportDir.path, 'picklist_tracker.db');
    } else {
      final defaultDatabasesPath = await getDatabasesPath();
      dbPath = p.join(defaultDatabasesPath, 'picklist_tracker.db');
    }

    final factory = _ffiFactory ?? databaseFactory;

    return await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 13,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onOpen: (db) async {
          // Enable WAL (Write-Ahead Logging) for zero-loss crash protection & speed
          await db.rawQuery('PRAGMA journal_mode=WAL;');
          await db.execute('PRAGMA foreign_keys=ON;');
        },
      ),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE units (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        total_required INTEGER NOT NULL DEFAULT 0,
        total_picked INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'IN_PROGRESS',
        created_at INTEGER NOT NULL,
        completed_at INTEGER,
        last_accessed_at INTEGER NOT NULL,
        deleted_at INTEGER,
        original_headers TEXT NOT NULL DEFAULT '[]'
      );
    ''');

    await db.execute('''
      CREATE TABLE departments (
        id TEXT PRIMARY KEY,
        unit_id TEXT NOT NULL,
        name TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY(unit_id) REFERENCES units(id) ON DELETE CASCADE
      );
    ''');

    await db.execute('''
      CREATE TABLE picklist_items (
        id TEXT PRIMARY KEY,
        unit_id TEXT NOT NULL,
        department TEXT NOT NULL,
        line TEXT NOT NULL,
        work_order TEXT NOT NULL,
        part_id TEXT NOT NULL,
        part_description TEXT NOT NULL,
        qty_required REAL NOT NULL,
        qty_due REAL NOT NULL,
        qty_picked REAL NOT NULL DEFAULT 0,
        row_order INTEGER NOT NULL,
        pick_date TEXT NOT NULL DEFAULT '',
        prod_date TEXT NOT NULL DEFAULT '',
        sub_unit TEXT NOT NULL DEFAULT '',
        resource_id TEXT NOT NULL DEFAULT '',
        component_resource_id TEXT NOT NULL DEFAULT '',
        on_hand TEXT NOT NULL DEFAULT '',
        dept_type TEXT NOT NULL DEFAULT '',
        raw_columns TEXT NOT NULL DEFAULT '{}',
        -- Part ID replacement tracking
        replaced_part_id TEXT NOT NULL DEFAULT '',
        replacement_note TEXT NOT NULL DEFAULT '',
        replaced_at INTEGER,
        replaced_by TEXT NOT NULL DEFAULT '',
        FOREIGN KEY(unit_id) REFERENCES units(id) ON DELETE CASCADE
      );
    ''');

    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        session_seq_no INTEGER NOT NULL DEFAULT 0,
        unit_id TEXT NOT NULL,
        worker_name TEXT NOT NULL,
        tablet_id TEXT NOT NULL DEFAULT '',
        start_time INTEGER NOT NULL,
        end_time INTEGER,
        pick_date TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'ACTIVE',
        issued_status TEXT NOT NULL DEFAULT 'Pending Issue',
        total_items_picked INTEGER NOT NULL DEFAULT 0,
        batch_id TEXT NOT NULL DEFAULT '',
        issued_at INTEGER,
        FOREIGN KEY(unit_id) REFERENCES units(id) ON DELETE CASCADE
      );
    ''');

    await db.execute('''
      CREATE TABLE pick_returns (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        unit_id TEXT NOT NULL,
        worker_name TEXT NOT NULL,
        part_id TEXT NOT NULL,
        department TEXT NOT NULL,
        qty_returned REAL NOT NULL,
        comment TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE part_flags (
        id TEXT PRIMARY KEY,
        unit_id TEXT NOT NULL,
        part_id TEXT NOT NULL,
        department TEXT NOT NULL,
        flag_type TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE admin_config (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');

    // Default PIN: 1234
    await db.insert('admin_config', {
      'key': 'admin_pin',
      'value': '1234',
    });

    // Default Super Admin PIN: 9999
    await db.insert('admin_config', {
      'key': 'super_admin_pin',
      'value': '9999',
    });

    // Default standard pickers
    await db.insert('admin_config', {
      'key': 'standard_pickers',
      'value': jsonEncode(['Alex', 'John', 'Sarah', 'Mike', 'David']),
    });

    // System logs table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        level TEXT NOT NULL,
        tag TEXT NOT NULL,
        message TEXT NOT NULL,
        stack_trace TEXT NOT NULL DEFAULT ''
      );
    ''');
    await db.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_timestamp ON app_logs(timestamp);");
    await db.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_level ON app_logs(level);");

    // Session picks table for tracking parts picked in specific sessions
    await db.execute('''
      CREATE TABLE IF NOT EXISTS session_picks (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        unit_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        part_id TEXT NOT NULL,
        qty_picked REAL NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
      );
    ''');
    await db.execute("CREATE INDEX IF NOT EXISTS idx_session_picks_session ON session_picks(session_id);");
    await db.execute("CREATE INDEX IF NOT EXISTS idx_session_picks_part ON session_picks(session_id, part_id);");

    // Manual picks table — for parts entered manually in Pick Mode
    await db.execute('''
      CREATE TABLE IF NOT EXISTS manual_picks (
        id TEXT PRIMARY KEY,
        unit_id TEXT NOT NULL,
        session_id TEXT NOT NULL DEFAULT '',
        worker_name TEXT NOT NULL DEFAULT '',
        department TEXT NOT NULL DEFAULT '',
        work_order TEXT NOT NULL DEFAULT 'MANUAL',
        part_id TEXT NOT NULL,
        qty_picked REAL NOT NULL DEFAULT 0,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      );
    ''');
    await db.execute("CREATE INDEX IF NOT EXISTS idx_manual_picks_unit ON manual_picks(unit_id);");

    // Part ID replacements log — tracks old→new Part ID swaps
    await db.execute('''
      CREATE TABLE IF NOT EXISTS part_id_replacements (
        id TEXT PRIMARY KEY,
        unit_id TEXT NOT NULL,
        session_id TEXT NOT NULL DEFAULT '',
        worker_name TEXT NOT NULL DEFAULT '',
        old_part_id TEXT NOT NULL,
        new_part_id TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      );
    ''');
    await db.execute("CREATE INDEX IF NOT EXISTS idx_part_replacements_unit ON part_id_replacements(unit_id);");
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute("ALTER TABLE picklist_items ADD COLUMN pick_date TEXT NOT NULL DEFAULT '';");
      await db.execute("ALTER TABLE picklist_items ADD COLUMN prod_date TEXT NOT NULL DEFAULT '';");
    }
    if (oldVersion < 3) {
      await db.execute("ALTER TABLE picklist_items ADD COLUMN sub_unit TEXT NOT NULL DEFAULT '';");
    }
    if (oldVersion < 4) {
      await db.execute("ALTER TABLE picklist_items ADD COLUMN resource_id TEXT NOT NULL DEFAULT '';");
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pick_returns (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          unit_id TEXT NOT NULL,
          worker_name TEXT NOT NULL,
          part_id TEXT NOT NULL,
          department TEXT NOT NULL,
          qty_returned REAL NOT NULL,
          comment TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS part_flags (
          id TEXT PRIMARY KEY,
          unit_id TEXT NOT NULL,
          part_id TEXT NOT NULL,
          department TEXT NOT NULL,
          flag_type TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL
        );
      ''');
    }
    if (oldVersion < 5) {
      await db.execute("ALTER TABLE picklist_items ADD COLUMN on_hand TEXT NOT NULL DEFAULT '';");
    }
    if (oldVersion < 6) {
      // Add dept_type to picklist_items
      await db.execute("ALTER TABLE picklist_items ADD COLUMN dept_type TEXT NOT NULL DEFAULT '';");
      // Add session_seq_no and tablet_id to sessions
      await db.execute("ALTER TABLE sessions ADD COLUMN session_seq_no INTEGER NOT NULL DEFAULT 0;");
      await db.execute("ALTER TABLE sessions ADD COLUMN tablet_id TEXT NOT NULL DEFAULT '';");
    }
    if (oldVersion < 7) {
      // Add deleted_at to units for 30-day soft-delete retention
      await db.execute("ALTER TABLE units ADD COLUMN deleted_at INTEGER DEFAULT NULL;");
      // Create app_logs table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp INTEGER NOT NULL,
          level TEXT NOT NULL,
          tag TEXT NOT NULL,
          message TEXT NOT NULL,
          stack_trace TEXT NOT NULL DEFAULT ''
        );
      ''');
      await db.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_timestamp ON app_logs(timestamp);");
      await db.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_level ON app_logs(level);");
    }
    if (oldVersion < 8) {
      await db.execute("UPDATE admin_config SET value = '9999' WHERE key = 'super_admin_pin' AND value = '7777';");
    }
    if (oldVersion < 9) {
      await db.execute("ALTER TABLE sessions ADD COLUMN batch_id TEXT NOT NULL DEFAULT '';");
    }
    if (oldVersion < 10) {
      await db.execute("ALTER TABLE sessions ADD COLUMN issued_at INTEGER;");
    }
    if (oldVersion < 11) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS session_picks (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          unit_id TEXT NOT NULL,
          item_id TEXT NOT NULL,
          part_id TEXT NOT NULL,
          qty_picked REAL NOT NULL,
          created_at INTEGER NOT NULL,
          FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        );
      ''');
      await db.execute("CREATE INDEX IF NOT EXISTS idx_session_picks_session ON session_picks(session_id);");
      await db.execute("CREATE INDEX IF NOT EXISTS idx_session_picks_part ON session_picks(session_id, part_id);");
    }
    if (oldVersion < 12) {
      await db.execute("ALTER TABLE units ADD COLUMN original_headers TEXT NOT NULL DEFAULT '[]';");
      await db.execute("ALTER TABLE picklist_items ADD COLUMN component_resource_id TEXT NOT NULL DEFAULT '';");
      await db.execute("ALTER TABLE picklist_items ADD COLUMN raw_columns TEXT NOT NULL DEFAULT '{}';");
    }
    if (oldVersion < 13) {
      // Part ID replacement tracking columns on picklist_items
      await db.execute("ALTER TABLE picklist_items ADD COLUMN replaced_part_id TEXT NOT NULL DEFAULT '';");
      await db.execute("ALTER TABLE picklist_items ADD COLUMN replacement_note TEXT NOT NULL DEFAULT '';");
      await db.execute("ALTER TABLE picklist_items ADD COLUMN replaced_at INTEGER;");
      await db.execute("ALTER TABLE picklist_items ADD COLUMN replaced_by TEXT NOT NULL DEFAULT '';");
      // Manual picks table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS manual_picks (
          id TEXT PRIMARY KEY,
          unit_id TEXT NOT NULL,
          session_id TEXT NOT NULL DEFAULT '',
          worker_name TEXT NOT NULL DEFAULT '',
          department TEXT NOT NULL DEFAULT '',
          work_order TEXT NOT NULL DEFAULT 'MANUAL',
          part_id TEXT NOT NULL,
          qty_picked REAL NOT NULL DEFAULT 0,
          note TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL
        );
      ''');
      await db.execute("CREATE INDEX IF NOT EXISTS idx_manual_picks_unit ON manual_picks(unit_id);");
      // Part ID replacements log
      await db.execute('''
        CREATE TABLE IF NOT EXISTS part_id_replacements (
          id TEXT PRIMARY KEY,
          unit_id TEXT NOT NULL,
          session_id TEXT NOT NULL DEFAULT '',
          worker_name TEXT NOT NULL DEFAULT '',
          old_part_id TEXT NOT NULL,
          new_part_id TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL
        );
      ''');
      await db.execute("CREATE INDEX IF NOT EXISTS idx_part_replacements_unit ON part_id_replacements(unit_id);");
    }
  }

  // --- UNIT OPERATIONS ---

  Future<void> insertUnit(UnitRecord unit) async {
    final db = await database;
    final cleanUnit = unit.copyWith(clearDeletedAt: true);
    await db.insert('units', cleanUnit.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateUnit(UnitRecord unit) async {
    final db = await database;
    await db.update(
      'units',
      unit.toMap(),
      where: 'id = ?',
      whereArgs: [unit.id],
    );
  }

  Future<UnitRecord?> getUnit(String unitId) async {
    final db = await database;
    final maps = await db.query(
      'units',
      where: 'id = ?',
      whereArgs: [unitId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UnitRecord.fromMap(maps.first);
  }

  Future<List<UnitRecord>> getAllUnits({bool includeDeleted = false}) async {
    final db = await database;
    final maps = await db.query(
      'units',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'created_at ASC, id ASC',
    );
    return maps.map((m) => UnitRecord.fromMap(m)).toList();
  }

  /// Soft-deletes a unit by setting its deleted_at timestamp.
  /// Sessions and picklist items are retained for 30 days.
  Future<void> deleteUnit(String unitId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'units',
      {'deleted_at': now},
      where: 'id = ?',
      whereArgs: [unitId],
    );
  }

  /// Checks whether there is previous picking history or a soft-deleted record for this unit name / file name.
  /// Used during Excel import to detect accidental unit deletion and restore historical picks.
  Future<Map<String, dynamic>> findUnitHistory(String unitId, {String filePath = ''}) async {
    final db = await database;
    final fileBase = filePath.isNotEmpty ? p.basenameWithoutExtension(filePath) : unitId;

    // Check if unit exists in 'units' table (active or soft-deleted)
    final unitMaps = await db.query(
      'units',
      where: 'LOWER(id) = ? OR LOWER(name) = ? OR LOWER(id) = ? OR LOWER(name) = ?',
      whereArgs: [unitId.toLowerCase(), unitId.toLowerCase(), fileBase.toLowerCase(), fileBase.toLowerCase()],
      limit: 1,
    );

    UnitRecord? existingUnit;
    String matchedUnitId = unitId;
    if (unitMaps.isNotEmpty) {
      existingUnit = UnitRecord.fromMap(unitMaps.first);
      matchedUnitId = existingUnit.id;
    }

    // Query historical sessions for this unitId
    final sessionMaps = await db.query(
      'sessions',
      where: 'LOWER(unit_id) = ? OR LOWER(unit_id) = ?',
      whereArgs: [unitId.toLowerCase(), matchedUnitId.toLowerCase()],
      orderBy: 'start_time DESC',
    );
    final sessions = sessionMaps.map((m) => SessionMetadata.fromMap(m)).toList();

    // Query distinct picked parts and total quantity from session_picks
    final pickRows = await db.rawQuery('''
      SELECT COUNT(DISTINCT part_id) as distinct_parts,
             COALESCE(SUM(qty_picked), 0.0) as total_qty
      FROM session_picks
      WHERE LOWER(unit_id) = ? OR LOWER(unit_id) = ?
    ''', [unitId.toLowerCase(), matchedUnitId.toLowerCase()]);

    int distinctPickedParts = 0;
    double totalPickedQty = 0.0;
    if (pickRows.isNotEmpty) {
      distinctPickedParts = (pickRows.first['distinct_parts'] as num?)?.toInt() ?? 0;
      totalPickedQty = (pickRows.first['total_qty'] as num?)?.toDouble() ?? 0.0;
    }

    // Also check picklist_items table if any items still remain in DB
    final itemRows = await db.rawQuery('''
      SELECT COUNT(DISTINCT part_id) as distinct_parts,
             COALESCE(SUM(qty_picked), 0.0) as total_qty
      FROM picklist_items
      WHERE (LOWER(unit_id) = ? OR LOWER(unit_id) = ?) AND qty_picked > 0
    ''', [unitId.toLowerCase(), matchedUnitId.toLowerCase()]);
    if (itemRows.isNotEmpty) {
      final itemParts = (itemRows.first['distinct_parts'] as num?)?.toInt() ?? 0;
      final itemQty = (itemRows.first['total_qty'] as num?)?.toDouble() ?? 0.0;
      if (itemParts > distinctPickedParts) distinctPickedParts = itemParts;
      if (itemQty > totalPickedQty) totalPickedQty = itemQty;
    }

    final workers = sessions.map((s) => s.workerName.trim()).where((w) => w.isNotEmpty).toSet().toList();
    final isDeleted = existingUnit != null && existingUnit.deletedAt != null;
    final hasHistory = sessions.isNotEmpty || distinctPickedParts > 0 || isDeleted;

    return {
      'hasHistory': hasHistory,
      'isDeleted': isDeleted,
      'matchedUnitId': matchedUnitId,
      'unit': existingUnit,
      'sessions': sessions,
      'distinctPickedParts': distinctPickedParts,
      'totalPickedQty': totalPickedQty,
      'workers': workers,
    };
  }

  /// Restores past picking progress onto freshly parsed picklist items when re-importing a previously deleted unit.
  /// Restores picked quantities from SQLite `session_picks` and previous item records,
  /// clears deleted_at, updates unit status, and reconnects the unit to its historical sessions.
  Future<UnitRecord> restoreUnitWithPicks({
    required UnitRecord unit,
    required List<PicklistItem> parsedItems,
    required List<String> departments,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final unitId = unit.id;

    return await db.transaction((txn) async {
      // 1. Collect historical picks by part_id from session_picks
      final sessionPickRows = await txn.rawQuery('''
        SELECT part_id, COALESCE(SUM(qty_picked), 0.0) as sum_picked
        FROM session_picks
        WHERE LOWER(unit_id) = ?
        GROUP BY part_id
      ''', [unitId.toLowerCase()]);

      final historicalPartPicks = <String, double>{};
      for (final r in sessionPickRows) {
        final pid = r['part_id']?.toString() ?? '';
        final qp = (r['sum_picked'] as num?)?.toDouble() ?? 0.0;
        if (pid.isNotEmpty && qp > 0) {
          historicalPartPicks[pid] = qp;
        }
      }

      // Also check existing picklist_items table in case picks were recorded there
      final existingItemRows = await txn.query(
        'picklist_items',
        columns: ['work_order', 'part_id', 'row_order', 'qty_picked'],
        where: 'LOWER(unit_id) = ? AND qty_picked > 0',
        whereArgs: [unitId.toLowerCase()],
      );
      final exactPickedMap = <String, double>{};
      for (final r in existingItemRows) {
        final wo = r['work_order']?.toString() ?? '';
        final pid = r['part_id']?.toString() ?? '';
        final ro = r['row_order']?.toString() ?? '';
        final qp = (r['qty_picked'] as num?)?.toDouble() ?? 0.0;
        exactPickedMap['${wo}__${pid}__$ro'] = qp;
        if ((historicalPartPicks[pid] ?? 0.0) < qp) {
          historicalPartPicks[pid] = qp;
        }
      }

      // 2. Allocate historical picks onto the new parsed items
      final remainingPicks = Map<String, double>.from(historicalPartPicks);
      final itemsToInsert = <PicklistItem>[];
      double totalRestored = 0.0;

      for (final item in parsedItems) {
        double restoredQty = item.qtyPicked;
        final exactKey = '${item.workOrder}__${item.partId}__${item.rowOrder}';

        if (exactPickedMap.containsKey(exactKey)) {
          restoredQty = exactPickedMap[exactKey]!;
        } else if (remainingPicks.containsKey(item.partId) && remainingPicks[item.partId]! > 0) {
          final available = remainingPicks[item.partId]!;
          restoredQty = available > item.qtyRequired ? item.qtyRequired : available;
          remainingPicks[item.partId] = (available - restoredQty).clamp(0.0, double.infinity);
        }

        totalRestored += restoredQty;
        final due = (item.qtyRequired - restoredQty).clamp(0.0, item.qtyRequired);
        itemsToInsert.add(item.copyWith(
          qtyPicked: restoredQty,
          qtyDue: due,
        ));
      }

      // 3. Replace picklist_items
      await txn.delete('picklist_items', where: 'LOWER(unit_id) = ?', whereArgs: [unitId.toLowerCase()]);
      final batch = txn.batch();
      for (final it in itemsToInsert) {
        batch.insert('picklist_items', it.toMap());
      }
      await batch.commit(noResult: true);

      // 4. Save departments
      await txn.delete('departments', where: 'LOWER(unit_id) = ?', whereArgs: [unitId.toLowerCase()]);
      final deptBatch = txn.batch();
      for (final d in departments) {
        deptBatch.insert('departments', {
          'unit_id': unitId,
          'name': d,
          'is_active': 1,
        });
      }
      await deptBatch.commit(noResult: true);

      // 5. Re-link historical sessions and session picks to this unitId
      await txn.update(
        'sessions',
        {'unit_id': unitId},
        where: 'LOWER(unit_id) = ?',
        whereArgs: [unitId.toLowerCase()],
      );
      await txn.update(
        'session_picks',
        {'unit_id': unitId},
        where: 'LOWER(unit_id) = ?',
        whereArgs: [unitId.toLowerCase()],
      );

      // 6. Save active unit record (clear deleted_at)
      final totalReq = parsedItems.fold<double>(0.0, (s, i) => s + i.qtyRequired).round();
      final restoredUnit = unit.copyWith(
        filePath: unit.filePath,
        totalRequired: totalReq,
        totalPicked: totalRestored.round(),
        status: (totalRestored >= totalReq && totalReq > 0) ? 'FULLY_PICKED' : 'IN_PROGRESS',
        lastAccessedAt: now,
        clearDeletedAt: true,
      );

      await txn.insert('units', restoredUnit.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      LogService.admin('Unit "${unit.name}" recovered with $totalRestored picked pcs across ${itemsToInsert.length} items');

      return restoredUnit;
    });
  }

  /// Permanently removes units (and cascade-deletes their sessions and items)
  /// that have been soft-deleted for more than [retentionDays] days (default 30 days).
  Future<int> purgeExpiredDeletedUnits({int retentionDays = 30}) async {
    final db = await database;
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays)).millisecondsSinceEpoch;
    final expiredUnits = await db.query(
      'units',
      columns: ['id'],
      where: 'deleted_at IS NOT NULL AND deleted_at < ?',
      whereArgs: [cutoff],
    );

    int purgedCount = 0;
    for (final u in expiredUnits) {
      final uid = u['id'] as String;
      await db.transaction((txn) async {
        await txn.delete('picklist_items', where: 'unit_id = ?', whereArgs: [uid]);
        await txn.delete('departments', where: 'unit_id = ?', whereArgs: [uid]);
        // Note: Sessions are NOT deleted on unit expiration!
        // Sessions are retained for 60 days after being marked as ISSUED.
        await txn.delete('units', where: 'id = ?', whereArgs: [uid]);
      });
      purgedCount++;
    }
    return purgedCount;
  }

  /// Permanently removes sessions according to the lifecycle retention policy:
  /// - CLOSED sessions older than 80 days
  /// - EXPORTED sessions older than 70 days
  /// - ISSUED sessions older than 60 days
  /// Also enforces 50 MB total storage cap.
  Future<int> purgeExpiredIssuedSessions({int retentionDays = 60}) async {
    return await purgeExpiredSessionsLifecycle(issuedRetentionDays: retentionDays);
  }

  Future<int> purgeExpiredSessionsLifecycle({
    int closedRetentionDays = 80,
    int exportedRetentionDays = 70,
    int issuedRetentionDays = 60,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final closedCutoff = now - Duration(days: closedRetentionDays).inMilliseconds;
    final exportedCutoff = now - Duration(days: exportedRetentionDays).inMilliseconds;
    final issuedCutoff = now - Duration(days: issuedRetentionDays).inMilliseconds;

    int purgedCount = 0;

    // 1. Purge CLOSED older than 80 days
    purgedCount += await db.delete(
      'sessions',
      where: "status = 'CLOSED' AND ((end_time IS NOT NULL AND end_time < ?) OR (end_time IS NULL AND start_time < ?))",
      whereArgs: [closedCutoff, closedCutoff],
    );

    // 2. Purge EXPORTED older than 70 days
    purgedCount += await db.delete(
      'sessions',
      where: "(status = 'EXPORTED' OR status = 'FINISHED') AND ((end_time IS NOT NULL AND end_time < ?) OR (end_time IS NULL AND start_time < ?))",
      whereArgs: [exportedCutoff, exportedCutoff],
    );

    // 3. Purge ISSUED older than 60 days
    purgedCount += await db.delete(
      'sessions',
      where: "status = 'ISSUED' AND ((issued_at IS NOT NULL AND issued_at < ?) OR (issued_at IS NULL AND end_time IS NOT NULL AND end_time < ?) OR (issued_at IS NULL AND start_time < ?))",
      whereArgs: [issuedCutoff, issuedCutoff, issuedCutoff],
    );

    // 4. Enforce 50 MB storage limit
    await enforce50MbStorageCap();

    return purgedCount;
  }

  /// Checks total database file size and purges oldest records if approaching 50 MB.
  Future<void> enforce50MbStorageCap() async {
    try {
      final db = await database;
      final dbPath = db.path;
      final file = File(dbPath);
      if (!await file.exists()) return;
      final sizeBytes = await file.length();
      const capBytes = 50 * 1024 * 1024; // 50 MB
      if (sizeBytes >= capBytes) {
        // Purge oldest sessions in FIFO order: ISSUED first, then EXPORTED, then CLOSED
        final oldestSessions = await db.query(
          'sessions',
          columns: ['id'],
          orderBy: "CASE status WHEN 'ISSUED' THEN 1 WHEN 'EXPORTED' THEN 2 ELSE 3 END ASC, start_time ASC",
          limit: 20,
        );
        for (final s in oldestSessions) {
          final sid = s['id'] as String;
          await db.delete('session_picks', where: 'session_id = ?', whereArgs: [sid]);
          await db.delete('sessions', where: 'id = ?', whereArgs: [sid]);
        }
        // Also prune oldest app_logs if DB is large
        await db.rawDelete('''
          DELETE FROM app_logs WHERE id IN (
            SELECT id FROM app_logs ORDER BY timestamp ASC LIMIT 500
          )
        ''');
      }
    } catch (_) {}
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('picklist_items');
      await txn.delete('departments');
      await txn.delete('sessions');
      await txn.delete('units');
    });
  }

  // --- PICKLIST ITEMS OPERATIONS ---

  Future<void> savePicklistItems(String unitId, List<PicklistItem> items) async {
    final db = await database;
    await db.transaction((txn) async {
      // Check if there are previously picked items in DB for this unit to restore progress
      final existingRows = await txn.query(
        'picklist_items',
        columns: ['work_order', 'part_id', 'row_order', 'qty_picked'],
        where: 'unit_id = ? AND qty_picked > 0',
        whereArgs: [unitId],
      );

      final exactPickedMap = <String, double>{};
      final woPartPickedMap = <String, double>{};
      for (final r in existingRows) {
        final wo = r['work_order']?.toString() ?? '';
        final pid = r['part_id']?.toString() ?? '';
        final ro = r['row_order']?.toString() ?? '';
        final qp = (r['qty_picked'] as num?)?.toDouble() ?? 0.0;
        exactPickedMap['${wo}__${pid}__$ro'] = qp;
        woPartPickedMap['${wo}__$pid'] = (woPartPickedMap['${wo}__$pid'] ?? 0.0) + qp;
      }

      await txn.delete('picklist_items', where: 'unit_id = ?', whereArgs: [unitId]);
      final batch = txn.batch();
      double totalRestored = 0.0;

      for (final item in items) {
        var restoredPicked = item.qtyPicked;
        final exactKey = '${item.workOrder}__${item.partId}__${item.rowOrder}';
        final woKey = '${item.workOrder}__${item.partId}';

        if (exactPickedMap.containsKey(exactKey)) {
          restoredPicked = exactPickedMap[exactKey]!;
        } else if (item.qtyPicked <= 0.0001 && woPartPickedMap.containsKey(woKey)) {
          restoredPicked = woPartPickedMap[woKey]!;
        }

        totalRestored += restoredPicked;
        final restoredDue = (item.qtyRequired - restoredPicked).clamp(0.0, item.qtyRequired);
        final itemToSave = item.copyWith(
          qtyPicked: restoredPicked,
          qtyDue: restoredDue,
        );
        batch.insert('picklist_items', itemToSave.toMap());
      }
      await batch.commit(noResult: true);

      if (totalRestored > 0) {
        await txn.update(
          'units',
          {
            'total_picked': totalRestored.round(),
            'deleted_at': null,
          },
          where: 'id = ?',
          whereArgs: [unitId],
        );
      }
    });
  }

  Future<List<PicklistItem>> getPicklistItems(String unitId) async {
    final db = await database;
    final maps = await db.query(
      'picklist_items',
      where: 'unit_id = ?',
      whereArgs: [unitId],
      orderBy: 'row_order ASC',
    );
    return maps.map((m) => PicklistItem.fromMap(m)).toList();
  }

  Future<void> updateItemQtyPicked(String itemId, double qtyPicked, double qtyDue) async {
    final db = await database;
    await db.update(
      'picklist_items',
      {
        'qty_picked': qtyPicked,
        'qty_due': qtyDue,
      },
      where: 'id = ?',
      whereArgs: [itemId],
    );
    if (qtyDue <= 0.0001) {
      final rows = await db.query('picklist_items', columns: ['unit_id', 'part_id'], where: 'id = ?', whereArgs: [itemId], limit: 1);
      if (rows.isNotEmpty) {
        final unitId = rows.first['unit_id']?.toString() ?? '';
        final partId = rows.first['part_id']?.toString() ?? '';
        if (unitId.isNotEmpty && partId.isNotEmpty) {
          await clearPartFlag(unitId: unitId, partId: partId);
        }
      }
    }
  }

  Future<void> batchUpdateItems(List<PicklistItem> items) async {
    if (items.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final item in items) {
        batch.update(
          'picklist_items',
          {
            'qty_picked': item.qtyPicked,
            'qty_due': item.qtyDue,
          },
          where: 'id = ?',
          whereArgs: [item.id],
        );
      }
      await batch.commit(noResult: true);
    });
    await cleanupResolvedMissingFlags(items.first.unitId);
  }

  // --- DEPARTMENTS CONFIGURATION ---

  Future<void> saveDepartments(String unitId, List<String> departmentNames) async {
    final db = await database;
    final blockedJson = await getConfig('blocked_departments');
    final blockedSet = <String>{};
    if (blockedJson != null) {
      try {
        final list = (json.decode(blockedJson) as List).map((e) => e.toString()).toSet();
        blockedSet.addAll(list);
      } catch (_) {}
    }

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final dept in departmentNames) {
        final id = '${unitId}_$dept';
        final isActive = blockedSet.contains(dept) ? 0 : 1;
        batch.insert(
          'departments',
          {
            'id': id,
            'unit_id': unitId,
            'name': dept,
            'is_active': isActive,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<Map<String, bool>> getDepartmentsForUnit(String unitId) async {
    final db = await database;
    var maps = await db.query(
      'departments',
      where: 'unit_id = ?',
      whereArgs: [unitId],
    );

    // Self-heal: If departments table has no entries for this unit, extract them from picklist_items
    if (maps.isEmpty) {
      final itemDepts = await db.rawQuery(
        'SELECT DISTINCT department FROM picklist_items WHERE unit_id = ? AND department != ""',
        [unitId],
      );
      if (itemDepts.isNotEmpty) {
        final deptNames = itemDepts
            .map((m) => m['department']?.toString().trim())
            .where((s) => s != null && s.isNotEmpty)
            .cast<String>()
            .toList();
        await saveDepartments(unitId, deptNames);
        maps = await db.query('departments', where: 'unit_id = ?', whereArgs: [unitId]);
      }
    }

    final blockedJson = await getConfig('blocked_departments');
    final blockedSet = <String>{};
    if (blockedJson != null) {
      try {
        final list = (json.decode(blockedJson) as List).map((e) => e.toString()).toSet();
        blockedSet.addAll(list);
      } catch (_) {}
    }

    final result = <String, bool>{};
    for (final m in maps) {
      final name = m['name'] as String;
      final isUnitActive = (m['is_active'] as int) == 1;
      final isGloballyBlocked = blockedSet.contains(name);
      result[name] = isUnitActive && !isGloballyBlocked;
    }
    return result;
  }

  Future<void> setDepartmentActive(String unitId, String department, bool isActive) async {
    final db = await database;
    await db.update(
      'departments',
      {'is_active': isActive ? 1 : 0},
      where: 'unit_id = ? AND name = ?',
      whereArgs: [unitId, department],
    );
  }

  /// Returns the set of all department names currently blocked from picking globally or per unit.
  Future<Set<String>> getBlockedDepartmentSet() async {
    final blockedJson = await getConfig('blocked_departments');
    final blockedSet = <String>{};
    if (blockedJson != null) {
      try {
        final list = (json.decode(blockedJson) as List).map((e) => e.toString().trim()).where((s) => s.isNotEmpty);
        blockedSet.addAll(list);
      } catch (_) {}
    }

    final db = await database;
    final inactiveRows = await db.query(
      'departments',
      columns: ['name'],
      where: 'is_active = 0',
    );
    for (final r in inactiveRows) {
      final n = r['name']?.toString().trim();
      if (n != null && n.isNotEmpty) blockedSet.add(n);
    }
    return blockedSet;
  }

  /// Returns all distinct departments globally and their active status (allowed for picking).
  /// Any department not explicitly blocked in admin_config defaults to true (allowed).
  Future<Map<String, bool>> getGlobalDepartments() async {
    final allDepts = await getAllDistinctDepartments();
    final blockedSet = await getBlockedDepartmentSet();

    final result = <String, bool>{};
    for (final d in allDepts) {
      result[d] = !blockedSet.contains(d);
    }
    return result;
  }

  /// Sets a department active/blocked globally across all units on this tablet.
  Future<void> setGlobalDepartmentActive(String department, bool isActive) async {
    final db = await database;
    if (department == '(Empty / Unassigned)') {
      await db.update(
        'departments',
        {'is_active': isActive ? 1 : 0},
        where: 'name = ? OR name = "" OR name IS NULL',
        whereArgs: [department],
      );
    } else {
      await db.update(
        'departments',
        {'is_active': isActive ? 1 : 0},
        where: 'name = ?',
        whereArgs: [department],
      );
    }

    final blockedJson = await getConfig('blocked_departments');
    final blockedSet = <String>{};
    if (blockedJson != null) {
      try {
        final list = (json.decode(blockedJson) as List).map((e) => e.toString()).toSet();
        blockedSet.addAll(list);
      } catch (_) {}
    }

    if (isActive) {
      blockedSet.remove(department);
    } else {
      blockedSet.add(department);
    }
    await setConfig('blocked_departments', json.encode(blockedSet.toList()));
  }

  /// Bulk set all departments active/blocked globally.
  Future<void> setAllGlobalDepartmentsActive(bool isActive) async {
    final db = await database;
    await db.update('departments', {'is_active': isActive ? 1 : 0});
    final allDepts = await getAllDistinctDepartments();
    if (isActive) {
      await setConfig('blocked_departments', json.encode([]));
    } else {
      await setConfig('blocked_departments', json.encode(allDepts));
    }
  }

  /// Returns all unique department names found across all units and picklist items.
  Future<List<String>> getAllDistinctDepartments() async {
    final db = await database;
    final deptMaps = await db.rawQuery('SELECT DISTINCT name FROM departments WHERE name IS NOT NULL AND name != ""');
    final itemMaps = await db.rawQuery('SELECT DISTINCT department FROM picklist_items WHERE department IS NOT NULL AND department != ""');
    final emptyItems = await db.rawQuery('SELECT COUNT(*) as cnt FROM picklist_items WHERE department IS NULL OR TRIM(department) = "" OR department = "(Empty / Unassigned)"');

    final set = <String>{};
    for (final m in deptMaps) {
      final name = (m['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) set.add(name);
    }
    for (final m in itemMaps) {
      final name = (m['department'] as String?)?.trim();
      if (name != null && name.isNotEmpty) set.add(name);
    }
    final knownDepts = await getKnownDepartments();
    set.addAll(knownDepts);
    final emptyCount = Sqflite.firstIntValue(emptyItems) ?? 0;
    if (emptyCount > 0) {
      set.add('(Empty / Unassigned)');
    }

    final list = set.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  // --- SESSIONS ---

  Future<void> saveSession(SessionMetadata session) async {
    final db = await database;
    await db.insert('sessions', session.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<SessionMetadata?> getActiveSession(String unitId) async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'unit_id = ? AND status = ?',
      whereArgs: [unitId, 'ACTIVE'],
      orderBy: 'start_time DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return SessionMetadata.fromMap(maps.first);
  }

  /// Returns all ACTIVE or OPEN sessions across all units.
  Future<List<SessionMetadata>> getAllActiveSessions() async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'status = ? OR status = ?',
      whereArgs: ['ACTIVE', 'OPEN'],
      orderBy: 'start_time DESC',
    );
    return maps.map((m) => SessionMetadata.fromMap(m)).toList();
  }

  /// Marks a session as EXPORTED — file has been successfully written to disk.
  Future<void> finishSession(String sessionId, int endTime, int totalPicked, String issuedStatus, {String? batchId}) async {
    final db = await database;
    final updates = <String, dynamic>{
      'end_time': endTime,
      'status': 'EXPORTED',
      'issued_status': issuedStatus,
      'total_items_picked': totalPicked,
    };
    if (batchId != null) {
      updates['batch_id'] = batchId;
    }
    await db.update(
      'sessions',
      updates,
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Marks a session as CLOSED — picker has finished their shift but has not yet exported.
  /// CLOSED sessions appear in the export list and block re-opening.
  Future<void> closeSession(String sessionId, int endTime, int totalPicked) async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE sessions
      SET end_time = ?,
          status = 'CLOSED',
          total_items_picked = MAX(total_items_picked, ?)
      WHERE id = ?
    ''', [endTime, totalPicked, sessionId]);
  }

  /// Closes all active or open sessions across all units.
  Future<void> closeAllActiveSessions({int? endTime}) async {
    final db = await database;
    final now = endTime ?? DateTime.now().millisecondsSinceEpoch;
    final activeSessions = await db.query(
      'sessions',
      where: 'status = ? OR status = ?',
      whereArgs: ['ACTIVE', 'OPEN'],
    );
    for (final s in activeSessions) {
      final sId = s['id']?.toString() ?? '';
      final unitId = s['unit_id']?.toString() ?? '';
      int currentPicked = (s['total_items_picked'] as num?)?.toInt() ?? 0;
      if (currentPicked <= 0 && unitId.isNotEmpty) {
        final res = await db.rawQuery(
          'SELECT COUNT(DISTINCT part_id) as cnt FROM picklist_items WHERE unit_id = ? AND qty_picked > 0.0001',
          [unitId],
        );
        final cnt = (res.first['cnt'] as num?)?.toInt() ?? 0;
        if (cnt > 0) {
          currentPicked = cnt;
        }
      }
      await db.update(
        'sessions',
        {
          'end_time': now,
          'status': 'CLOSED',
          'total_items_picked': currentPicked,
        },
        where: 'id = ?',
        whereArgs: [sId],
      );
    }
  }

  /// Admin action: mark a CLOSED or EXPORTED session as ISSUED.
  Future<void> updateSessionIssuedStatus(String sessionId, String status, {int? issuedAt}) async {
    final db = await database;
    final updates = <String, dynamic>{
      'status': status,
      'issued_status': status == 'ISSUED' ? 'Issued' : 'Pending Issue',
    };
    if (status == 'ISSUED') {
      updates['issued_at'] = issuedAt ?? DateTime.now().millisecondsSinceEpoch;
    }
    await db.update(
      'sessions',
      updates,
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Updates progress of an ACTIVE session (total items picked and optional timestamp).
  Future<void> updateSessionProgress(String sessionId, int totalPicked, {int? endTime}) async {
    final db = await database;
    final updates = <String, dynamic>{
      'total_items_picked': totalPicked,
    };
    if (endTime != null) {
      updates['end_time'] = endTime;
    }
    await db.update(
      'sessions',
      updates,
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Deletes a session that has zero picks (abandoned empty session).
  Future<void> deleteEmptySession(String sessionId) async {
    final db = await database;
    // Safety check: before deleting, verify that NO items were picked for its unit
    final sessRows = await db.query('sessions', where: 'id = ?', whereArgs: [sessionId]);
    if (sessRows.isNotEmpty) {
      final unitId = sessRows.first['unit_id']?.toString() ?? '';
      if (unitId.isNotEmpty) {
        final pickRes = await db.rawQuery(
          'SELECT COUNT(DISTINCT part_id) as cnt FROM picklist_items WHERE unit_id = ? AND qty_picked > 0.0001',
          [unitId],
        );
        final cnt = (pickRes.first['cnt'] as num?)?.toInt() ?? 0;
        if (cnt > 0) {
          // Picks exist on this unit! Do not delete — update total_items_picked and keep CLOSED
          await db.update('sessions', {'total_items_picked': cnt, 'status': 'CLOSED'}, where: 'id = ?', whereArgs: [sessionId]);
          return;
        }
      }
    }
    await db.delete('sessions', where: 'id = ? AND total_items_picked = 0', whereArgs: [sessionId]);
  }

  /// Permanently deletes specific sessions by IDs (e.g. cleaning up test or legacy batches).
  Future<void> deleteSessions(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(sessionIds.length, '?').join(',');
    await db.delete(
      'sessions',
      where: 'id IN ($placeholders)',
      whereArgs: sessionIds,
    );
  }

  /// Returns next sequential session number globally for the tablet (1..9999 wrapping).
  /// Monotonically increases across all units so session numbers never duplicate.
  Future<int> nextSessionSeqNo([String? unitId]) async {
    final db = await database;
    const configKey = 'global_last_session_seq_no';
    final savedValStr = await getConfig(configKey);
    final savedVal = int.tryParse(savedValStr ?? '') ?? 0;

    final result = await db.rawQuery(
      'SELECT MAX(session_seq_no) as mx FROM sessions',
    );
    final dbMax = (result.first['mx'] as num?)?.toInt() ?? 0;

    final current = savedVal > dbMax ? savedVal : dbMax;
    final next = current >= 9999 ? 1 : current + 1;

    await setConfig(configKey, next.toString());
    if (unitId != null && unitId.isNotEmpty) {
      await setConfig('last_seq_no_$unitId', next.toString());
    }
    return next;
  }

  /// Returns the total count of distinct parts flagged as MISSING for a unit.
  Future<int> getUnitMissingPartsCount(String unitId) async {
    final db = await database;
    final res = await db.rawQuery(
      "SELECT COUNT(DISTINCT part_id) as cnt FROM part_flags WHERE unit_id = ? AND UPPER(flag_type) = 'MISSING'",
      [unitId],
    );
    return (res.first['cnt'] as num?)?.toInt() ?? 0;
  }

  /// Returns pick statistics for a unit:
  /// - picked_parts: distinct part IDs with qty_picked > 0.0001 (partially or fully picked)
  /// - total_parts: distinct part IDs in the entire picklist for this unit
  /// - total_pieces: sum of qty_picked across all items
  Future<Map<String, num>> getUnitPartPickStats(String unitId) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT 
        COUNT(DISTINCT CASE WHEN qty_picked > 0.0001 THEN part_id END) as picked_parts,
        COUNT(DISTINCT part_id) as total_parts,
        COALESCE(SUM(qty_picked), 0.0) as total_pieces
      FROM picklist_items
      WHERE unit_id = ?
    ''', [unitId]);
    if (res.isEmpty) return {'picked_parts': 0, 'total_parts': 0, 'total_pieces': 0.0};
    return {
      'picked_parts': (res.first['picked_parts'] as num?)?.toInt() ?? 0,
      'total_parts': (res.first['total_parts'] as num?)?.toInt() ?? 0,
      'total_pieces': (res.first['total_pieces'] as num?)?.toDouble() ?? 0.0,
    };
  }

  /// Auto-closes sessions older than 13 hours that are still ACTIVE.
  Future<void> autoCloseExpiredSessions() async {
    final db = await database;
    final cutoff = DateTime.now().subtract(const Duration(hours: 13)).millisecondsSinceEpoch;
    await db.update(
      'sessions',
      {'status': 'CLOSED', 'end_time': DateTime.now().millisecondsSinceEpoch},
      where: 'status = ? AND start_time < ?',
      whereArgs: ['ACTIVE', cutoff],
    );
  }

  /// Aggregates return comments per Part ID for a given unit.
  /// Returns: {partId: ['comment1', 'comment2', ...]}
  Future<Map<String, List<String>>> getReturnCommentsForUnit(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT part_id, comment FROM pick_returns WHERE unit_id = ? ORDER BY created_at ASC',
      [unitId],
    );
    final result = <String, List<String>>{};
    for (final row in rows) {
      final partId = row['part_id'] as String? ?? '';
      final comment = row['comment'] as String? ?? '';
      if (partId.isEmpty || comment.isEmpty) continue;
      (result[partId] ??= []).add(comment);
    }
    return result;
  }

  /// Returns all sessions for a unit, ordered newest first.
  Future<List<SessionMetadata>> getAllSessionsForUnit(String unitId) async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'unit_id = ?',
      whereArgs: [unitId],
      orderBy: 'start_time DESC',
    );
    return maps.map((m) => SessionMetadata.fromMap(m)).toList();
  }

  /// Returns all sessions for a unit that are CLOSED or FINISHED.
  /// Used by the session export screen.
  Future<List<SessionMetadata>> getExportableSessionsForUnit(String unitId) async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: "unit_id = ? AND status IN ('CLOSED', 'FINISHED')",
      whereArgs: [unitId],
      orderBy: 'start_time DESC',
    );
    final list = <SessionMetadata>[];
    for (final m in maps) {
      var sess = SessionMetadata.fromMap(m);
      if (sess.totalItemsPicked <= 0) {
        final cnt = await getSessionPickedPartCount(sess.id);
        if (cnt > 0) {
          sess = sess.copyWith(totalItemsPicked: cnt);
          await db.update('sessions', {'total_items_picked': cnt}, where: 'id = ?', whereArgs: [sess.id]);
        }
      }
      list.add(sess);
    }
    return list;
  }

  /// Returns all sessions across ALL units that are CLOSED/EXPORTED/ISSUED.
  Future<List<SessionMetadata>> getAllExportableSessions() async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: "status IN ('CLOSED', 'EXPORTED', 'FINISHED', 'ISSUED')",
      orderBy: 'start_time DESC',
    );
    final list = <SessionMetadata>[];
    for (final m in maps) {
      var sess = SessionMetadata.fromMap(m);
      if (sess.totalItemsPicked <= 0) {
        final cnt = await getSessionPickedPartCount(sess.id);
        if (cnt > 0) {
          sess = sess.copyWith(totalItemsPicked: cnt);
          await db.update('sessions', {'total_items_picked': cnt}, where: 'id = ?', whereArgs: [sess.id]);
        }
      }
      list.add(sess);
    }
    return list;
  }


  /// Total session count across all units.
  Future<int> countSessions() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM sessions');
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// Deletes the single oldest FINISHED session (global, any unit). Used for session pruning.
  Future<void> deleteOldestFinishedSession() async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'status = ?',
      whereArgs: ['FINISHED'],
      orderBy: 'start_time ASC',
      limit: 1,
    );
    if (maps.isNotEmpty) {
      await db.delete('sessions', where: 'id = ?', whereArgs: [maps.first['id']]);
    }
  }

  // --- ADMIN CONFIG ---

  Future<String?> getConfig(String key) async {
    final db = await database;
    final maps = await db.query('admin_config', where: 'key = ?', whereArgs: [key], limit: 1);
    if (maps.isEmpty) return null;
    return maps.first['value'] as String?;
  }

  Future<void> setConfig(String key, String value) async {
    final db = await database;
    await db.insert(
      'admin_config',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<String>> getStandardPickers() async {
    final jsonStr = await getConfig('standard_pickers');
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final list = jsonDecode(jsonStr) as List;
        return list.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return ['Alex', 'John', 'Sarah', 'Mike', 'David'];
  }

  Future<void> saveStandardPickers(List<String> pickers) async {
    await setConfig('standard_pickers', jsonEncode(pickers));
  }

  /// Exports all device configuration settings into a structured Map suitable for JSON serialization.
  Future<Map<String, dynamic>> exportFullConfiguration({
    bool includePins = true,
    String? columnMapperJson,
  }) async {
    final db = await database;
    final rows = await db.query('admin_config');
    final rawConfig = <String, String>{};
    for (final r in rows) {
      final k = r['key'] as String? ?? '';
      final v = r['value'] as String? ?? '';
      if (k.isNotEmpty) rawConfig[k] = v;
    }

    final tabletId = rawConfig['tablet_id'] ?? 'Tablet 1';
    final autoAdvance = rawConfig['auto_advance_pick'] == '1' || rawConfig['auto_advance_pick'] == 'true';
    final groupByLine = rawConfig['group_by_line'] != '0' && rawConfig['group_by_line'] != 'false';
    final lastExportDir = rawConfig['last_export_dir'] ?? '';
    final standardPickers = await getStandardPickers();
    final globalDepts = await getGlobalDepartments();
    final blockedResources = await getBlockedResourceIds();
    final autoIssueResources = await getAutoIssueResourceIds();
    final autoIssueComponents = await getAutoIssueComponents();
    final patternRules = await getResourcePatternRules();
    final mainLinePicks = await getMainLineResourcePicks();
    final mainLineDefaultView = rawConfig['mainline_resource_default_view'] ?? 'combined';
    final mainLineViews = await getMainLineResourceViewOverrides();
    final deptLineOverrides = await getLineGroupingDeptOverrides();
    final resLineOverrides = await getLineGroupingResourceOverrides();

    final mapperConfig = columnMapperJson ?? rawConfig['column_mapper_config'];
    final knownDepts = await getKnownDepartments();
    final knownCompResources = await getKnownComponentResources();
    final knownMainLine = await getKnownMainLineResources();

    final settings = <String, dynamic>{
      'tablet_id': tabletId,
      'auto_advance_pick': autoAdvance,
      'group_by_line': groupByLine,
      'last_export_dir': lastExportDir,
      'standard_pickers': standardPickers,
      'global_departments': globalDepts,
      'known_departments': knownDepts,
      'known_component_resources': knownCompResources,
      'known_main_line_resources': knownMainLine,
      'blocked_resource_ids': blockedResources,
      'auto_issue_resource_ids': autoIssueResources,
      'auto_issue_components': autoIssueComponents,
      'component_resource_pattern_rules': patternRules,
      'main_line_resource_picks': mainLinePicks,
      'mainline_resource_default_view': mainLineDefaultView,
      'mainline_resource_views': mainLineViews,
      'line_grouping_dept_overrides': deptLineOverrides,
      'line_grouping_resource_overrides': resLineOverrides,
    };

    if (mapperConfig != null && mapperConfig.isNotEmpty) {
      try {
        settings['column_mapper_config'] = jsonDecode(mapperConfig);
      } catch (_) {
        settings['column_mapper_config'] = mapperConfig;
      }
    }

    if (includePins) {
      if (rawConfig.containsKey('admin_pin')) settings['admin_pin'] = rawConfig['admin_pin'];
      if (rawConfig.containsKey('super_admin_pin')) settings['super_admin_pin'] = rawConfig['super_admin_pin'];
    }

    return {
      'app': 'Picklist Tracker',
      'config_version': 1,
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'source_tablet_id': tabletId,
      'settings': settings,
    };
  }

  /// Imports configuration settings from a Map (parsed from a configuration JSON file).
  Future<void> importFullConfiguration(
    Map<String, dynamic> configData, {
    bool overwriteTabletId = false,
    bool overwritePins = false,
  }) async {
    final settings = (configData['settings'] as Map<String, dynamic>?) ?? configData;
    final db = await database;

    await db.transaction((txn) async {
      Future<void> setCfg(String key, String val) async {
        await txn.insert(
          'admin_config',
          {'key': key, 'value': val},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      if (overwriteTabletId && settings.containsKey('tablet_id')) {
        final tid = settings['tablet_id']?.toString().trim() ?? '';
        if (tid.isNotEmpty) await setCfg('tablet_id', tid);
      }

      if (settings.containsKey('auto_advance_pick')) {
        final val = settings['auto_advance_pick'];
        final b = val == true || val == 1 || val == '1' || val == 'true';
        await setCfg('auto_advance_pick', b ? '1' : '0');
      }

      if (settings.containsKey('group_by_line')) {
        final val = settings['group_by_line'];
        final b = val == true || val == 1 || val == '1' || val == 'true';
        await setCfg('group_by_line', b ? '1' : '0');
      }

      if (settings.containsKey('last_export_dir')) {
        final dir = settings['last_export_dir']?.toString().trim() ?? '';
        if (dir.isNotEmpty) await setCfg('last_export_dir', dir);
      }

      if (settings.containsKey('standard_pickers')) {
        final p = settings['standard_pickers'];
        if (p is List) {
          final list = p.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('standard_pickers', jsonEncode(list));
        }
      }

      if (settings.containsKey('global_departments')) {
        final gd = settings['global_departments'];
        if (gd is Map) {
          final map = <String, bool>{};
          for (final e in gd.entries) {
            map[e.key.toString()] = e.value == true;
          }
          await setCfg('global_departments', jsonEncode(map));
        }
      }

      if (settings.containsKey('known_departments')) {
        final kd = settings['known_departments'];
        if (kd is List) {
          final list = kd.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('known_departments', jsonEncode(list));
        }
      }

      if (settings.containsKey('known_component_resources')) {
        final kcr = settings['known_component_resources'];
        if (kcr is List) {
          final list = kcr.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('known_component_resources', jsonEncode(list));
        }
      }

      if (settings.containsKey('known_main_line_resources')) {
        final kml = settings['known_main_line_resources'];
        if (kml is List) {
          final list = kml.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('known_main_line_resources', jsonEncode(list));
        }
      }

      if (settings.containsKey('blocked_resource_ids')) {
        final br = settings['blocked_resource_ids'];
        if (br is List) {
          final list = br.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('blocked_resource_ids', jsonEncode(list));
        }
      }

      if (settings.containsKey('auto_issue_resource_ids')) {
        final ar = settings['auto_issue_resource_ids'];
        if (ar is List) {
          final list = ar.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('auto_issue_resource_ids', jsonEncode(list));
        }
      }

      if (settings.containsKey('auto_issue_components')) {
        final ac = settings['auto_issue_components'];
        if (ac is List) {
          final list = ac.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('auto_issue_components', jsonEncode(list));
        }
      }

      if (settings.containsKey('component_resource_pattern_rules')) {
        final pr = settings['component_resource_pattern_rules'];
        if (pr is List) {
          await setCfg('component_resource_pattern_rules', jsonEncode(pr));
        }
      }

      if (settings.containsKey('main_line_resource_picks')) {
        final ml = settings['main_line_resource_picks'];
        if (ml is List) {
          final list = ml.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          await setCfg('main_line_resource_picks', jsonEncode(list));
        }
      }

      if (settings.containsKey('mainline_resource_default_view')) {
        await setCfg('mainline_resource_default_view', settings['mainline_resource_default_view'].toString());
      }

      if (settings.containsKey('mainline_resource_views')) {
        final mv = settings['mainline_resource_views'];
        if (mv is Map) {
          final map = mv.map((k, v) => MapEntry(k.toString(), v.toString()));
          await setCfg('mainline_resource_views', jsonEncode(map));
        }
      }

      if (settings.containsKey('line_grouping_dept_overrides')) {
        final ld = settings['line_grouping_dept_overrides'];
        if (ld is Map) {
          final map = ld.map((k, v) => MapEntry(k.toString(), v == true));
          await setCfg('line_grouping_dept_overrides', jsonEncode(map));
        }
      }

      if (settings.containsKey('line_grouping_resource_overrides')) {
        final lr = settings['line_grouping_resource_overrides'];
        if (lr is Map) {
          final map = lr.map((k, v) => MapEntry(k.toString(), v == true));
          await setCfg('line_grouping_resource_overrides', jsonEncode(map));
        }
      }

      if (settings.containsKey('column_mapper_config')) {
        final cm = settings['column_mapper_config'];
        if (cm is Map || cm is List) {
          await setCfg('column_mapper_config', jsonEncode(cm));
        } else if (cm is String && cm.isNotEmpty) {
          await setCfg('column_mapper_config', cm);
        }
      }

      if (overwritePins) {
        if (settings.containsKey('admin_pin')) {
          final ap = settings['admin_pin']?.toString().trim() ?? '';
          if (ap.isNotEmpty) await setCfg('admin_pin', ap);
        }
        if (settings.containsKey('super_admin_pin')) {
          final sap = settings['super_admin_pin']?.toString().trim() ?? '';
          if (sap.isNotEmpty) await setCfg('super_admin_pin', sap);
        }
      }
    });

    await LogService.admin('Admin imported configuration file (overwriteTabletId: $overwriteTabletId, overwritePins: $overwritePins)');
  }

  // --- RETURNS & FLAGS ---

  Future<void> recordReturn({
    required String sessionId,
    required String unitId,
    required String workerName,
    required String partId,
    required String department,
    required double qtyReturned,
    required String comment,
  }) async {
    final db = await database;
    final uuid = const Uuid().v4();
    await db.insert('pick_returns', {
      'id': uuid,
      'session_id': sessionId,
      'unit_id': unitId,
      'worker_name': workerName,
      'part_id': partId,
      'department': department,
      'qty_returned': qtyReturned,
      'comment': comment,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> recordPartFlag({
    required String unitId,
    required String partId,
    required String department,
    required String flagType,
    String note = '',
  }) async {
    final db = await database;
    final uuid = const Uuid().v4();
    await db.insert('part_flags', {
      'id': uuid,
      'unit_id': unitId,
      'part_id': partId,
      'department': department,
      'flag_type': flagType,
      'note': note,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Clears a part flag (e.g. MISSING) when a part has been fully picked.
  Future<int> clearPartFlag({
    required String unitId,
    required String partId,
    String? department,
    String flagType = 'MISSING',
  }) async {
    final db = await database;
    if (department != null && department.isNotEmpty) {
      return await db.delete(
        'part_flags',
        where: 'unit_id = ? AND part_id = ? AND department = ? AND UPPER(flag_type) = UPPER(?)',
        whereArgs: [unitId, partId, department, flagType],
      );
    }
    return await db.delete(
      'part_flags',
      where: 'unit_id = ? AND part_id = ? AND UPPER(flag_type) = UPPER(?)',
      whereArgs: [unitId, partId, flagType],
    );
  }

  /// Cleans up any MISSING part_flags for parts that have had at least one pick (qty_picked > 0.0001) or are fully picked.
  Future<int> cleanupResolvedMissingFlags(String unitId) async {
    final db = await database;
    return await db.rawDelete('''
      DELETE FROM part_flags
      WHERE unit_id = ? AND UPPER(flag_type) = 'MISSING'
        AND part_id IN (
          SELECT part_id FROM picklist_items WHERE unit_id = ? GROUP BY part_id HAVING SUM(qty_due) <= 0.0001 OR SUM(qty_picked) > 0.0001
        )
    ''', [unitId, unitId]);
  }

  /// Returns recorded part flags (e.g. MISSING) for a unit, optionally filtered by department.
  Future<List<Map<String, dynamic>>> getPartFlags(String unitId, {String? department}) async {
    await cleanupResolvedMissingFlags(unitId);
    final db = await database;
    if (department != null && department.isNotEmpty) {
      return await db.query(
        'part_flags',
        where: 'unit_id = ? AND department = ?',
        whereArgs: [unitId, department],
        orderBy: 'created_at DESC',
      );
    }
    return await db.query(
      'part_flags',
      where: 'unit_id = ?',
      whereArgs: [unitId],
      orderBy: 'created_at DESC',
    );
  }

  /// Returns true if a part has been flagged as REMOVED FROM PICKING for this unit.
  Future<bool> isPartRemovedFromPicking(String unitId, String partId, {String? department}) async {
    final db = await database;
    final where = department != null && department.isNotEmpty
        ? 'unit_id = ? AND part_id = ? AND UPPER(flag_type) = \'REMOVED\''
        : 'unit_id = ? AND part_id = ? AND UPPER(flag_type) = \'REMOVED\'';
    final rows = await db.query(
      'part_flags',
      where: where,
      whereArgs: [unitId, partId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Returns all part IDs flagged as REMOVED FROM PICKING for this unit (and optional dept).
  Future<Set<String>> getRemovedFromPickingParts(String unitId, {String? department}) async {
    final db = await database;
    final rows = department != null && department.isNotEmpty
        ? await db.query(
            'part_flags',
            columns: ['part_id'],
            where: "unit_id = ? AND department = ? AND UPPER(flag_type) = 'REMOVED'",
            whereArgs: [unitId, department],
          )
        : await db.query(
            'part_flags',
            columns: ['part_id'],
            where: "unit_id = ? AND UPPER(flag_type) = 'REMOVED'",
            whereArgs: [unitId],
          );
    return rows.map((r) => r['part_id']?.toString() ?? '').where((s) => s.isNotEmpty).toSet();
  }

  /// Returns a map of partId -> remove note for parts flagged as REMOVED for a unit.
  Future<Map<String, String>> getRemovedPartCommentsForUnit(String unitId, {String? department}) async {
    final db = await database;
    final rows = department != null && department.isNotEmpty
        ? await db.query(
            'part_flags',
            columns: ['part_id', 'note'],
            where: "unit_id = ? AND department = ? AND UPPER(flag_type) = 'REMOVED'",
            whereArgs: [unitId, department],
            orderBy: 'created_at DESC',
          )
        : await db.query(
            'part_flags',
            columns: ['part_id', 'note'],
            where: "unit_id = ? AND UPPER(flag_type) = 'REMOVED'",
            whereArgs: [unitId],
            orderBy: 'created_at DESC',
          );
    final map = <String, String>{};
    for (final r in rows) {
      final pid = r['part_id']?.toString() ?? '';
      final note = r['note']?.toString() ?? '';
      if (pid.isNotEmpty && !map.containsKey(pid)) {
        map[pid] = note;
      }
    }
    return map;
  }

  /// Sets or clears a free-form picker note for a specific Part ID in a unit.
  Future<void> setUserPartNote({
    required String unitId,
    required String partId,
    required String note,
    String department = '',
  }) async {
    final db = await database;
    final trimmed = note.trim();
    await db.delete(
      'part_flags',
      where: 'unit_id = ? AND part_id = ? AND UPPER(flag_type) = ?',
      whereArgs: [unitId, partId, 'USER_NOTE'],
    );
    if (trimmed.isNotEmpty) {
      await db.insert('part_flags', {
        'id': const Uuid().v4(),
        'unit_id': unitId,
        'part_id': partId,
        'department': department,
        'flag_type': 'USER_NOTE',
        'note': trimmed,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  /// Returns all free-form picker notes for a unit as a Map<partId, note>.
  Future<Map<String, String>> getUserPartNotesForUnit(String unitId) async {
    final db = await database;
    final rows = await db.query(
      'part_flags',
      where: 'unit_id = ? AND UPPER(flag_type) = ?',
      whereArgs: [unitId, 'USER_NOTE'],
    );
    final map = <String, String>{};
    for (final r in rows) {
      final pid = r['part_id']?.toString() ?? '';
      final note = r['note']?.toString() ?? '';
      if (pid.isNotEmpty && note.isNotEmpty) {
        map[pid] = note;
      }
    }
    return map;
  }

  /// Records a manually entered part pick in Pick Mode.
  /// Inserts a row into [manual_picks] AND inserts a complete [picklist_items] row
  /// so it appears in all grouping trees and picking views. Also updates unit progress.
  Future<PicklistItem> recordManualPick({
    required String unitId,
    required String sessionId,
    required String workerName,
    required String department,
    required String workOrder,
    required String partId,
    required double qtyPicked,
    required String note,
    String line = '',
    String resourceId = '',
    String componentResourceId = '',
    String subUnit = '',
    String deptType = '',
    String pickDate = '',
    String prodDate = '',
    String uom = 'EA',
  }) async {
    final db = await database;
    final uuid = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final itemId = 'manual_${now}_${uuid.substring(0, 8)}';
    final wo = workOrder.isNotEmpty ? workOrder : 'MANUAL';

    final rawCols = {
      '_manual_add': true,
      '_manual_note': note,
      '_manual_worker': workerName,
      '_manual_added_at': now,
      '_uom': uom,
    };

    final newItem = PicklistItem(
      id: itemId,
      unitId: unitId,
      department: department,
      line: line,
      workOrder: wo,
      partId: partId,
      partDescription: note,
      qtyRequired: qtyPicked,
      qtyDue: 0.0,
      qtyPicked: qtyPicked,
      rowOrder: 999999,
      pickDate: pickDate,
      prodDate: prodDate,
      subUnit: subUnit,
      resourceId: resourceId,
      componentResourceId: componentResourceId,
      deptType: deptType,
      rawColumns: rawCols,
    );

    await db.transaction((txn) async {
      await txn.insert('manual_picks', {
        'id': uuid,
        'unit_id': unitId,
        'session_id': sessionId,
        'worker_name': workerName,
        'department': department,
        'work_order': wo,
        'part_id': partId,
        'qty_picked': qtyPicked,
        'note': note,
        'created_at': now,
      });

      await txn.insert('picklist_items', newItem.toMap());

      // Update unit total_picked
      await txn.rawUpdate('''
        UPDATE units
        SET total_picked = (SELECT COALESCE(SUM(qty_picked), 0) FROM picklist_items WHERE unit_id = ?),
            last_accessed_at = ?
        WHERE id = ?
      ''', [unitId, now, unitId]);
    });

    LogService.picker('MANUAL ADD: $partId +${PicklistItem.formatQty(qtyPicked)} (Note: "$note") → Unit: $unitId, Dept: $department');
    return newItem;
  }

  /// Returns all manually added picks for a unit, newest first.
  Future<List<Map<String, dynamic>>> getManualPicksForUnit(String unitId) async {
    final db = await database;
    return await db.query(
      'manual_picks',
      where: 'unit_id = ?',
      whereArgs: [unitId],
      orderBy: 'created_at ASC',
    );
  }

  /// Records a Part ID replacement. Updates [picklist_items] to use the new Part ID,
  /// stores original Part ID in replacement tracking columns, and logs to [part_id_replacements].
  /// Synchronizes [manual_picks], [session_picks], and [part_flags] to maintain strict database integrity.
  /// Scoped strictly to [targetItemIds], or [department] / [resourceId] if provided.
  Future<void> recordPartIdReplacement({
    required String unitId,
    required String sessionId,
    required String workerName,
    required String oldPartId,
    required String newPartId,
    required String note,
    String? department,
    String? resourceId,
    List<String>? targetItemIds,
  }) async {
    final db = await database;
    final uuid = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      String whereClause;
      List<dynamic> whereArgs;

      if (targetItemIds != null && targetItemIds.isNotEmpty) {
        final placeholders = List.filled(targetItemIds.length, '?').join(',');
        whereClause = 'unit_id = ? AND id IN ($placeholders)';
        whereArgs = [unitId, ...targetItemIds];
      } else {
        whereClause = 'unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))';
        whereArgs = [unitId, oldPartId];

        if (department != null && department.isNotEmpty && department != 'All Departments') {
          whereClause += ' AND LOWER(TRIM(department)) = LOWER(TRIM(?))';
          whereArgs.add(department);
        } else if (resourceId != null && resourceId.isNotEmpty) {
          whereClause += ' AND (LOWER(TRIM(resource_id)) = LOWER(TRIM(?)) OR LOWER(TRIM(component_resource_id)) = LOWER(TRIM(?)))';
          whereArgs.add(resourceId);
          whereArgs.add(resourceId);
        }
      }

      await txn.rawUpdate('''
        UPDATE picklist_items
        SET part_id = ?,
            replaced_part_id = CASE WHEN replaced_part_id = '' THEN ? ELSE replaced_part_id END,
            replacement_note = ?,
            replaced_at = ?,
            replaced_by = ?
        WHERE $whereClause
      ''', [newPartId, oldPartId, note, now, workerName, ...whereArgs]);

      // If any of the replaced items were manual adds, also record replaced_from in raw_columns
      final updatedRows = await txn.query(
        'picklist_items',
        columns: ['id', 'raw_columns'],
        where: 'unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))',
        whereArgs: [unitId, newPartId],
      );
      for (final r in updatedRows) {
        final rawStr = r['raw_columns']?.toString() ?? '';
        if (rawStr.isNotEmpty) {
          try {
            final raw = jsonDecode(rawStr) as Map<String, dynamic>;
            if (raw['_manual_add'] == true || raw['_manual_add'] == 1 || raw['_manual_add'] == 'true') {
              raw['_manual_replaced_from'] = oldPartId;
              raw['_manual_replacement_note'] = note;
              await txn.update(
                'picklist_items',
                {'raw_columns': jsonEncode(raw)},
                where: 'id = ?',
                whereArgs: [r['id']],
              );
            }
          } catch (_) {}
        }
      }

      // Synchronize manual_picks table so exports and history do not retain stale part_id
      await txn.rawUpdate('''
        UPDATE manual_picks
        SET part_id = ?
        WHERE unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))
      ''', [newPartId, unitId, oldPartId]);

      // Synchronize session_picks table so session metrics recognize the new part_id
      await txn.rawUpdate('''
        UPDATE session_picks
        SET part_id = ?
        WHERE unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))
      ''', [newPartId, unitId, oldPartId]);

      // Synchronize part_flags table (e.g. notes or missing flags)
      await txn.rawUpdate('''
        UPDATE part_flags
        SET part_id = ?
        WHERE unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))
      ''', [newPartId, unitId, oldPartId]);

      // Insert replacement log record
      await txn.insert('part_id_replacements', {
        'id': uuid,
        'unit_id': unitId,
        'session_id': sessionId,
        'worker_name': workerName,
        'old_part_id': oldPartId,
        'new_part_id': newPartId,
        'note': note,
        'department': department ?? '',
        'created_at': now,
      });
    });
    LogService.picker('REPLACE PART ID: $oldPartId → $newPartId (Scope: ${department ?? resourceId ?? targetItemIds?.join(",") ?? "all"}) (Note: "$note") by $workerName on unit $unitId');
  }

  /// Updates the quantity of a manually added pick in [manual_picks] and [picklist_items].
  Future<void> updateManualPickQuantity({
    required String unitId,
    required String partId,
    required double newQty,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.rawUpdate('''
        UPDATE manual_picks
        SET qty_picked = ?
        WHERE unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))
      ''', [newQty, unitId, partId]);

      await txn.rawUpdate('''
        UPDATE picklist_items
        SET qty_required = ?,
            qty_picked = ?,
            qty_due = 0.0
        WHERE unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))
      ''', [newQty, newQty, unitId, partId]);
    });
  }

  /// Records a part removal strictly for the specified scope (Department or Resource ID).
  /// Updates [picklist_items.raw_columns] with _is_removed and _remove_note, and logs to [part_flags].
  Future<void> recordPartRemoval({
    required String unitId,
    required String partId,
    required String workerName,
    required String reason,
    String? department,
    String? resourceId,
  }) async {
    final db = await database;
    final uuid = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      await txn.insert('part_flags', {
        'id': uuid,
        'unit_id': unitId,
        'part_id': partId,
        'department': department ?? resourceId ?? '',
        'flag_type': 'REMOVED',
        'note': reason,
        'created_at': now,
      });

      String whereClause = 'unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))';
      List<dynamic> whereArgs = [unitId, partId];

      if (department != null && department.isNotEmpty && department != 'All Departments') {
        whereClause += ' AND LOWER(TRIM(department)) = LOWER(TRIM(?))';
        whereArgs.add(department);
      } else if (resourceId != null && resourceId.isNotEmpty) {
        whereClause += ' AND (LOWER(TRIM(resource_id)) = LOWER(TRIM(?)) OR LOWER(TRIM(component_resource_id)) = LOWER(TRIM(?)))';
        whereArgs.add(resourceId);
        whereArgs.add(resourceId);
      }

      final rows = await txn.query(
        'picklist_items',
        columns: ['id', 'raw_columns'],
        where: whereClause,
        whereArgs: whereArgs,
      );

      for (final r in rows) {
        final id = r['id']?.toString() ?? '';
        var raw = <String, dynamic>{};
        final rawStr = r['raw_columns']?.toString() ?? '';
        if (rawStr.isNotEmpty) {
          try {
            raw = jsonDecode(rawStr) as Map<String, dynamic>;
          } catch (_) {}
        }
        raw['_is_removed'] = true;
        raw['_remove_note'] = reason;
        raw['_remove_worker'] = workerName;
        raw['_removed_at'] = now;

        await txn.update(
          'picklist_items',
          {'raw_columns': jsonEncode(raw)},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
    LogService.picker('REMOVED PART: $partId in ${department ?? resourceId ?? "all"} (Reason: "$reason") by $workerName on unit $unitId');
  }

  /// Unmarks a part as REMOVED when it is picked, restoring it to active picking.
  /// The removal note and worker are preserved in raw_columns for technical comments/audit.
  Future<void> unmarkPartRemoval({
    required String unitId,
    required String partId,
    String? department,
    String? resourceId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      String flagWhere = 'unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?)) AND UPPER(flag_type) = \'REMOVED\'';
      List<dynamic> flagArgs = [unitId, partId];
      if (department != null && department.isNotEmpty && department != 'All Departments') {
        flagWhere += ' AND (department = ? OR department = \'\')';
        flagArgs.add(department);
      }
      await txn.delete('part_flags', where: flagWhere, whereArgs: flagArgs);

      String whereClause = 'unit_id = ? AND LOWER(TRIM(part_id)) = LOWER(TRIM(?))';
      List<dynamic> whereArgs = [unitId, partId];
      if (department != null && department.isNotEmpty && department != 'All Departments') {
        whereClause += ' AND LOWER(TRIM(department)) = LOWER(TRIM(?))';
        whereArgs.add(department);
      } else if (resourceId != null && resourceId.isNotEmpty) {
        whereClause += ' AND (LOWER(TRIM(resource_id)) = LOWER(TRIM(?)) OR LOWER(TRIM(component_resource_id)) = LOWER(TRIM(?)))';
        whereArgs.add(resourceId);
        whereArgs.add(resourceId);
      }

      final rows = await txn.query(
        'picklist_items',
        columns: ['id', 'raw_columns'],
        where: whereClause,
        whereArgs: whereArgs,
      );

      for (final r in rows) {
        final id = r['id']?.toString() ?? '';
        var raw = <String, dynamic>{};
        final rawStr = r['raw_columns']?.toString() ?? '';
        if (rawStr.isNotEmpty) {
          try {
            raw = jsonDecode(rawStr) as Map<String, dynamic>;
          } catch (_) {}
        }
        raw['_is_removed'] = false;
        // Preserve _remove_note, _remove_worker, and _removed_at for comment history

        await txn.update(
          'picklist_items',
          {'raw_columns': jsonEncode(raw)},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
    LogService.picker('UNMARKED REMOVED PART: $partId in ${department ?? resourceId ?? "all"} on unit $unitId');
  }

  /// Returns all Part ID replacement logs for a unit, in insertion order.
  Future<List<Map<String, dynamic>>> getPartIdReplacements(String unitId) async {
    final db = await database;
    return await db.query(
      'part_id_replacements',
      where: 'unit_id = ?',
      whereArgs: [unitId],
      orderBy: 'created_at ASC',
    );
  }



  /// Calculates progress by unique Part IDs for the given unit.
  /// Parts belonging to blocked departments or blocked component resources are completely excluded.
  /// Returns a Map with 'totalParts' and 'completedParts'.
  Future<Map<String, int>> getUnitPartProgress(String unitId) async {

    final allItems = await getPicklistItems(unitId);
    if (allItems.isEmpty) {
      return {'totalParts': 0, 'completedParts': 0};
    }
    final blockedDepts = await getBlockedDepartmentSet();
    final blockedRes = await getBlockedResourceIds();
    final isBlockedEmpty = blockedRes.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)');
    final blockedResSet = blockedRes
        .map((r) => r.trim().toLowerCase())
        .where((s) => s.isNotEmpty && s != '(empty / unassigned)')
        .toSet();

    final unblockedItems = allItems.where((i) {
      if (i.isManualAdd) return true;
      if (blockedDepts.contains(i.department)) return false;
      final cr = i.componentResourceId.trim().toLowerCase();
      if (cr.isEmpty) {
        if (isBlockedEmpty) return false;
      } else {
        if (blockedResSet.contains(cr)) return false;
      }
      return true;
    }).toList();

    final partMap = <String, double>{};
    for (final i in unblockedItems) {
      partMap[i.partId] = (partMap[i.partId] ?? 0.0) + i.qtyDue;
    }

    final totalParts = partMap.length;
    final completedParts = partMap.values.where((due) => due <= 0.0001).length;

    return {
      'totalParts': totalParts,
      'completedParts': completedParts,
    };
  }
  /// Calculates progress by unique Part IDs for the given department in a unit.
  /// Parts belonging to blocked component resources are completely excluded.
  /// Returns a Map with 'totalParts', 'completedParts', and 'missingParts'.
  Future<Map<String, int>> getDepartmentPartProgress(String unitId, String department) async {
    await cleanupResolvedMissingFlags(unitId);
    final allItems = await getPicklistItems(unitId);
    final deptItems = allItems.where((i) => i.department == department).toList();
    if (deptItems.isEmpty) {
      return {'totalParts': 0, 'completedParts': 0, 'missingParts': 0};
    }

    final blockedRes = await getBlockedResourceIds();
    final isBlockedEmpty = blockedRes.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)');
    final blockedResSet = blockedRes
        .map((r) => r.trim().toLowerCase())
        .where((s) => s.isNotEmpty && s != '(empty / unassigned)')
        .toSet();

    final isMainLineDept = department.toUpperCase().contains('MAIN') ||
        department.toUpperCase().contains('MACG');
    final mainLineResourcePicks = isMainLineDept ? await getMainLineResourcePicks() : <String>[];
    final mainLinePicksSet = mainLineResourcePicks.map((r) => r.trim().toLowerCase()).toSet();
    final isMainLineEmptyPick = mainLineResourcePicks.contains('(Empty / Unassigned)');

    final unblockedItems = deptItems.where((i) {
      // Exclude blocked component resources
      final cr = i.componentResourceId.trim().toLowerCase();
      if (cr.isEmpty) {
        if (isBlockedEmpty) return false;
      } else {
        if (blockedResSet.contains(cr)) return false;
      }
      // Exclude destination resources picked under Whole Resource mode
      if (isMainLineDept && mainLineResourcePicks.isNotEmpty) {
        final r = i.resourceId.trim().toLowerCase();
        if (r.isEmpty && isMainLineEmptyPick) return false;
        if (r.isNotEmpty && mainLinePicksSet.contains(r)) return false;
      }
      return true;
    }).toList();

    final partMap = <String, double>{};
    for (final i in unblockedItems) {
      partMap[i.partId] = (partMap[i.partId] ?? 0.0) + i.qtyDue;
    }

    final totalParts = partMap.length;
    final completedParts = partMap.values.where((due) => due <= 0.0001).length;

    // Missing parts among unblocked incomplete parts
    final db = await database;
    final missingFlags = await db.query(
      'part_flags',
      where: 'unit_id = ? AND department = ? AND UPPER(flag_type) = \'MISSING\'',
      whereArgs: [unitId, department],
    );
    final missingPartIds = missingFlags.map((f) => f['part_id']?.toString() ?? '').toSet();
    int missingCount = 0;
    for (final entry in partMap.entries) {
      if (entry.value > 0.0001 && missingPartIds.contains(entry.key)) {
        missingCount++;
      }
    }

    final addedPartIds = unblockedItems.where((i) => i.isManualAdd).map((i) => i.partId).toSet();
    final replacedPartIds = unblockedItems.where((i) => i.replacedPartId.isNotEmpty).map((i) => i.partId).toSet();

    final removedFlags = await db.query(
      'part_flags',
      where: 'unit_id = ? AND department = ? AND UPPER(flag_type) = \'REMOVED\'',
      whereArgs: [unitId, department],
    );
    final removedFlagPartIds = removedFlags.map((f) => f['part_id']?.toString() ?? '').toSet();
    final removedPartIds = unblockedItems
        .where((i) => i.isRemoved || removedFlagPartIds.contains(i.partId))
        .map((i) => i.partId)
        .toSet();

    return {
      'totalParts': totalParts,
      'completedParts': completedParts,
      'missingParts': missingCount,
      'addedParts': addedPartIds.length,
      'replacedParts': replacedPartIds.length,
      'removedParts': removedPartIds.length,
    };
  }

  /// Returns the earliest incomplete pick date urgency for a unit.
  /// Parts belonging to blocked departments or blocked component resources are completely excluded.
  /// Parts marked as MISSING in part_flags are excluded (they do not block completion).
  /// If all non-missing unblocked parts are picked, returns status = completed.
  /// Compares with today:
  /// - < 0 days (past due date) -> Glow RED
  /// - 0..2 days -> Glow YELLOW
  /// - > 2 days -> Glow GREEN
  Future<UnitPickDateUrgency?> getUnitEarliestIncompletePickDate(
    String unitId, {
    DateTime? referenceToday,
  }) async {
    final allItems = await getPicklistItems(unitId);
    if (allItems.isEmpty) return null;

    final blockedDepts = await getBlockedDepartmentSet();
    final blockedRes = await getBlockedResourceIds();
    final isBlockedEmpty = blockedRes.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)');
    final blockedResSet = blockedRes
        .map((r) => r.trim().toLowerCase())
        .where((s) => s.isNotEmpty && s != '(empty / unassigned)')
        .toSet();

    // Query missing part flags
    final db = await database;
    final missingRows = await db.query(
      'part_flags',
      columns: ['part_id'],
      where: 'unit_id = ? AND UPPER(flag_type) = \'MISSING\'',
      whereArgs: [unitId],
    );
    final missingPartIds = missingRows.map((r) => r['part_id']?.toString() ?? '').toSet();

    // Filter to unblocked incomplete items not flagged as missing
    final activeIncompleteItems = allItems.where((i) {
      if (blockedDepts.contains(i.department)) return false;
      final cr = i.componentResourceId.trim().toLowerCase();
      if (cr.isEmpty) {
        if (isBlockedEmpty) return false;
      } else {
        if (blockedResSet.contains(cr)) return false;
      }
      if (i.qtyDue <= 0.0001) return false;
      if (missingPartIds.contains(i.partId)) return false;
      return true;
    }).toList();

    if (activeIncompleteItems.isEmpty) {
      return UnitPickDateUrgency.evaluate(
        dateStr: null,
        department: 'All Complete',
        isAllCompleted: true,
        referenceToday: referenceToday,
      );
    }

    // Find earliest pick date among active incomplete items
    String? earliestDateStr;
    DateTime? earliestParsedDate;
    String? earliestDept;

    for (final item in activeIncompleteItems) {
      final rawDate = item.pickDate.trim();
      if (rawDate.isNotEmpty) {
        final parsed = UnitPickDateUrgency.parseDateRobust(rawDate);
        if (parsed != null) {
          if (earliestParsedDate == null || parsed.isBefore(earliestParsedDate)) {
            earliestParsedDate = parsed;
            earliestDateStr = rawDate;
            earliestDept = item.department;
          }
        } else if (earliestDateStr == null) {
          earliestDateStr = rawDate;
          earliestDept = item.department;
        }
      }
    }

    if (earliestDateStr == null && activeIncompleteItems.isNotEmpty) {
      earliestDept = activeIncompleteItems.first.department;
    }

    return UnitPickDateUrgency.evaluate(
      dateStr: earliestDateStr,
      department: earliestDept,
      isAllCompleted: false,
      referenceToday: referenceToday,
    );
  }

  /// Returns a map of department -> UnitPickDateUrgency for all departments in a unit.
  /// Excludes blocked component resources and MISSING parts from blocking department completion.
  Future<Map<String, UnitPickDateUrgency>> getDepartmentPickDates(
    String unitId, {
    DateTime? referenceToday,
  }) async {
    final allItems = await getPicklistItems(unitId);
    if (allItems.isEmpty) return {};

    final blockedRes = await getBlockedResourceIds();
    final isBlockedEmpty = blockedRes.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)');
    final blockedResSet = blockedRes
        .map((r) => r.trim().toLowerCase())
        .where((s) => s.isNotEmpty && s != '(empty / unassigned)')
        .toSet();

    final mainLineResourcePicks = await getMainLineResourcePicks();
    final mainLinePicksSet = mainLineResourcePicks.map((r) => r.trim().toLowerCase()).toSet();
    final isMainLineEmptyPick = mainLineResourcePicks.contains('(Empty / Unassigned)');

    final db = await database;
    final missingRows = await db.query(
      'part_flags',
      columns: ['part_id', 'department'],
      where: 'unit_id = ? AND UPPER(flag_type) = "MISSING"',
      whereArgs: [unitId],
    );
    final missingSet = missingRows.map((r) => '${r['department']}__${r['part_id']}').toSet();

    final deptGroups = <String, List<PicklistItem>>{};
    for (final i in allItems) {
      deptGroups.putIfAbsent(i.department, () => []).add(i);
    }

    final result = <String, UnitPickDateUrgency>{};

    for (final entry in deptGroups.entries) {
      final dept = entry.key;
      final isMainLineDept = dept.toUpperCase().contains('MAIN') || dept.toUpperCase().contains('MACG');

      final unblockedItems = entry.value.where((i) {
        final cr = i.componentResourceId.trim().toLowerCase();
        if (cr.isEmpty) {
          if (isBlockedEmpty) return false;
        } else {
          if (blockedResSet.contains(cr)) return false;
        }
        if (isMainLineDept && mainLineResourcePicks.isNotEmpty) {
          final r = i.resourceId.trim().toLowerCase();
          if (r.isEmpty && isMainLineEmptyPick) return false;
          if (r.isNotEmpty && mainLinePicksSet.contains(r)) return false;
        }
        return true;
      }).toList();

      if (unblockedItems.isEmpty) {
        result[dept] = UnitPickDateUrgency.evaluate(
          dateStr: null,
          department: dept,
          isAllCompleted: true,
          referenceToday: referenceToday,
        );
        continue;
      }

      final incompleteItems = unblockedItems.where((i) {
        if (i.qtyDue <= 0.0001) return false;
        if (missingSet.contains('${dept}__${i.partId}')) return false;
        return true;
      }).toList();

      final isDeptCompleted = incompleteItems.isEmpty;
      String? rawDate;
      for (final i in unblockedItems) {
        if (i.pickDate.trim().isNotEmpty) {
          rawDate = i.pickDate.trim();
          break;
        }
      }

      result[dept] = UnitPickDateUrgency.evaluate(
        dateStr: rawDate,
        department: dept,
        isAllCompleted: isDeptCompleted,
        referenceToday: referenceToday,
      );
    }

    return result;
  }

  // --- ADDITIONAL CONFIG HELPERS ---

  Future<bool> getAutoAdvancePick() async {
    final val = await getConfig('auto_advance_pick');
    return val == '1' || val == 'true';
  }

  Future<void> setAutoAdvancePick(bool val) async {
    await setConfig('auto_advance_pick', val ? '1' : '0');
  }

  Future<bool> getGroupByLine() async {
    final val = await getConfig('group_by_line');
    if (val == null) return true; // default true
    return val == '1' || val == 'true';
  }

  Future<void> setGroupByLine(bool val) async {
    await setConfig('group_by_line', val ? '1' : '0');
  }

  Future<Map<String, bool>> getLineGroupingDeptOverrides() async {
    final val = await getConfig('line_grouping_dept_overrides');
    if (val != null && val.isNotEmpty) {
      try {
        final decoded = jsonDecode(val) as Map<String, dynamic>;
        return decoded.map((k, v) => MapEntry(k, v == true));
      } catch (_) {}
    }
    return {};
  }

  Future<void> setLineGroupingDeptOverride(String dept, bool enabled) async {
    final map = await getLineGroupingDeptOverrides();
    map[dept] = enabled;
    await setConfig('line_grouping_dept_overrides', jsonEncode(map));
  }

  Future<Map<String, bool>> getLineGroupingResourceOverrides() async {
    final val = await getConfig('line_grouping_resource_overrides');
    if (val != null && val.isNotEmpty) {
      try {
        final decoded = jsonDecode(val) as Map<String, dynamic>;
        return decoded.map((k, v) => MapEntry(k, v == true));
      } catch (_) {}
    }
    return {};
  }

  Future<void> setLineGroupingResourceOverride(String resource, bool enabled) async {
    final map = await getLineGroupingResourceOverrides();
    map[resource] = enabled;
    await setConfig('line_grouping_resource_overrides', jsonEncode(map));
  }

  Future<bool> shouldGroupByLineForDept(String dept) async {
    final overrides = await getLineGroupingDeptOverrides();
    if (overrides.containsKey(dept)) return overrides[dept]!;
    return await getGroupByLine();
  }

  Future<bool> shouldGroupByLineForResource(String resource) async {
    final overrides = await getLineGroupingResourceOverrides();
    if (overrides.containsKey(resource)) return overrides[resource]!;
    return await getGroupByLine();
  }

  // --- KNOWN DISCOVERED CATALOGS & AUTO-REGISTRATION ---

  Future<List<String>> getKnownComponentResources() async {
    final val = await getConfig('known_component_resources');
    if (val != null && val.isNotEmpty) {
      try {
        return (jsonDecode(val) as List).map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> recordKnownComponentResources(List<String> resources) async {
    final current = await getKnownComponentResources();
    final set = current.toSet();
    set.addAll(resources.map((s) => s.trim()).where((s) => s.isNotEmpty && s != '(Empty / Unassigned)'));
    await setConfig('known_component_resources', jsonEncode(set.toList()));
  }

  Future<List<String>> getKnownMainLineResources() async {
    final val = await getConfig('known_main_line_resources');
    if (val != null && val.isNotEmpty) {
      try {
        return (jsonDecode(val) as List).map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> recordKnownMainLineResources(List<String> resources) async {
    final current = await getKnownMainLineResources();
    final set = current.toSet();
    set.addAll(resources.map((s) => s.trim()).where((s) => s.isNotEmpty && s != '(Empty / Unassigned)'));
    await setConfig('known_main_line_resources', jsonEncode(set.toList()));
  }

  Future<List<String>> getKnownDepartments() async {
    final val = await getConfig('known_departments');
    if (val != null && val.isNotEmpty) {
      try {
        return (jsonDecode(val) as List).map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> recordKnownDepartments(List<String> departments) async {
    final current = await getKnownDepartments();
    final set = current.toSet();
    set.addAll(departments.map((s) => s.trim()).where((s) => s.isNotEmpty && s != '(Empty / Unassigned)'));
    await setConfig('known_departments', jsonEncode(set.toList()));
  }

  /// Automatically registers and persists any new departments, component resources,
  /// or MAIN LINE destination resources found in an imported picklist.
  ///
  /// Returns a map of newly discovered items:
  /// {
  ///   'departments': [...],
  ///   'component_resources': [...],
  ///   'main_line_resources': [...],
  /// }
  Future<Map<String, List<String>>> registerDiscoveredPicklistItems({
    required List<String> departments,
    required List<String> componentResources,
    required List<String> mainLineResources,
  }) async {
    final existingDepts = (await getAllDistinctDepartments()).map((s) => s.trim().toLowerCase()).toSet();
    final existingCompRes = (await getAllDistinctComponentResourceIds()).map((s) => s.trim().toLowerCase()).toSet();
    final existingMainLine = (await getMainLineDistinctResourceIds()).map((s) => s.trim().toLowerCase()).toSet();

    final newDepts = <String>[];
    final seenDepts = <String>{};
    for (final d in departments) {
      final trimmed = d.trim();
      final lower = trimmed.toLowerCase();
      if (trimmed.isNotEmpty &&
          trimmed != '(Empty / Unassigned)' &&
          !existingDepts.contains(lower) &&
          seenDepts.add(lower)) {
        newDepts.add(trimmed);
      }
    }

    final newCompRes = <String>[];
    final seenCompRes = <String>{};
    for (final cr in componentResources) {
      final trimmed = cr.trim();
      final lower = trimmed.toLowerCase();
      if (trimmed.isNotEmpty &&
          trimmed != '(Empty / Unassigned)' &&
          !existingCompRes.contains(lower) &&
          seenCompRes.add(lower)) {
        newCompRes.add(trimmed);
      }
    }

    final newMainLine = <String>[];
    final seenMainLine = <String>{};
    for (final ml in mainLineResources) {
      final trimmed = ml.trim();
      final lower = trimmed.toLowerCase();
      if (trimmed.isNotEmpty &&
          trimmed != '(Empty / Unassigned)' &&
          !existingMainLine.contains(lower) &&
          seenMainLine.add(lower)) {
        newMainLine.add(trimmed);
      }
    }

    if (newDepts.isNotEmpty) {
      await recordKnownDepartments(newDepts);
    }
    if (newCompRes.isNotEmpty) {
      await recordKnownComponentResources(newCompRes);
    }
    if (newMainLine.isNotEmpty) {
      await recordKnownMainLineResources(newMainLine);
    }

    return {
      'departments': newDepts,
      'component_resources': newCompRes,
      'main_line_resources': newMainLine,
    };
  }

  /// Scans all picklist_items in the database, backfills any missing component_resource_id
  /// using raw_columns (for files imported with legacy mappings), and synchronizes all
  /// distinct departments, component resources, and MAIN LINE resources into known catalogs.
  Future<Map<String, int>> syncAllKnownCatalogs(ColumnMapper mapper) async {
    final db = await database;

    // 1. Backfill component_resource_id from raw_columns for rows where it is empty
    final emptyRows = await db.query(
      'picklist_items',
      columns: ['id', 'raw_columns'],
      where: "(component_resource_id IS NULL OR TRIM(component_resource_id) = '') AND raw_columns IS NOT NULL AND TRIM(raw_columns) != '' AND raw_columns != '{}'",
    );

    int backfilledCount = 0;
    final newlyDiscoveredCompRes = <String>{};

    if (emptyRows.isNotEmpty) {
      final batch = db.batch();
      for (final row in emptyRows) {
        final id = row['id'] as String;
        final rawStr = row['raw_columns'] as String;
        try {
          final rawMap = jsonDecode(rawStr) as Map<String, dynamic>;
          String foundValue = '';
          for (final entry in rawMap.entries) {
            final identified = mapper.identifyColumn(entry.key);
            if (identified == ColumnMapper.keyComponentResourceId) {
              final val = entry.value?.toString().trim() ?? '';
              if (val.isNotEmpty) {
                foundValue = val;
                break;
              }
            }
          }
          if (foundValue.isNotEmpty) {
            batch.update(
              'picklist_items',
              {'component_resource_id': foundValue},
              where: 'id = ?',
              whereArgs: [id],
            );
            newlyDiscoveredCompRes.add(foundValue);
            backfilledCount++;
          }
        } catch (_) {}
      }

      if (backfilledCount > 0) {
        await batch.commit(noResult: true);
        if (newlyDiscoveredCompRes.isNotEmpty) {
          await recordKnownComponentResources(newlyDiscoveredCompRes.toList());
        }
      }
    }

    // 2. Backfill on_hand from raw_columns for rows where it is empty
    final emptyOnHandRows = await db.query(
      'picklist_items',
      columns: ['id', 'raw_columns'],
      where: "(on_hand IS NULL OR TRIM(on_hand) = '') AND raw_columns IS NOT NULL AND TRIM(raw_columns) != '' AND raw_columns != '{}'",
    );

    int backfilledOnHandCount = 0;
    if (emptyOnHandRows.isNotEmpty) {
      final batch = db.batch();
      for (final row in emptyOnHandRows) {
        final id = row['id'] as String;
        final rawStr = row['raw_columns'] as String;
        try {
          final rawMap = jsonDecode(rawStr) as Map<String, dynamic>;
          String foundOnHand = '';
            for (final entry in rawMap.entries) {
            final key = entry.key;
            final identified = mapper.identifyColumn(key);
            final norm = ColumnMapper.normalize(key);
            if (identified == ColumnMapper.keyOnHand ||
                norm == 'ON HAND' ||
                norm.contains('ON HAND') ||
                norm.contains('ONHAND') ||
                norm.contains('LOCATION') ||
                norm.contains('BIN') ||
                norm.contains('STOCK') ||
                norm.contains('INVENTORY') ||
                norm == 'LOC' ||
                norm == 'OH') {
              final val = entry.value?.toString().trim() ?? '';
              if (val.isNotEmpty && val.toLowerCase() != 'null') {
                foundOnHand = val;
                break;
              }
            }
          }
          if (foundOnHand.isNotEmpty) {
            batch.update(
              'picklist_items',
              {'on_hand': foundOnHand},
              where: 'id = ?',
              whereArgs: [id],
            );
            backfilledOnHandCount++;
          }
        } catch (_) {}
      }

      if (backfilledOnHandCount > 0) {
        await batch.commit(noResult: true);
      }
    }

    // 3. Discover departments across all units
    final allDepts = await getAllDistinctDepartments();
    if (allDepts.isNotEmpty) {
      await recordKnownDepartments(allDepts);
    }

    // 3. Discover component resources across all units
    final allCompRes = await getAllDistinctComponentResourceIds();
    if (allCompRes.isNotEmpty) {
      await recordKnownComponentResources(allCompRes);
    }

    // 4. Discover MAIN LINE resources across all units
    final allMainLine = await getMainLineDistinctResourceIds();
    if (allMainLine.isNotEmpty) {
      await recordKnownMainLineResources(allMainLine);
    }

    return {
      'backfilledItems': backfilledCount,
      'departments': allDepts.length,
      'componentResources': allCompRes.length,
      'mainLineResources': allMainLine.length,
    };
  }

  Future<List<String>> getAllDistinctComponentResourceIds() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT DISTINCT component_resource_id FROM picklist_items WHERE component_resource_id IS NOT NULL AND TRIM(component_resource_id) != '' ORDER BY component_resource_id ASC",
    );
    final set = rows.map((r) => (r['component_resource_id'] as String).trim()).where((s) => s.isNotEmpty).toSet();
    final knownList = await getKnownComponentResources();
    set.addAll(knownList);
    final autoIssueList = await getAutoIssueResourceIds();
    set.addAll(autoIssueList);
    final blockedList = await getBlockedResourceIds();
    set.addAll(blockedList);
    // Always include (Empty / Unassigned) so admin can always configure it
    set.add('(Empty / Unassigned)');
    final list = set.toList();
    list.sort((a, b) {
      if (a == '(Empty / Unassigned)') return 1;
      if (b == '(Empty / Unassigned)') return -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return list;
  }

  Future<List<String>> _getRawDistinctComponentResourceNames() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT DISTINCT component_resource_id FROM picklist_items WHERE component_resource_id IS NOT NULL AND TRIM(component_resource_id) != ''",
    );
    final list = rows.map((r) => (r['component_resource_id'] as String).trim()).where((s) => s.isNotEmpty).toList();
    final knownList = await getKnownComponentResources();
    list.addAll(knownList);
    list.add('(Empty / Unassigned)');
    return list.toSet().toList();
  }

  Future<List<String>> getAllDistinctResourceIds() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT DISTINCT resource_id FROM picklist_items WHERE resource_id IS NOT NULL AND TRIM(resource_id) != '' ORDER BY resource_id ASC",
    );
    final set = rows.map((r) => (r['resource_id'] as String).trim()).where((s) => s.isNotEmpty).toSet();
    final autoIssueList = await getAutoIssueResourceIds();
    set.addAll(autoIssueList);
    final blockedList = await getBlockedResourceIds();
    set.addAll(blockedList);
    // Always include (Empty / Unassigned) so admin can always configure it
    set.add('(Empty / Unassigned)');
    final list = set.toList();
    list.sort((a, b) {
      if (a == '(Empty / Unassigned)') return 1;
      if (b == '(Empty / Unassigned)') return -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return list;
  }

  Future<List<String>> getBlockedResourceIds() async {
    final val = await getConfig('blocked_resource_ids');
    final set = <String>{};
    if (val != null && val.isNotEmpty) {
      try {
        final list = jsonDecode(val) as List;
        set.addAll(list.map((e) => e.toString().trim()).where((s) => s.isNotEmpty));
      } catch (_) {}
    }

    // Include resources matching any blocked pattern rules
    final rules = await getResourcePatternRules();
    if (rules.isNotEmpty) {
      final allRes = await _getRawDistinctComponentResourceNames();
      for (final rule in rules) {
        final pat = (rule['pattern']?.toString() ?? '').trim().toLowerCase();
        final allowPick = rule['allowPick'] == true;
        if (pat.isNotEmpty && !allowPick) {
          for (final res in allRes) {
            if (res.toLowerCase().contains(pat)) {
              set.add(res);
            }
          }
        }
      }
    }
    return set.toList();
  }

  Future<void> setBlockedResourceIds(List<String> list) async {
    await setConfig('blocked_resource_ids', jsonEncode(list));
  }

  Future<List<String>> getAutoIssueComponents() async {
    final val = await getConfig('auto_issue_components');
    if (val != null && val.isNotEmpty) {
      try {
        final list = jsonDecode(val) as List;
        return list.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> setAutoIssueComponents(List<String> list) async {
    await setConfig('auto_issue_components', jsonEncode(list));
  }

  Future<List<String>> getAutoIssueResourceIds() async {
    final val = await getConfig('auto_issue_resource_ids');
    final set = <String>{};
    if (val != null && val.isNotEmpty) {
      try {
        final list = jsonDecode(val) as List;
        set.addAll(list.map((e) => e.toString().trim()).where((s) => s.isNotEmpty));
      } catch (_) {}
    }

    // Include resources matching any auto-issue pattern rules
    final rules = await getResourcePatternRules();
    if (rules.isNotEmpty) {
      final allRes = await _getRawDistinctComponentResourceNames();
      for (final rule in rules) {
        final pat = (rule['pattern']?.toString() ?? '').trim().toLowerCase();
        final autoIssue = rule['autoIssue'] == true;
        if (pat.isNotEmpty && autoIssue) {
          for (final res in allRes) {
            if (res.toLowerCase().contains(pat)) {
              set.add(res);
            }
          }
        }
      }
    }

    // Enforce dependency rule: blocked resources cannot be auto-issued
    final blocked = await getBlockedResourceIds();
    set.removeWhere((r) => blocked.contains(r));

    return set.toList();
  }

  Future<void> setAutoIssueResourceIds(List<String> list) async {
    await setConfig('auto_issue_resource_ids', jsonEncode(list));
  }


  Future<List<Map<String, dynamic>>> getResourcePatternRules() async {
    final val = await getConfig('component_resource_pattern_rules');
    if (val != null && val.isNotEmpty) {
      try {
        final decoded = jsonDecode(val) as List;
        return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> setResourcePatternRules(List<Map<String, dynamic>> rules) async {
    await setConfig('component_resource_pattern_rules', jsonEncode(rules));
  }

  // --- SESSION PICKS TRACKING ---

  Future<void> recordSessionPick({
    required String sessionId,
    required String unitId,
    required String itemId,
    required String partId,
    required double qtyPickedDelta,
  }) async {
    if (qtyPickedDelta <= 0) return;
    final db = await database;
    final id = '${sessionId}_${itemId}_${DateTime.now().microsecondsSinceEpoch}';
    await db.insert(
      'session_picks',
      {
        'id': id,
        'session_id': sessionId,
        'unit_id': unitId,
        'item_id': itemId,
        'part_id': partId,
        'qty_picked': qtyPickedDelta,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Set<String>> getSessionPickedPartIds(String sessionId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT part_id FROM session_picks WHERE session_id = ? AND qty_picked > 0.0001',
      [sessionId],
    );
    return rows.map((r) => r['part_id'].toString()).where((s) => s.isNotEmpty).toSet();
  }

  Future<int> getSessionPickedPartCount(String sessionId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT part_id) as cnt FROM session_picks WHERE session_id = ? AND qty_picked > 0.0001',
      [sessionId],
    );
    return (rows.first['cnt'] as num?)?.toInt() ?? 0;
  }

  /// Returns all distinct Part IDs picked across a given list of sessions.
  Future<Set<String>> getBatchPickedPartIds(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(sessionIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT DISTINCT part_id FROM session_picks WHERE session_id IN ($placeholders) AND qty_picked > 0.0001',
      sessionIds,
    );
    return rows.map((r) => r['part_id'].toString()).where((s) => s.isNotEmpty).toSet();
  }

  /// Returns distinct Part IDs picked across a given list of sessions for a specific unit.
  Future<Set<String>> getBatchPickedPartIdsForUnit(List<String> sessionIds, String unitId) async {
    if (sessionIds.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(sessionIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT DISTINCT part_id FROM session_picks WHERE session_id IN ($placeholders) AND unit_id = ? AND qty_picked > 0.0001',
      [...sessionIds, unitId],
    );
    return rows.map((r) => r['part_id'].toString()).where((s) => s.isNotEmpty).toSet();
  }

  /// Synchronizes total_items_picked in sessions table with actual session_picks count.
  /// Fixes any sessions where unit-wide total was accidentally assigned.
  Future<void> syncSessionPicksCounts() async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE sessions
      SET total_items_picked = (
        SELECT COUNT(DISTINCT part_id)
        FROM session_picks
        WHERE session_picks.session_id = sessions.id AND session_picks.qty_picked > 0.0001
      )
    ''');
  }

  /// List of Resource IDs configured to be picked across all MAIN LINE departments.
  Future<List<String>> getMainLineResourcePicks() async {
    final val = await getConfig('main_line_resource_picks');
    if (val != null && val.isNotEmpty) {
      try {
        final list = jsonDecode(val) as List;
        return list.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> setMainLineResourcePicks(List<String> list) async {
    await setConfig('main_line_resource_picks', jsonEncode(list));
  }

  /// Returns distinct Resource IDs found within MAIN LINE departments.
  Future<List<String>> getMainLineDistinctResourceIds([String? unitId]) async {
    final db = await database;
    final where = unitId != null
        ? "unit_id = ? AND (UPPER(dept_type) = 'MAIN LINE' OR UPPER(department) LIKE '%MAIN%' OR UPPER(department) LIKE '%MACG%')"
        : "(UPPER(dept_type) = 'MAIN LINE' OR UPPER(department) LIKE '%MAIN%' OR UPPER(department) LIKE '%MACG%')";
    final args = unitId != null ? [unitId] : null;
    final rows = await db.rawQuery("SELECT DISTINCT resource_id FROM picklist_items WHERE $where", args);
    final set = <String>{};
    bool hasEmpty = false;
    for (final r in rows) {
      final res = r['resource_id']?.toString().trim() ?? '';
      if (res.isEmpty) {
        hasEmpty = true;
      } else {
        set.add(res);
      }
    }
    if (unitId == null) {
      final known = await getKnownMainLineResources();
      set.addAll(known);
    }
    final sortedList = set.toList();
    sortedList.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (hasEmpty) {
      sortedList.add('(Empty / Unassigned)');
    }
    return sortedList;
  }

  /// Returns a map of Resource ID -> view mode ('combined' or 'split_by_dept')
  Future<Map<String, String>> getMainLineResourceViewOverrides() async {
    final val = await getConfig('mainline_resource_views');
    if (val != null && val.isNotEmpty) {
      try {
        final decoded = jsonDecode(val) as Map<String, dynamic>;
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      } catch (_) {}
    }
    return {};
  }

  /// Sets the preferred tree view mode for a specific MAIN LINE Resource ID ('combined' or 'split_by_dept').
  Future<void> setMainLineResourceView(String resId, String viewMode) async {
    final map = await getMainLineResourceViewOverrides();
    map[resId] = viewMode;
    await setConfig('mainline_resource_views', jsonEncode(map));
  }

  /// Resolves the tree view mode for a specific MAIN LINE Resource ID.
  /// Checks per-resource override first; falls back to global default ('combined').
  Future<String> getMainLineResourceView(String resId) async {
    final map = await getMainLineResourceViewOverrides();
    if (map.containsKey(resId)) {
      return map[resId]!;
    }
    final globalDef = await getConfig('mainline_resource_default_view');
    return globalDef ?? 'combined';
  }

  /// Checks whether Auto-Issue items have already been exported to Excel for this unit.
  Future<bool> isUnitAutoIssueExported(String unitId) async {
    final val = await getConfig('auto_issue_exported_$unitId');
    return val == 'true';
  }

  /// Records whether Auto-Issue items have been exported to Excel for this unit.
  Future<void> setUnitAutoIssueExported(String unitId, [bool exported = true]) async {
    await setConfig('auto_issue_exported_$unitId', exported ? 'true' : 'false');
  }

  Future<String?> getLastExportDir() async {
    return await getConfig('last_export_dir');
  }

  Future<void> setLastExportDir(String dir) async {
    await setConfig('last_export_dir', dir);
  }

  Future<bool> verifyAdminPin(String enteredPin) async {
    final pin = await getConfig('admin_pin') ?? '1234';
    return enteredPin.trim() == pin.trim();
  }

  Future<void> insertPickReturn({
    required String sessionId,
    required String unitId,
    required String workerName,
    required String partId,
    required String department,
    required double qtyReturned,
    required String comment,
    String? workOrder,
  }) async {
    final db = await database;
    await db.insert('pick_returns', {
      'id': 'ret_${DateTime.now().millisecondsSinceEpoch}',
      'session_id': sessionId,
      'unit_id': unitId,
      'worker_name': workerName,
      'part_id': partId,
      'department': department,
      'qty_returned': qtyReturned,
      'comment': comment,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // --- SYSTEM LOGS OPERATIONS ---

  @override
  Future<void> insertLog({
    required int timestamp,
    required String level,
    required String tag,
    required String message,
    String stackTrace = '',
  }) async {
    final db = await database;
    await db.insert('app_logs', {
      'timestamp': timestamp,
      'level': level.toUpperCase(),
      'tag': tag,
      'message': message,
      'stack_trace': stackTrace,
    });
  }

  Future<List<Map<String, dynamic>>> getLogs({
    String? level,
    String? search,
    int limit = 200,
    int offset = 0,
  }) async {
    final db = await database;
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (level != null && level.isNotEmpty && level.toUpperCase() != 'ALL') {
      if (level.toUpperCase() == 'PICKER' || level.toUpperCase() == 'ADMIN') {
        whereClauses.add('UPPER(tag) = ?');
        whereArgs.add(level.toUpperCase());
      } else {
        whereClauses.add('level = ?');
        whereArgs.add(level.toUpperCase());
      }
    }

    if (search != null && search.trim().isNotEmpty) {
      whereClauses.add('(tag LIKE ? OR message LIKE ? OR stack_trace LIKE ?)');
      final term = '%${search.trim()}%';
      whereArgs.addAll([term, term, term]);
    }

    final where = whereClauses.isNotEmpty ? whereClauses.join(' AND ') : null;

    return await db.query(
      'app_logs',
      where: where,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>> getLogsStats() async {
    final db = await database;
    final countRes = await db.rawQuery('SELECT COUNT(*) as cnt FROM app_logs');
    final count = (countRes.first['cnt'] as num?)?.toInt() ?? 0;

    final sizeRes = await db.rawQuery(
      'SELECT SUM(LENGTH(tag) + LENGTH(message) + LENGTH(stack_trace) + 64) as total_size FROM app_logs',
    );
    final sizeBytes = (sizeRes.first['total_size'] as num?)?.toInt() ?? 0;

    return {
      'count': count,
      'sizeBytes': sizeBytes,
    };
  }

  @override
  Future<int> pruneOldestLogs(int countToPrune) async {
    final db = await database;
    return await db.rawDelete('''
      DELETE FROM app_logs
      WHERE id IN (
        SELECT id FROM app_logs ORDER BY timestamp ASC LIMIT ?
      )
    ''', [countToPrune]);
  }

  Future<int> purgeLogsOlderThanDays(int days) async {
    final db = await database;
    final cutoff = DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    return await db.delete(
      'app_logs',
      where: 'timestamp < ?',
      whereArgs: [cutoff],
    );
  }

  Future<void> clearAllLogs() async {
    final db = await database;
    await db.delete('app_logs');
  }

  @override
  Future<List<Map<String, dynamic>>> getAllLogsForExport() async {
    final db = await database;
    return await db.query(
      'app_logs',
      orderBy: 'timestamp ASC',
    );
  }
}
