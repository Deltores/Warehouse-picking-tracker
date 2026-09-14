import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/picklist_item.dart';
import '../models/session_metadata.dart';
import '../models/unit_pick_date_urgency.dart';
import '../models/unit_record.dart';
import 'log_service.dart';

class DatabaseService implements LogDatabase {
  static Database? _database;
  static DatabaseFactory? _ffiFactory;

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
        version: 8,
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
        deleted_at INTEGER
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
        on_hand TEXT NOT NULL DEFAULT '',
        dept_type TEXT NOT NULL DEFAULT '',
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
        issued_status TEXT NOT NULL DEFAULT 'Pending',
        total_items_picked INTEGER NOT NULL DEFAULT 0,
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
        await txn.delete('sessions', where: 'unit_id = ?', whereArgs: [uid]);
        await txn.delete('units', where: 'id = ?', whereArgs: [uid]);
      });
      purgedCount++;
    }
    return purgedCount;
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

  /// Returns all distinct departments globally and their active status (allowed for picking).
  /// Any department not explicitly blocked in admin_config defaults to true (allowed).
  Future<Map<String, bool>> getGlobalDepartments() async {
    final allDepts = await getAllDistinctDepartments();
    final db = await database;

    final blockedJson = await getConfig('blocked_departments');
    final blockedSet = <String>{};
    if (blockedJson != null) {
      try {
        final list = (json.decode(blockedJson) as List).map((e) => e.toString()).toSet();
        blockedSet.addAll(list);
      } catch (_) {}
    }

    final inactiveRows = await db.query(
      'departments',
      columns: ['name'],
      where: 'is_active = 0',
    );
    for (final r in inactiveRows) {
      final n = r['name']?.toString().trim();
      if (n != null && n.isNotEmpty) blockedSet.add(n);
    }

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
  Future<void> finishSession(String sessionId, int endTime, int totalPicked, String issuedStatus) async {
    final db = await database;
    await db.update(
      'sessions',
      {
        'end_time': endTime,
        'status': 'EXPORTED',
        'issued_status': issuedStatus,
        'total_items_picked': totalPicked,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Marks a session as CLOSED — picker has finished their shift but has not yet exported.
  /// CLOSED sessions appear in the export list and block re-opening.
  Future<void> closeSession(String sessionId, int endTime, int totalPicked) async {
    final db = await database;
    await db.update(
      'sessions',
      {
        'end_time': endTime,
        'status': 'CLOSED',
        'total_items_picked': totalPicked,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Closes all active or open sessions across all units.
  Future<void> closeAllActiveSessions({int? endTime}) async {
    final db = await database;
    final now = endTime ?? DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'sessions',
      {
        'end_time': now,
        'status': 'CLOSED',
      },
      where: 'status = ? OR status = ?',
      whereArgs: ['ACTIVE', 'OPEN'],
    );
  }

  /// Admin action: mark a CLOSED or EXPORTED session as ISSUED.
  Future<void> updateSessionIssuedStatus(String sessionId, String status) async {
    final db = await database;
    await db.update(
      'sessions',
      {'status': status, 'issued_status': status == 'ISSUED' ? 'Issued' : 'Pending'},
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
    await db.delete('sessions', where: 'id = ? AND total_items_picked = 0', whereArgs: [sessionId]);
  }

  /// Returns next sequential session number for a unit (1..9999 wrapping).
  /// Monotonically increases and never decrements even if previous sessions are deleted.
  Future<int> nextSessionSeqNo(String unitId) async {
    final db = await database;
    final configKey = 'last_seq_no_$unitId';
    final savedValStr = await getConfig(configKey);
    final savedVal = int.tryParse(savedValStr ?? '') ?? 0;

    final result = await db.rawQuery(
      'SELECT MAX(session_seq_no) as mx FROM sessions WHERE unit_id = ?',
      [unitId],
    );
    final dbMax = (result.first['mx'] as num?)?.toInt() ?? 0;

    final current = savedVal > dbMax ? savedVal : dbMax;
    final next = current >= 9999 ? 1 : current + 1;

    await setConfig(configKey, next.toString());
    return next;
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

  /// Returns all sessions across all units that are CLOSED or FINISHED with picks > 0.
  /// Used by the session export screen.
  Future<List<SessionMetadata>> getExportableSessionsForUnit(String unitId) async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'unit_id = ? AND total_items_picked > 0 AND (status = ? OR status = ?)',
      whereArgs: [unitId, 'CLOSED', 'FINISHED'],
      orderBy: 'start_time DESC',
    );
    return maps.map((m) => SessionMetadata.fromMap(m)).toList();
  }

  /// Returns all sessions across ALL units that are CLOSED/EXPORTED/ISSUED with picks > 0.
  Future<List<SessionMetadata>> getAllExportableSessions() async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: "total_items_picked > 0 AND (status = 'CLOSED' OR status = 'EXPORTED' OR status = 'FINISHED' OR status = 'ISSUED')",
      orderBy: 'start_time DESC',
    );
    return maps.map((m) => SessionMetadata.fromMap(m)).toList();
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

  /// Cleans up any MISSING part_flags for parts that have been fully picked (qty_due <= 0.0001).
  Future<int> cleanupResolvedMissingFlags(String unitId) async {
    final db = await database;
    return await db.rawDelete('''
      DELETE FROM part_flags
      WHERE unit_id = ? AND UPPER(flag_type) = 'MISSING'
        AND part_id IN (
          SELECT part_id FROM picklist_items WHERE unit_id = ? GROUP BY part_id HAVING SUM(qty_due) <= 0.0001
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

  /// Calculates progress by unique Part IDs for the given unit.
  /// Returns a Map with 'totalParts' and 'completedParts'.
  Future<Map<String, int>> getUnitPartProgress(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT part_id, SUM(qty_due) as total_due
      FROM picklist_items
      WHERE unit_id = ?
      GROUP BY part_id
    ''', [unitId]);

    final totalParts = rows.length;
    final completedParts = rows.where((r) {
      final due = (r['total_due'] as num?)?.toDouble() ?? 0.0;
      return due <= 0.0001;
    }).length;

    return {
      'totalParts': totalParts,
      'completedParts': completedParts,
    };
  }

  /// Calculates progress by unique Part IDs for the given department in a unit.
  /// Returns a Map with 'totalParts', 'completedParts', and 'missingParts'.
  Future<Map<String, int>> getDepartmentPartProgress(String unitId, String department) async {
    await cleanupResolvedMissingFlags(unitId);
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT part_id, SUM(qty_due) as total_due
      FROM picklist_items
      WHERE unit_id = ? AND department = ?
      GROUP BY part_id
    ''', [unitId, department]);

    final totalParts = rows.length;
    final completedParts = rows.where((r) {
      final due = (r['total_due'] as num?)?.toDouble() ?? 0.0;
      return due <= 0.0001;
    }).length;

    // Count parts flagged as MISSING that are still incomplete (qty_due > 0.0001)
    final missingRows = await db.rawQuery('''
      SELECT DISTINCT part_id
      FROM part_flags
      WHERE unit_id = ? AND department = ? AND UPPER(flag_type) = 'MISSING'
        AND part_id IN (
          SELECT part_id FROM picklist_items WHERE unit_id = ? AND department = ? GROUP BY part_id HAVING SUM(qty_due) > 0.0001
        )
    ''', [unitId, department, unitId, department]);

    final missingParts = missingRows.length;

    return {
      'totalParts': totalParts,
      'completedParts': completedParts,
      'missingParts': missingParts,
    };
  }

  /// Returns the earliest incomplete pick date urgency for a unit.
  /// Parts marked as MISSING in part_flags are excluded (they do not block completion).
  /// If all non-missing parts are picked, returns status = completed.
  /// Compares with today:
  /// - < 0 days (past due date) -> Glow RED
  /// - 0..2 days -> Glow YELLOW
  /// - > 2 days -> Glow GREEN
  Future<UnitPickDateUrgency?> getUnitEarliestIncompletePickDate(
    String unitId, {
    DateTime? referenceToday,
  }) async {
    final db = await database;

    // Check if unit has any items
    final totalItemsCount = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM picklist_items WHERE unit_id = ?',
        [unitId],
      ),
    ) ?? 0;

    if (totalItemsCount == 0) return null;

    // Check if there are any incomplete non-missing items in the unit
    final incompleteRows = await db.rawQuery('''
      SELECT DISTINCT department
      FROM picklist_items
      WHERE unit_id = ?
        AND qty_due > 0.0001
        AND part_id NOT IN (
          SELECT part_id FROM part_flags WHERE unit_id = ? AND UPPER(flag_type) = 'MISSING'
        )
    ''', [unitId, unitId]);

    // If no incomplete items, unit is 100% completed
    if (incompleteRows.isEmpty) {
      return UnitPickDateUrgency.evaluate(
        dateStr: null,
        department: null,
        isAllCompleted: true,
        referenceToday: referenceToday,
      );
    }

    final incompleteDepts = incompleteRows
        .map((r) => r['department']?.toString() ?? '')
        .where((d) => d.isNotEmpty)
        .toList();

    // For each incomplete department, find its pick_date
    String? earliestDateStr;
    DateTime? earliestParsedDate;
    String? earliestDept;

    for (final dept in incompleteDepts) {
      final dateRow = await db.rawQuery('''
        SELECT pick_date
        FROM picklist_items
        WHERE unit_id = ? AND department = ? AND pick_date IS NOT NULL AND TRIM(pick_date) != ''
        LIMIT 1
      ''', [unitId, dept]);

      if (dateRow.isNotEmpty) {
        final rawDate = dateRow.first['pick_date']?.toString() ?? '';
        final parsed = UnitPickDateUrgency.parseDateRobust(rawDate);
        if (parsed != null) {
          if (earliestParsedDate == null || parsed.isBefore(earliestParsedDate)) {
            earliestParsedDate = parsed;
            earliestDateStr = rawDate;
            earliestDept = dept;
          }
        } else if (earliestDateStr == null) {
          earliestDateStr = rawDate;
          earliestDept = dept;
        }
      }
    }

    if (earliestDateStr == null && incompleteDepts.isNotEmpty) {
      earliestDept = incompleteDepts.first;
    }

    return UnitPickDateUrgency.evaluate(
      dateStr: earliestDateStr,
      department: earliestDept,
      isAllCompleted: false,
      referenceToday: referenceToday,
    );
  }

  /// Returns a map of department -> UnitPickDateUrgency for all departments in a unit.
  /// Excludes MISSING parts from blocking department completion.
  Future<Map<String, UnitPickDateUrgency>> getDepartmentPickDates(
    String unitId, {
    DateTime? referenceToday,
  }) async {
    final db = await database;

    final deptRows = await db.rawQuery('''
      SELECT DISTINCT department
      FROM picklist_items
      WHERE unit_id = ?
    ''', [unitId]);

    final result = <String, UnitPickDateUrgency>{};

    for (final r in deptRows) {
      final dept = r['department']?.toString() ?? '';
      if (dept.isEmpty) continue;

      // Check if department has unpicked non-missing items
      final incompleteCount = Sqflite.firstIntValue(
        await db.rawQuery('''
          SELECT COUNT(*)
          FROM picklist_items
          WHERE unit_id = ?
            AND department = ?
            AND qty_due > 0.0001
            AND part_id NOT IN (
              SELECT part_id FROM part_flags WHERE unit_id = ? AND UPPER(flag_type) = 'MISSING'
            )
        ''', [unitId, dept, unitId]),
      ) ?? 0;

      final isDeptCompleted = incompleteCount == 0;

      // Get department pick_date
      final dateRow = await db.rawQuery('''
        SELECT pick_date
        FROM picklist_items
        WHERE unit_id = ? AND department = ? AND pick_date IS NOT NULL AND TRIM(pick_date) != ''
        LIMIT 1
      ''', [unitId, dept]);

      final rawDate = dateRow.isNotEmpty ? dateRow.first['pick_date']?.toString() : null;

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
    if (val != null && val.isNotEmpty) {
      try {
        final list = jsonDecode(val) as List;
        return list.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return [];
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
    if (val != null && val.isNotEmpty) {
      try {
        final list = jsonDecode(val) as List;
        return list.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> setAutoIssueResourceIds(List<String> list) async {
    await setConfig('auto_issue_resource_ids', jsonEncode(list));
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

  Future<List<Map<String, dynamic>>> getAllLogsForExport() async {
    final db = await database;
    return await db.query(
      'app_logs',
      orderBy: 'timestamp ASC',
    );
  }
}
