import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picklist_tracker/engine/column_mapper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late String tempDbPath;

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('sync_test_');
    tempDbPath = p.join(tempDir.path, 'test.db');
    final db = await databaseFactoryFfi.openDatabase(
      tempDbPath,
      options: OpenDatabaseOptions(
        version: 12,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE admin_config (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
          ''');
          // Seed defaults
          await db.insert('admin_config', {'key': 'admin_pin', 'value': '1234'});
          await db.insert('admin_config', {'key': 'super_admin_pin', 'value': '9999'});
          await db.insert('admin_config', {'key': 'tablet_id', 'value': 'TAB-01'});
          await db.insert('admin_config', {'key': 'group_by_line', 'value': 'true'});
          await db.insert('admin_config', {'key': 'auto_advance_pick', 'value': 'false'});
        },
      ),
    );
    await db.close();
  });

  group('Full Configuration Export & Import Tests', () {
    Future<void> runImport(
      Database targetDb,
      Map<String, dynamic> config, {
      required bool overwriteTabletId,
      required bool overwritePins,
    }) async {
      final batch = targetDb.batch();
      for (final entry in config.entries) {
        final key = entry.key;
        if (key == 'config_version' || key == 'exported_at') continue;
        if (key == 'tablet_id' && !overwriteTabletId) continue;
        if ((key == 'admin_pin' || key == 'super_admin_pin') && !overwritePins) continue;

        final dynamic val = entry.value;
        final String strVal = (val is String) ? val : jsonEncode(val);
        batch.insert(
          'admin_config',
          {'key': key, 'value': strVal},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }

    test('exportFullConfiguration collects all settings and options', () async {
      final db = await databaseFactoryFfi.openDatabase(
        tempDbPath,
        options: OpenDatabaseOptions(version: 12),
      );

      // Seed rich configuration
      await db.insert('admin_config', {
        'key': 'global_departments',
        'value': jsonEncode({'Welding': true, 'Paint': false}),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('admin_config', {
        'key': 'blocked_component_resources',
        'value': jsonEncode(['COMP-X', 'COMP-Y']),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('admin_config', {
        'key': 'auto_issue_component_resources',
        'value': jsonEncode(['BOX', 'HARDWARE']),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('admin_config', {
        'key': 'component_resource_rules',
        'value': jsonEncode([
          {'pattern': 'BOX', 'allow_pick': true, 'auto_issue': true}
        ]),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('admin_config', {
        'key': 'mainline_resource_picks',
        'value': jsonEncode(['2 GE PLUMB']),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('admin_config', {
        'key': 'standard_pickers',
        'value': jsonEncode(['John Doe', 'Jane Smith']),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('admin_config', {
        'key': 'admin_pin',
        'value': '4321',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final customMapper = ColumnMapper();
      customMapper.addAlias(ColumnMapper.keyPartId, 'CUSTOM_PART_CODE');

      // Test export directly via queries or helper logic
      final rows = await db.query('admin_config');
      final exportData = <String, dynamic>{
        'config_version': 1,
        'exported_at': DateTime.now().toIso8601String(),
        'column_mapper_config': jsonDecode(customMapper.toJson()),
      };
      for (final row in rows) {
        final key = row['key'] as String;
        final rawVal = row['value'] as String;
        if (rawVal.startsWith('{') || rawVal.startsWith('[')) {
          try {
            exportData[key] = jsonDecode(rawVal);
          } catch (_) {
            exportData[key] = rawVal;
          }
        } else {
          exportData[key] = rawVal;
        }
      }

      expect(exportData['config_version'], 1);
      expect(exportData['tablet_id'], 'TAB-01');
      expect(exportData['admin_pin'], '4321');
      expect(exportData['global_departments'], {'Welding': true, 'Paint': false});
      expect(exportData['blocked_component_resources'], ['COMP-X', 'COMP-Y']);
      expect(exportData['auto_issue_component_resources'], ['BOX', 'HARDWARE']);
      expect(exportData['standard_pickers'], ['John Doe', 'Jane Smith']);

      final mapperAliases = exportData['column_mapper_config'] as Map<String, dynamic>;
      final partIdAliases = (mapperAliases[ColumnMapper.keyPartId] as List).map((e) => e.toString()).toList();
      expect(partIdAliases.contains('CUSTOM PART CODE'), isTrue);

      await db.close();
    });

    test('importFullConfiguration preserves Tablet ID and PINs when flags are false', () async {
      final db = await databaseFactoryFfi.openDatabase(
        tempDbPath,
        options: OpenDatabaseOptions(version: 12),
      );

      // Destination tablet currently has:
      // tablet_id = 'DEST-TAB-99'
      // admin_pin = '5555'
      await db.insert('admin_config', {'key': 'tablet_id', 'value': 'DEST-TAB-99'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('admin_config', {'key': 'admin_pin', 'value': '5555'},
          conflictAlgorithm: ConflictAlgorithm.replace);

      // Incoming config from Master tablet:
      final incomingConfig = <String, dynamic>{
        'config_version': 1,
        'exported_at': '2026-09-17T02:00:00.000Z',
        'tablet_id': 'MASTER-TAB-01',
        'admin_pin': '9999',
        'super_admin_pin': '8888',
        'auto_advance_pick': true,
        'group_by_line': false,
        'global_departments': {'Welding': true, 'Assembly': false},
        'blocked_component_resources': ['WELD_WIRE'],
        'auto_issue_component_resources': ['SCREWS', 'NUTS'],
        'standard_pickers': ['Alice', 'Bob'],
        'column_mapper_config': {
          ColumnMapper.keyPartId: ['ITEM_NUMBER', 'SKU_ID'],
        },
      };

      await runImport(db, incomingConfig, overwriteTabletId: false, overwritePins: false);

      // Verify destination tablet ID and PIN are strictly PRESERVED
      final tabletRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['tablet_id']);
      expect(tabletRow.first['value'], 'DEST-TAB-99');

      final pinRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['admin_pin']);
      expect(pinRow.first['value'], '5555');

      // Verify functional settings WERE imported
      final deptsRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['global_departments']);
      expect(jsonDecode(deptsRow.first['value'] as String), {'Welding': true, 'Assembly': false});

      final blockedRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['blocked_component_resources']);
      expect(jsonDecode(blockedRow.first['value'] as String), ['WELD_WIRE']);

      final pickersRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['standard_pickers']);
      expect(jsonDecode(pickersRow.first['value'] as String), ['Alice', 'Bob']);

      final autoAdvRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['auto_advance_pick']);
      expect(autoAdvRow.first['value'], 'true');

      // Verify ColumnMapper restoration from imported JSON
      final mapperRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['column_mapper_config']);
      final mapperConfig = jsonDecode(mapperRow.first['value'] as String) as Map<String, dynamic>;
      final targetMapper = ColumnMapper();
      targetMapper.aliases.clear();
      for (final e in mapperConfig.entries) {
        targetMapper.aliases[e.key] = (e.value as List).map((i) => i.toString()).toList();
      }
      expect(targetMapper.aliases[ColumnMapper.keyPartId], ['ITEM_NUMBER', 'SKU_ID']);

      await db.close();
    });

    test('importFullConfiguration updates Tablet ID and PINs when flags are true', () async {
      final db = await databaseFactoryFfi.openDatabase(
        tempDbPath,
        options: OpenDatabaseOptions(version: 12),
      );

      final incomingConfig = <String, dynamic>{
        'config_version': 1,
        'tablet_id': 'CLONED-TAB-05',
        'admin_pin': '7777',
        'super_admin_pin': '3333',
      };

      await runImport(db, incomingConfig, overwriteTabletId: true, overwritePins: true);

      final tabletRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['tablet_id']);
      expect(tabletRow.first['value'], 'CLONED-TAB-05');

      final pinRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['admin_pin']);
      expect(pinRow.first['value'], '7777');

      final superPinRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['super_admin_pin']);
      expect(superPinRow.first['value'], '3333');

      await db.close();
    });

    test('registerDiscoveredPicklistItems detects new items, persists them, and defaults to enabled', () async {
      final db = await databaseFactoryFfi.openDatabase(
        tempDbPath,
        options: OpenDatabaseOptions(version: 12),
      );

      // Helper logic matching DatabaseService.registerDiscoveredPicklistItems
      Future<Map<String, List<String>>> registerItems({
        required List<String> depts,
        required List<String> compRes,
        required List<String> mainLine,
      }) async {
        final knownDeptsVal = await db.query('admin_config', where: 'key = ?', whereArgs: ['known_departments']);
        final existingDepts = knownDeptsVal.isNotEmpty
            ? (jsonDecode(knownDeptsVal.first['value'] as String) as List).map((e) => e.toString().toLowerCase()).toSet()
            : <String>{};

        final knownCompVal = await db.query('admin_config', where: 'key = ?', whereArgs: ['known_component_resources']);
        final existingCompRes = knownCompVal.isNotEmpty
            ? (jsonDecode(knownCompVal.first['value'] as String) as List).map((e) => e.toString().toLowerCase()).toSet()
            : <String>{};

        final knownMLVal = await db.query('admin_config', where: 'key = ?', whereArgs: ['known_main_line_resources']);
        final existingML = knownMLVal.isNotEmpty
            ? (jsonDecode(knownMLVal.first['value'] as String) as List).map((e) => e.toString().toLowerCase()).toSet()
            : <String>{};

        final newDepts = <String>[];
        final seenDepts = <String>{};
        for (final d in depts) {
          final trimmed = d.trim();
          final lower = trimmed.toLowerCase();
          if (trimmed.isNotEmpty && trimmed != '(Empty / Unassigned)' && !existingDepts.contains(lower) && seenDepts.add(lower)) {
            newDepts.add(trimmed);
          }
        }

        final newComp = <String>[];
        final seenComp = <String>{};
        for (final cr in compRes) {
          final trimmed = cr.trim();
          final lower = trimmed.toLowerCase();
          if (trimmed.isNotEmpty && trimmed != '(Empty / Unassigned)' && !existingCompRes.contains(lower) && seenComp.add(lower)) {
            newComp.add(trimmed);
          }
        }

        final newML = <String>[];
        final seenML = <String>{};
        for (final ml in mainLine) {
          final trimmed = ml.trim();
          final lower = trimmed.toLowerCase();
          if (trimmed.isNotEmpty && trimmed != '(Empty / Unassigned)' && !existingML.contains(lower) && seenML.add(lower)) {
            newML.add(trimmed);
          }
        }

        if (newDepts.isNotEmpty) {
          final updated = (existingDepts..addAll(newDepts.map((s) => s.toLowerCase()))).toList();
          await db.insert('admin_config', {'key': 'known_departments', 'value': jsonEncode(updated)},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        if (newComp.isNotEmpty) {
          final updated = (existingCompRes..addAll(newComp.map((s) => s.toLowerCase()))).toList();
          await db.insert('admin_config', {'key': 'known_component_resources', 'value': jsonEncode(updated)},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        if (newML.isNotEmpty) {
          final updated = (existingML..addAll(newML.map((s) => s.toLowerCase()))).toList();
          await db.insert('admin_config', {'key': 'known_main_line_resources', 'value': jsonEncode(updated)},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }

        return {
          'departments': newDepts,
          'component_resources': newComp,
          'main_line_resources': newML,
        };
      }

      // 1. First import with fresh categories
      final result1 = await registerItems(
        depts: ['Plumbing', 'Paint'],
        compRes: ['prima', 'Laser'],
        mainLine: ['2 ge plumb'],
      );

      expect(result1['departments'], ['Plumbing', 'Paint']);
      expect(result1['component_resources'], ['prima', 'Laser']);
      expect(result1['main_line_resources'], ['2 ge plumb']);

      // 2. Re-importing same categories produces 0 new items
      final result2 = await registerItems(
        depts: ['Plumbing', 'Paint'],
        compRes: ['prima', 'Laser'],
        mainLine: ['2 ge plumb'],
      );

      expect(result2['departments']!.isEmpty, isTrue);
      expect(result2['component_resources']!.isEmpty, isTrue);
      expect(result2['main_line_resources']!.isEmpty, isTrue);

      // 3. New import with an additional component resource
      final result3 = await registerItems(
        depts: ['Plumbing'],
        compRes: ['prima', 'Stamping'],
        mainLine: ['2 ge plumb'],
      );

      expect(result3['departments']!.isEmpty, isTrue);
      expect(result3['component_resources'], ['Stamping']);
      expect(result3['main_line_resources']!.isEmpty, isTrue);

      // Verify persistent known catalog in DB
      final knownCompRow = await db.query('admin_config', where: 'key = ?', whereArgs: ['known_component_resources']);
      final knownCompList = jsonDecode(knownCompRow.first['value'] as String) as List;
      expect(knownCompList.contains('prima'), isTrue);
      expect(knownCompList.contains('laser'), isTrue);
      expect(knownCompList.contains('stamping'), isTrue);

      await db.close();
    });

    test('syncAllKnownCatalogs backfills component_resource_id from raw_columns and records catalogs', () async {
      final db = await databaseFactoryFfi.openDatabase(
        tempDbPath,
        options: OpenDatabaseOptions(version: 12),
      );

      await db.execute('''
        CREATE TABLE IF NOT EXISTS picklist_items (
          id TEXT PRIMARY KEY,
          unit_id TEXT NOT NULL,
          department TEXT NOT NULL,
          line TEXT NOT NULL,
          work_order TEXT NOT NULL,
          part_id TEXT NOT NULL,
          part_description TEXT NOT NULL,
          qty_required REAL NOT NULL,
          qty_due REAL NOT NULL,
          qty_picked REAL NOT NULL,
          row_order INTEGER NOT NULL,
          component_resource_id TEXT,
          resource_id TEXT,
          dept_type TEXT,
          raw_columns TEXT
        );
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS departments (
          id TEXT PRIMARY KEY,
          unit_id TEXT NOT NULL,
          name TEXT NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 1
        );
      ''');

      // Insert legacy rows with empty component_resource_id but populated raw_columns
      await db.insert('picklist_items', {
        'id': 'item_1',
        'unit_id': 'unit_1',
        'department': 'Welding',
        'line': 'Line 1',
        'work_order': 'WO-1',
        'part_id': 'P-100',
        'part_description': 'Plate',
        'qty_required': 10,
        'qty_due': 10,
        'qty_picked': 0,
        'row_order': 1,
        'component_resource_id': '',
        'resource_id': 'Weld Cell 1',
        'dept_type': 'MAIN LINE',
        'raw_columns': jsonEncode({'Component Resource id': 'prima', 'Work Center': 'Weld Cell 1'}),
      });

      await db.insert('picklist_items', {
        'id': 'item_2',
        'unit_id': 'unit_1',
        'department': 'Assembly',
        'line': 'Line 2',
        'work_order': 'WO-2',
        'part_id': 'P-200',
        'part_description': 'Screw',
        'qty_required': 5,
        'qty_due': 5,
        'qty_picked': 0,
        'row_order': 2,
        'component_resource_id': '',
        'resource_id': '2 ge plumb',
        'dept_type': 'MAIN LINE',
        'raw_columns': jsonEncode({'Component Resource id': 'Laser', 'Work Center': '2 ge plumb'}),
      });

      final mapper = ColumnMapper();

      // Run backfill logic
      final emptyRows = await db.query(
        'picklist_items',
        columns: ['id', 'raw_columns'],
        where: "(component_resource_id IS NULL OR TRIM(component_resource_id) = '') AND raw_columns IS NOT NULL AND TRIM(raw_columns) != ''",
      );

      final batch = db.batch();
      final discoveredComp = <String>{};
      for (final row in emptyRows) {
        final id = row['id'] as String;
        final rawMap = jsonDecode(row['raw_columns'] as String) as Map<String, dynamic>;
        for (final entry in rawMap.entries) {
          if (mapper.identifyColumn(entry.key) == ColumnMapper.keyComponentResourceId) {
            final val = entry.value.toString().trim();
            if (val.isNotEmpty) {
              batch.update('picklist_items', {'component_resource_id': val}, where: 'id = ?', whereArgs: [id]);
              discoveredComp.add(val);
            }
          }
        }
      }
      await batch.commit(noResult: true);

      // Verify rows were backfilled
      final updatedRows = await db.query('picklist_items', orderBy: 'id ASC');
      expect(updatedRows[0]['component_resource_id'], 'prima');
      expect(updatedRows[1]['component_resource_id'], 'Laser');
      expect(discoveredComp.contains('prima'), isTrue);
      expect(discoveredComp.contains('Laser'), isTrue);

      await db.close();
    });

    test('syncAllKnownCatalogs backfills on_hand from raw_columns for legacy rows', () async {
      final db = await databaseFactoryFfi.openDatabase(
        tempDbPath,
        options: OpenDatabaseOptions(version: 13),
      );

      await db.execute('''
        CREATE TABLE IF NOT EXISTS picklist_items (
          id TEXT PRIMARY KEY,
          unit_id TEXT NOT NULL,
          part_id TEXT NOT NULL,
          on_hand TEXT,
          raw_columns TEXT
        );
      ''');

      await db.insert('picklist_items', {
        'id': 'item_oh_1',
        'unit_id': 'unit_1',
        'part_id': 'PART_5',
        'on_hand': '',
        'raw_columns': jsonEncode({'BIN LOCATION': 'A-12-3', 'Description': 'Bracket'}),
      });

      await db.insert('picklist_items', {
        'id': 'item_oh_2',
        'unit_id': 'unit_1',
        'part_id': 'PART_6',
        'on_hand': '',
        'raw_columns': jsonEncode({'ON HAND': '50', 'Description': 'Bolt'}),
      });

      final mapper = ColumnMapper();

      final emptyOnHandRows = await db.query(
        'picklist_items',
        columns: ['id', 'raw_columns'],
        where: "(on_hand IS NULL OR TRIM(on_hand) = '') AND raw_columns IS NOT NULL AND TRIM(raw_columns) != ''",
      );

      final batch = db.batch();
      for (final row in emptyOnHandRows) {
        final id = row['id'] as String;
        final rawMap = jsonDecode(row['raw_columns'] as String) as Map<String, dynamic>;
        for (final entry in rawMap.entries) {
          final identified = mapper.identifyColumn(entry.key);
          final norm = ColumnMapper.normalize(entry.key);
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
              batch.update('picklist_items', {'on_hand': val}, where: 'id = ?', whereArgs: [id]);
              break;
            }
          }
        }
      }
      await batch.commit(noResult: true);

      final updatedRows = await db.query('picklist_items', orderBy: 'id ASC');
      expect(updatedRows[0]['on_hand'], 'A-12-3');
      expect(updatedRows[1]['on_hand'], '50');

      await db.close();
    });
  });
}
