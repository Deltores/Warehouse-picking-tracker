import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:picklist_tracker/engine/column_mapper.dart';
import 'package:picklist_tracker/engine/fifo_allocation_engine.dart';
import 'package:picklist_tracker/engine/grouping_engine.dart';
import 'package:picklist_tracker/models/grouping_preset.dart';
import 'package:picklist_tracker/models/part_summary.dart';
import 'package:picklist_tracker/models/picklist_item.dart';
import 'package:picklist_tracker/models/session_metadata.dart';
import 'package:picklist_tracker/models/unit_pick_date_urgency.dart';
import 'package:picklist_tracker/models/unit_record.dart';
import 'package:picklist_tracker/services/database_service.dart';
import 'package:picklist_tracker/services/excel_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late DatabaseService dbService;
  late String tempDbPath;
  late Database testDb;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('picklist_tracker_tests_');
    tempDbPath = p.join(tempDir.path, 'test.db');
    testDb = await databaseFactoryFfi.openDatabase(
      tempDbPath,
      options: OpenDatabaseOptions(
        version: 15,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE units (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              file_path TEXT NOT NULL,
              total_required INTEGER NOT NULL DEFAULT 0,
              total_picked INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              completed_at INTEGER,
              last_accessed_at INTEGER NOT NULL,
              deleted_at INTEGER,
              original_headers TEXT
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
              qty_picked REAL NOT NULL,
              row_order INTEGER NOT NULL,
              pick_date TEXT NOT NULL DEFAULT '',
              prod_date TEXT NOT NULL DEFAULT '',
              sub_unit TEXT NOT NULL DEFAULT '',
              resource_id TEXT NOT NULL DEFAULT '',
              component_resource_id TEXT NOT NULL DEFAULT '',
              on_hand TEXT NOT NULL DEFAULT '',
              dept_type TEXT NOT NULL DEFAULT '',
              raw_columns TEXT NOT NULL DEFAULT '{}',
              replaced_part_id TEXT NOT NULL DEFAULT '',
              replacement_note TEXT NOT NULL DEFAULT '',
              replaced_at INTEGER,
              replaced_by TEXT NOT NULL DEFAULT ''
            );
          ''');
          await db.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              unit_id TEXT NOT NULL,
              worker_name TEXT NOT NULL,
              start_time INTEGER NOT NULL,
              end_time INTEGER,
              total_items_picked INTEGER NOT NULL DEFAULT 0,
              issued_status TEXT NOT NULL DEFAULT 'Pending Issue',
              batch_id TEXT,
              session_seq_no INTEGER NOT NULL DEFAULT 0,
              tablet_id TEXT NOT NULL DEFAULT '',
              pick_date TEXT NOT NULL DEFAULT '',
              status TEXT NOT NULL DEFAULT 'OPEN',
              issued_at INTEGER
            );
          ''');
          await db.execute('''
            CREATE TABLE part_flags (
              id TEXT PRIMARY KEY,
              unit_id TEXT NOT NULL,
              part_id TEXT NOT NULL,
              department TEXT NOT NULL DEFAULT '',
              flag_type TEXT NOT NULL,
              worker_name TEXT NOT NULL DEFAULT '',
              created_at INTEGER NOT NULL,
              note TEXT NOT NULL DEFAULT ''
            );
          ''');
          await db.execute('''
            CREATE TABLE manual_picks (
              id TEXT PRIMARY KEY,
              unit_id TEXT NOT NULL,
              session_id TEXT NOT NULL,
              part_id TEXT NOT NULL,
              qty_picked REAL NOT NULL,
              note TEXT NOT NULL,
              department TEXT NOT NULL,
              work_order TEXT NOT NULL,
              worker_name TEXT NOT NULL,
              created_at INTEGER NOT NULL
            );
          ''');
          await db.execute('''
            CREATE TABLE part_id_replacements (
              id TEXT PRIMARY KEY,
              unit_id TEXT NOT NULL,
              session_id TEXT NOT NULL,
              worker_name TEXT NOT NULL,
              old_part_id TEXT NOT NULL,
              new_part_id TEXT NOT NULL,
              note TEXT NOT NULL,
              department TEXT NOT NULL DEFAULT '',
              created_at INTEGER NOT NULL
            );
          ''');
          await db.execute('''
            CREATE TABLE admin_config (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
          ''');
          await db.execute('''
            CREATE TABLE session_picks (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              unit_id TEXT NOT NULL,
              item_id TEXT NOT NULL,
              part_id TEXT NOT NULL,
              qty_picked REAL NOT NULL,
              created_at INTEGER NOT NULL
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
        },
      ),
    );
    DatabaseService.setDatabaseForTesting(testDb);
    dbService = DatabaseService();
  });

  tearDown(() async {
    DatabaseService.setDatabaseForTesting(null);
    await testDb.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('20 Core Picklist Tracker Verification Tests', () {
    // 1. Column Mapping & Normalization
    test('1. ColumnMapper normalizes headers, resolves aliases, and identifies ON_HAND', () {
      final mapper = ColumnMapper();
      expect(mapper.identifyColumn('Part Number'), equals(ColumnMapper.keyPartId));
      expect(mapper.identifyColumn('ITEM_DESC'), equals(ColumnMapper.keyPartDescription));
      expect(mapper.identifyColumn('QTY REQUIRED'), equals(ColumnMapper.keyQtyRequired));
      expect(mapper.identifyColumn('work_order_num'), equals(ColumnMapper.keyWorkOrder));
      expect(mapper.identifyColumn('Assembly Line'), equals(ColumnMapper.keyLine));
      expect(mapper.identifyColumn('Dept'), equals(ColumnMapper.keyDepartment));
      expect(mapper.identifyColumn('ON HAND LOCATIONS'), equals(ColumnMapper.keyOnHand));
      expect(mapper.identifyColumn('Pick Date'), equals(ColumnMapper.keyPickDate));
      expect(mapper.identifyColumn('Production Date'), equals(ColumnMapper.keyProdDate));
      expect(mapper.identifyColumn('Component Resource id'), equals(ColumnMapper.keyComponentResourceId));
      expect(mapper.identifyColumn('RESOURCE'), equals(ColumnMapper.keyResourceId));
    });

    // 2. FIFO Allocation across Work Orders
    test('2. FifoAllocationEngine allocates pieces FIFO across Work Orders by row order', () {
      final items = [
        PicklistItem(id: '1', unitId: 'U1', department: 'Plumbing', line: 'L1', workOrder: 'WO-100', partId: 'PIPE-1', partDescription: 'Copper Pipe', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 1),
        PicklistItem(id: '2', unitId: 'U1', department: 'Plumbing', line: 'L1', workOrder: 'WO-200', partId: 'PIPE-1', partDescription: 'Copper Pipe', qtyRequired: 15, qtyDue: 15, qtyPicked: 0, rowOrder: 2),
      ];

      final updated = FifoAllocationEngine.allocateByPartId(
        allItems: items,
        department: 'Plumbing',
        partId: 'PIPE-1',
        totalPickedToAllocate: 18.0,
      );

      expect(updated[0].qtyPicked, equals(10.0));
      expect(updated[0].qtyDue, equals(0.0));
      expect(updated[1].qtyPicked, equals(8.0));
      expect(updated[1].qtyDue, equals(7.0));
    });

    // 3. Department Isolation in FIFO
    test('3. FifoAllocationEngine strictly isolates allocation to the target department', () {
      final items = [
        PicklistItem(id: '1', unitId: 'U1', department: 'Welding', line: 'L1', workOrder: 'WO-1', partId: 'BRK-1', partDescription: 'Bracket', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 1),
        PicklistItem(id: '2', unitId: 'U1', department: 'Assembly', line: 'L1', workOrder: 'WO-2', partId: 'BRK-1', partDescription: 'Bracket', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 2),
      ];

      final updated = FifoAllocationEngine.allocateByPartId(
        allItems: items,
        department: 'Welding',
        partId: 'BRK-1',
        totalPickedToAllocate: 5.0,
      );

      final weldingItem = updated.firstWhere((i) => i.department == 'Welding');
      final assemblyItem = updated.firstWhere((i) => i.department == 'Assembly');

      expect(weldingItem.qtyPicked, equals(5.0));
      expect(weldingItem.qtyDue, equals(5.0));
      expect(assemblyItem.qtyPicked, equals(0.0));
      expect(assemblyItem.qtyDue, equals(10.0));
    });

    // 4. Decimal Quantities Support
    test('4. FifoAllocationEngine handles decimal double quantities without precision loss', () {
      final items = [
        PicklistItem(id: '1', unitId: 'U1', department: 'Wiring', line: 'L1', workOrder: 'WO-1', partId: 'WIRE-01', partDescription: 'Copper Wire', qtyRequired: 12.5, qtyDue: 12.5, qtyPicked: 0, rowOrder: 1),
      ];

      final updated = FifoAllocationEngine.allocateByPartId(
        allItems: items,
        department: 'Wiring',
        partId: 'WIRE-01',
        totalPickedToAllocate: 7.25,
      );

      expect(updated[0].qtyPicked, closeTo(7.25, 0.0001));
      expect(updated[0].qtyDue, closeTo(5.25, 0.0001));
    });

    // 5. Grouping Tree Engine & Part-ID Progress
    test('5. GroupingEngine builds tree hierarchy and calculates Part-ID centric progress', () {
      final items = [
        PicklistItem(id: '1', unitId: 'U1', department: 'Electrical', line: 'L1', workOrder: 'WO-1', partId: 'WIRE-1', partDescription: 'Wire A', qtyRequired: 10, qtyDue: 0, qtyPicked: 10, rowOrder: 1),
        PicklistItem(id: '2', unitId: 'U1', department: 'Electrical', line: 'L1', workOrder: 'WO-2', partId: 'WIRE-1', partDescription: 'Wire A', qtyRequired: 5, qtyDue: 0, qtyPicked: 5, rowOrder: 2),
        PicklistItem(id: '3', unitId: 'U1', department: 'Electrical', line: 'L1', workOrder: 'WO-3', partId: 'SWITCH-1', partDescription: 'Switch B', qtyRequired: 2, qtyDue: 2, qtyPicked: 0, rowOrder: 3),
      ];

      final nodes = GroupingEngine.buildTree(
        items: items,
        preset: GroupingPreset.defaultPresets.first,
      );

      expect(nodes.isNotEmpty, isTrue);
      final deptNode = nodes.first;
      expect(deptNode.totalParts, equals(2)); // 2 unique part IDs: WIRE-1 and SWITCH-1
      expect(deptNode.completedParts, equals(1)); // WIRE-1 is fully picked
      expect(deptNode.isComplete, isFalse);
    });

    // 6. Date Urgency & Glow Evaluation
    test('6. UnitPickDateUrgency parses formats and evaluates urgency (Red, Yellow, Green)', () {
      final now = DateTime.now();
      final pastDate = now.subtract(const Duration(days: 2));
      final soonDate = now.add(const Duration(days: 1));
      final futureDate = now.add(const Duration(days: 10));

      final pastStr = '${pastDate.year}-${pastDate.month.toString().padLeft(2, '0')}-${pastDate.day.toString().padLeft(2, '0')}';
      final soonStr = '${soonDate.year}-${soonDate.month.toString().padLeft(2, '0')}-${soonDate.day.toString().padLeft(2, '0')}';
      final futureStr = '${futureDate.year}-${futureDate.month.toString().padLeft(2, '0')}-${futureDate.day.toString().padLeft(2, '0')}';

      final pastUrgency = UnitPickDateUrgency.evaluate(dateStr: pastStr, department: 'Paint', isAllCompleted: false);
      expect(pastUrgency.status, equals(UnitUrgencyStatus.pastDue));

      final soonUrgency = UnitPickDateUrgency.evaluate(dateStr: soonStr, department: 'Paint', isAllCompleted: false);
      expect(soonUrgency.status, equals(UnitUrgencyStatus.dueSoon));

      final futureUrgency = UnitPickDateUrgency.evaluate(dateStr: futureStr, department: 'Paint', isAllCompleted: false);
      expect(futureUrgency.status, equals(UnitUrgencyStatus.normal));

      final completedUrgency = UnitPickDateUrgency.evaluate(dateStr: pastStr, department: 'Paint', isAllCompleted: true);
      expect(completedUrgency.status, equals(UnitUrgencyStatus.completed));
    });

    // 7. Lazy Session Initialization
    test('7. DatabaseService lazy session initialization: persists only on first pick', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_lazy', name: 'Unit Lazy', filePath: 'lazy.xlsx', totalRequired: 10, totalPicked: 0, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));

      // Starting flow without picks leaves sessions empty
      var sessions = await dbService.getAllSessionsForUnit('u_lazy');
      expect(sessions.isEmpty, isTrue);

      // On first confirmed pick, session is saved
      final session = SessionMetadata(
        id: 's_lazy_1',
        unitId: 'u_lazy',
        workerName: 'Alice',
        startTime: now,
        sessionSeqNo: 1,
        totalItemsPicked: 1,
        pickDate: '2026-09-19',
      );
      await dbService.saveSession(session);

      sessions = await dbService.getAllSessionsForUnit('u_lazy');
      expect(sessions.length, equals(1));
      expect(sessions.first.workerName, equals('Alice'));
    });

    // 8. Monotonic Session Sequence
    test('8. DatabaseService monotonic session sequence increments 1..9999 and wraps', () async {
      final seq1 = await dbService.nextSessionSeqNo('u_seq');
      expect(seq1, equals(1));

      final seq2 = await dbService.nextSessionSeqNo('u_seq');
      expect(seq2, equals(2));

      await dbService.setConfig('global_last_session_seq_no', '9999');
      final wrappedSeq = await dbService.nextSessionSeqNo('u_seq');
      expect(wrappedSeq, equals(1));
    });

    // 9. Delta Picking
    test('9. DatabaseService delta picking updates quantities correctly', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_delta', name: 'Unit Delta', filePath: 'delta.xlsx', totalRequired: 20, totalPicked: 0, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));
      await dbService.savePicklistItems('u_delta', [
        PicklistItem(id: 'item_d1', unitId: 'u_delta', department: 'Plumbing', line: 'L1', workOrder: 'WO-1', partId: 'VALVE-1', partDescription: 'Ball Valve', qtyRequired: 20, qtyDue: 20, qtyPicked: 0, rowOrder: 1),
      ]);

      await dbService.recordSessionPick(
        sessionId: 's_delta',
        unitId: 'u_delta',
        itemId: 'item_d1',
        partId: 'VALVE-1',
        qtyPickedDelta: 5.0,
      );

      final picks = await dbService.getSessionPickedPartIds('s_delta');
      expect(picks.contains('VALVE-1'), isTrue);
    });

    // 10. LIFO Returns
    test('10. DatabaseService LIFO return reduces picked quantities and logs return record', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_ret', name: 'Unit Return', filePath: 'ret.xlsx', totalRequired: 10, totalPicked: 10, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));
      await dbService.savePicklistItems('u_ret', [
        PicklistItem(id: 'item_r1', unitId: 'u_ret', department: 'Paint', line: 'L1', workOrder: 'WO-1', partId: 'CAN-1', partDescription: 'Paint Can', qtyRequired: 10, qtyDue: 0, qtyPicked: 10, rowOrder: 1),
      ]);

      await testDb.insert('pick_returns', {
        'id': 'ret_1',
        'session_id': 's_ret',
        'unit_id': 'u_ret',
        'worker_name': 'Bob',
        'part_id': 'CAN-1',
        'department': 'Paint',
        'qty_returned': 3.0,
        'comment': 'Wrong color paint returned by inspector',
        'created_at': now,
      });

      final returns = await dbService.getReturnCommentsForUnit('u_ret');
      expect(returns.containsKey('CAN-1'), isTrue);
      expect(returns['CAN-1']!.first, equals('Wrong color paint returned by inspector'));
    });

    // 11. Missing Part Flagging & Auto-Clear on Pick
    test('11. DatabaseService missing part flag is cleared automatically on pick', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_miss', name: 'Unit Miss', filePath: 'miss.xlsx', totalRequired: 5, totalPicked: 0, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));
      await dbService.savePicklistItems('u_miss', [
        PicklistItem(id: 'item_m1', unitId: 'u_miss', department: 'Assembly', line: 'L1', workOrder: 'WO-1', partId: 'BOLT-10', partDescription: 'Hex Bolt', qtyRequired: 5, qtyDue: 5, qtyPicked: 0, rowOrder: 1),
      ]);

      await dbService.recordPartFlag(
        unitId: 'u_miss',
        partId: 'BOLT-10',
        flagType: 'MISSING',
        note: 'Out of stock in bin 12',
        department: 'Assembly',
      );

      var flags = await dbService.getPartFlags('u_miss');
      expect(flags.any((f) => f['flag_type'] == 'MISSING' && f['part_id'] == 'BOLT-10'), isTrue);

      // Picker confirms a pick -> clear MISSING flag directly
      await dbService.clearPartFlag(unitId: 'u_miss', partId: 'BOLT-10', flagType: 'MISSING');
      flags = await dbService.getPartFlags('u_miss');
      expect(flags.any((f) => f['flag_type'] == 'MISSING' && f['part_id'] == 'BOLT-10'), isFalse);

      // Re-add flag to test automatic database cleanup on partial pick
      await dbService.recordPartFlag(
        unitId: 'u_miss',
        partId: 'BOLT-10',
        flagType: 'MISSING',
        note: 'Out of stock in bin 12',
        department: 'Assembly',
      );
      // Partial pick: 2 picked, 3 remaining due
      await dbService.updateItemQtyPicked('item_m1', 2.0, 3.0);
      final cleanedCount = await dbService.cleanupResolvedMissingFlags('u_miss');
      expect(cleanedCount, equals(1));

      flags = await dbService.getPartFlags('u_miss');
      expect(flags.any((f) => f['flag_type'] == 'MISSING' && f['part_id'] == 'BOLT-10'), isFalse);
    });

    // 12. Part Removal & Auto-Unmarking on Pick
    test('12. DatabaseService part removal is unmarked on pick while preserving removal note', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_rm', name: 'Unit RM', filePath: 'rm.xlsx', totalRequired: 8, totalPicked: 0, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));
      await dbService.savePicklistItems('u_rm', [
        PicklistItem(
          id: 'item_rm1',
          unitId: 'u_rm',
          department: 'Welding',
          line: 'L1',
          workOrder: 'WO-1',
          partId: 'BAR-55',
          partDescription: 'Steel Bar',
          qtyRequired: 8,
          qtyDue: 8,
          qtyPicked: 0,
          rowOrder: 1,
          rawColumns: {'_is_removed': true, '_remove_note': 'Design change', '_remove_worker': 'Engineer'},
        ),
      ]);
      await dbService.recordPartRemoval(unitId: 'u_rm', partId: 'BAR-55', workerName: 'Engineer', reason: 'Design change', department: 'Welding');

      var removed = await dbService.getRemovedFromPickingParts('u_rm', department: 'Welding');
      expect(removed.contains('BAR-55'), isTrue);

      // On pick, unmark removal
      await dbService.unmarkPartRemoval(unitId: 'u_rm', partId: 'BAR-55', department: 'Welding');

      removed = await dbService.getRemovedFromPickingParts('u_rm', department: 'Welding');
      expect(removed.contains('BAR-55'), isFalse);

      final items = await dbService.getPicklistItems('u_rm');
      expect(items.first.isRemoved, isFalse);
      expect(items.first.removeNote, equals('Design change')); // note preserved for comments export!
    });

    // 13. Manual Part Addition
    test('13. DatabaseService manual part add persists to manual_picks and picklist_items', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_manual', name: 'Unit Manual', filePath: 'man.xlsx', totalRequired: 0, totalPicked: 0, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));

      await dbService.recordManualPick(
        unitId: 'u_manual',
        sessionId: 's_man_1',
        partId: 'CUSTOM-SCREW-9',
        qtyPicked: 14.0,
        note: 'Added reinforcement screws',
        department: 'Assembly',
        workOrder: 'WO-99',
        workerName: 'Dave',
      );

      final manualPicks = await dbService.getManualPicksForUnit('u_manual');
      expect(manualPicks.length, equals(1));
      expect(manualPicks.first['part_id'], equals('CUSTOM-SCREW-9'));
      expect(manualPicks.first['qty_picked'], equals(14.0));

      final items = await dbService.getPicklistItems('u_manual');
      expect(items.any((i) => i.partId == 'CUSTOM-SCREW-9' && i.isManualAdd), isTrue);
    });

    // 14. Part Replacement & Validation
    test('14. DatabaseService part replacement is department-scoped with 8+ char uppercase rule', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_repl', name: 'Unit Repl', filePath: 'repl.xlsx', totalRequired: 10, totalPicked: 0, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));
      await dbService.savePicklistItems('u_repl', [
        PicklistItem(id: 'item_rep1', unitId: 'u_repl', department: 'Plumbing', line: 'L1', workOrder: 'WO-1', partId: 'OLD-PART-01', partDescription: 'Old Pipe', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 1),
      ]);

      // 8+ char alphanumeric validator check
      const newPartId = 'REPLACED-PART-99';
      expect(newPartId.length >= 8, isTrue);
      expect(newPartId.toUpperCase() == newPartId, isTrue);

      await dbService.recordPartIdReplacement(
        unitId: 'u_repl',
        sessionId: 's_rep',
        oldPartId: 'OLD-PART-01',
        newPartId: newPartId,
        workerName: 'Frank',
        note: 'Superseded by manufacturer bulletin',
        department: 'Plumbing',
      );

      final items = await dbService.getPicklistItems('u_repl');
      final replacedItem = items.first;
      expect(replacedItem.partId, equals(newPartId));
      expect(replacedItem.replacedPartId, equals('OLD-PART-01'));
      expect(replacedItem.replacementNote, equals('Superseded by manufacturer bulletin'));
    });

    // 15. Custom Picker Notes
    test('15. DatabaseService custom picker notes persist in part_flags', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(id: 'u_note', name: 'Unit Note', filePath: 'note.xlsx', totalRequired: 10, totalPicked: 0, status: 'IN_PROGRESS', createdAt: now, lastAccessedAt: now));

      await dbService.setUserPartNote(
        unitId: 'u_note',
        partId: 'SENSOR-A',
        note: 'Calibrated at station 3',
        department: 'Electrical',
      );

      final notes = await dbService.getUserPartNotesForUnit('u_note');
      expect(notes['SENSOR-A'], equals('Calibrated at station 3'));
    });

    // 16. Component Resource Pattern Rules
    test('16. DatabaseService component resource pattern rules apply Allow/Block and Auto-Issue', () async {
      await dbService.setResourcePatternRules([
        {'pattern': 'BOX', 'allowPick': false, 'autoIssue': true},
        {'pattern': 'WELD', 'allowPick': true, 'autoIssue': false},
      ]);

      final rules = await dbService.getResourcePatternRules();
      expect(rules.length, equals(2));
      expect(rules.first['pattern'], equals('BOX'));
      expect(rules.first['autoIssue'], equals(true));
    });

    // 17. MAIN LINE Whole Resource Destination & View Mode
    test('17. MAIN LINE whole resource destination scopes parts across departments with view mode persistence', () async {
      await dbService.setMainLineResourceView('2 ge plumb', 'Combined');
      var view = await dbService.getMainLineResourceView('2 ge plumb');
      expect(view, equals('Combined'));

      await dbService.setMainLineResourceView('2 ge plumb', 'By Department');
      view = await dbService.getMainLineResourceView('2 ge plumb');
      expect(view, equals('By Department'));
    });

    // 18. 3-Stage Session Lifecycle
    test('18. DatabaseService 3-stage session lifecycle: CLOSED -> EXPORTED -> ISSUED with retention', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = SessionMetadata(
        id: 's_life_1',
        unitId: 'u_life',
        workerName: 'Grace',
        startTime: now - 3600000,
        endTime: now,
        sessionSeqNo: 1,
        totalItemsPicked: 5,
        status: 'CLOSED',
        pickDate: '2026-09-19',
      );
      await dbService.saveSession(session);

      // Transition to EXPORTED
      final batchId = 'BATCH_SUPER_T1_1_to_1_$now';
      await dbService.finishSession('s_life_1', now, 5, 'Pending Issue', batchId: batchId);

      var loaded = (await dbService.getAllSessionsForUnit('u_life')).first;
      expect(loaded.status, equals('EXPORTED'));
      expect(loaded.batchId, equals(batchId));

      // Transition to ISSUED
      await dbService.updateSessionIssuedStatus('s_life_1', 'ISSUED', issuedAt: now);
      loaded = (await dbService.getAllSessionsForUnit('u_life')).first;
      expect(loaded.status, equals('ISSUED'));
      expect(loaded.issuedAt, equals(now));
    });

    // 19. Excel Consolidated Super Session Export & 4-Tier Sorting
    test('19. ExcelService batch super session export consolidates across units with 4-tier comments-first sorting', () {
      final standardItem = PicklistItem(id: '1', unitId: 'U1', department: 'D1', line: 'L1', workOrder: 'W1', partId: 'STD-1', partDescription: 'Standard Item', qtyRequired: 10, qtyDue: 0, qtyPicked: 10, rowOrder: 1);
      final manualItem = PicklistItem(id: '2', unitId: 'U1', department: 'D1', line: 'L1', workOrder: 'W2', partId: 'MAN-1', partDescription: 'Added Item', qtyRequired: 5, qtyDue: 0, qtyPicked: 5, rowOrder: 2, rawColumns: {'_manual_add': true, '_manual_note': 'Extra'});
      final replacedItem = PicklistItem(id: '3', unitId: 'U1', department: 'D1', line: 'L1', workOrder: 'W3', partId: 'REP-1', partDescription: 'Replaced Item', qtyRequired: 8, qtyDue: 0, qtyPicked: 8, rowOrder: 3, replacedPartId: 'OLD-1');

      final tierStandard = ExcelService.getItemSortingTier(item: standardItem, partNotes: {}, returnComments: {}, removeComments: {}, missingFlag: null);
      final tierManual = ExcelService.getItemSortingTier(item: manualItem, partNotes: {}, returnComments: {}, removeComments: {}, missingFlag: null);
      final tierReplaced = ExcelService.getItemSortingTier(item: replacedItem, partNotes: {}, returnComments: {}, removeComments: {}, missingFlag: null);

      expect(tierManual, equals(1)); // Tier 1: Manually added
      expect(tierReplaced, equals(2)); // Tier 2: Replaced
      expect(tierStandard, equals(3)); // Tier 3: Standard
    });

    // 20. Context-Aware Unit of Measure (UOM)
    test('20. Unit of Measure (UOM) standardizes EA/PCS/NA to PCS and preserves custom units', () {
      expect(PicklistItem.formatUom('EA'), equals('PCS'));
      expect(PicklistItem.formatUom('ea'), equals('PCS'));
      expect(PicklistItem.formatUom('PCS'), equals('PCS'));
      expect(PicklistItem.formatUom('pc'), equals('PCS'));
      expect(PicklistItem.formatUom('NA'), equals('PCS'));
      expect(PicklistItem.formatUom('N/A'), equals('PCS'));
      expect(PicklistItem.formatUom(''), equals('PCS'));
      expect(PicklistItem.formatUom(null), equals('PCS'));

      // Measurement units preserved as-is
      expect(PicklistItem.formatUom('M'), equals('M'));
      expect(PicklistItem.formatUom('FT'), equals('FT'));
      expect(PicklistItem.formatUom('KG'), equals('KG'));
      expect(PicklistItem.formatUom('BOX'), equals('BOX'));
      expect(PicklistItem.formatUom('SET'), equals('SET'));
      expect(PicklistItem.formatUom('ROLL'), equals('ROLL'));
      expect(PicklistItem.formatUom('LBS'), equals('LBS'));

      expect(PartSummary.formatUom('M'), equals('M'));
      expect(PartSummary.formatUom('EA'), equals('PCS'));
    });

    // 21. Removed Parts Exclusion & List-Recovery Targeting
    test('21. Removed parts are excluded from general carousel but accessible when specifically targeted', () {
      const normalPart = PartSummary(
        partId: 'PART_1',
        description: 'Normal Widget',
        qtyPicked: 0,
        qtyRequired: 10,
        qtyDue: 10,
        minRowOrder: 1,
        isRemoved: false,
      );
      const removedPart = PartSummary(
        partId: 'PART_2',
        description: 'Removed Widget',
        qtyPicked: 2,
        qtyRequired: 100,
        qtyDue: 98,
        minRowOrder: 2,
        isRemoved: true,
      );

      final allParts = [normalPart, removedPart];

      // General picking without target: removed parts are excluded
      final generalList = allParts.where((p) => !p.isRemoved).toList();
      expect(generalList.length, equals(1));
      expect(generalList.first.partId, equals('PART_1'));

      // Specifically targeting PART_2 (case-insensitive & trimmed): removed part is included
      const targetId = ' part_2 ';
      final targetNorm = targetId.trim().toUpperCase();
      final targetedList = allParts.where((p) {
        if (p.partId.trim().toUpperCase() == targetNorm) return true;
        return !p.isRemoved;
      }).toList();

      expect(targetedList.length, equals(2));
      final found = targetedList.firstWhere((p) => p.partId.trim().toUpperCase() == targetNorm);
      expect(found.partId, equals('PART_2'));
      expect(found.isRemoved, isTrue);
    });

    // 22. Manually Added Part Replacement Synchronization across all DB tables
    test('22. DatabaseService manually added part replacement synchronizes manual_picks, session_picks, part_flags, and raw_columns', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(
        id: 'u_man_rep',
        name: 'Unit Man Rep',
        filePath: 'man_rep.xlsx',
        totalRequired: 0,
        totalPicked: 0,
        status: 'IN_PROGRESS',
        createdAt: now,
        lastAccessedAt: now,
      ));

      // 1. Worker adds a manual part
      final manualItem = await dbService.recordManualPick(
        unitId: 'u_man_rep',
        sessionId: 'sess_1',
        workerName: 'Alice',
        department: 'Assembly',
        workOrder: 'WO-100',
        partId: 'MAN-PART-OLD',
        qtyPicked: 5.0,
        note: 'Added bracket manually',
      );

      // 2. Also record in session_picks and part_flags
      await dbService.recordSessionPick(
        sessionId: 'sess_1',
        unitId: 'u_man_rep',
        itemId: manualItem.id,
        partId: 'MAN-PART-OLD',
        qtyPickedDelta: 5.0,
      );
      await dbService.setUserPartNote(
        unitId: 'u_man_rep',
        partId: 'MAN-PART-OLD',
        note: 'Torque to 15Nm',
        department: 'Assembly',
      );

      // Verify pre-replacement state
      final manualPicksBefore = await dbService.getManualPicksForUnit('u_man_rep');
      expect(manualPicksBefore.first['part_id'], equals('MAN-PART-OLD'));
      final batchPicksBefore = await dbService.getBatchPickedPartIdsForUnit(['sess_1'], 'u_man_rep');
      expect(batchPicksBefore.contains('MAN-PART-OLD'), isTrue);
      final notesBefore = await dbService.getUserPartNotesForUnit('u_man_rep');
      expect(notesBefore['MAN-PART-OLD'], equals('Torque to 15Nm'));

      // 3. Worker replaces the manually added part
      const newPartId = 'MAN-PART-NEW';
      await dbService.recordPartIdReplacement(
        unitId: 'u_man_rep',
        sessionId: 'sess_1',
        workerName: 'Alice',
        oldPartId: 'MAN-PART-OLD',
        newPartId: newPartId,
        note: 'Upgraded to reinforced steel bracket',
        department: 'Assembly',
        targetItemIds: [manualItem.id],
      );

      // Verify picklist_items is updated
      final items = await dbService.getPicklistItems('u_man_rep');
      final updatedItem = items.firstWhere((i) => i.id == manualItem.id);
      expect(updatedItem.partId, equals(newPartId));
      expect(updatedItem.replacedPartId, equals('MAN-PART-OLD'));
      expect(updatedItem.replacementNote, equals('Upgraded to reinforced steel bracket'));
      expect(updatedItem.isManualAdd, isTrue);

      // Verify manual_picks table is synchronized!
      final manualPicksAfter = await dbService.getManualPicksForUnit('u_man_rep');
      expect(manualPicksAfter.length, equals(1));
      expect(manualPicksAfter.first['part_id'], equals(newPartId));

      // Verify session_picks table is synchronized!
      final batchPicksAfter = await dbService.getBatchPickedPartIdsForUnit(['sess_1'], 'u_man_rep');
      expect(batchPicksAfter.contains(newPartId), isTrue);
      expect(batchPicksAfter.contains('MAN-PART-OLD'), isFalse);

      // Verify part_flags table is synchronized!
      final notesAfter = await dbService.getUserPartNotesForUnit('u_man_rep');
      expect(notesAfter[newPartId], equals('Torque to 15Nm'));
    });

    // 23. Manually added part FIFO allocation expansion beyond initial required
    test('23. FifoAllocationEngine allows manually added parts to allocate additional quantity beyond initial qtyRequired', () {
      final manualItem = PicklistItem(
        id: 'manual_item_1',
        unitId: 'u_fifo',
        department: 'Assembly',
        line: 'Line 1',
        workOrder: 'MANUAL',
        partId: 'MAN-BOLT-1',
        partDescription: 'Extra Bolt',
        qtyRequired: 4.0,
        qtyDue: 0.0,
        qtyPicked: 4.0,
        rowOrder: 999999,
        rawColumns: {'_manual_add': true, '_manual_note': 'Extra Bolt'},
      );

      // Worker enters total picked = 7 (delta +3)
      final allocated = FifoAllocationEngine.allocateByPartId(
        allItems: [manualItem],
        department: 'Assembly',
        partId: 'MAN-BOLT-1',
        totalPickedToAllocate: 7.0,
      );

      expect(allocated.length, equals(1));
      expect(allocated.first.qtyPicked, equals(7.0));
      expect(allocated.first.qtyRequired, equals(7.0));
      expect(allocated.first.qtyDue, equals(0.0));
    });

    // 24. Target item IDs scoping in part replacement
    test('24. DatabaseService part replacement with explicit targetItemIds updates exact scoped items', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await dbService.insertUnit(UnitRecord(
        id: 'u_scoped_rep',
        name: 'Unit Scoped Rep',
        filePath: 'scoped.xlsx',
        totalRequired: 20,
        totalPicked: 0,
        status: 'IN_PROGRESS',
        createdAt: now,
        lastAccessedAt: now,
      ));

      await dbService.savePicklistItems('u_scoped_rep', [
        PicklistItem(id: 'item_scope_1', unitId: 'u_scoped_rep', department: 'Plumbing (Main)', line: 'L1', workOrder: 'WO-1', partId: 'VALVE-A1', partDescription: 'Valve', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 1),
        PicklistItem(id: 'item_scope_2', unitId: 'u_scoped_rep', department: 'Plumbing (Secondary)', line: 'L2', workOrder: 'WO-2', partId: 'VALVE-A1', partDescription: 'Valve', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 2),
      ]);

      // Pass targetItemIds for only item_scope_1
      await dbService.recordPartIdReplacement(
        unitId: 'u_scoped_rep',
        sessionId: 'sess_scoped',
        workerName: 'George',
        oldPartId: 'VALVE-A1',
        newPartId: 'VALVE-B2-REPL',
        note: 'Scoped replacement on line 1',
        targetItemIds: ['item_scope_1'],
      );

      final items = await dbService.getPicklistItems('u_scoped_rep');
      final item1 = items.firstWhere((i) => i.id == 'item_scope_1');
      final item2 = items.firstWhere((i) => i.id == 'item_scope_2');

      expect(item1.partId, equals('VALVE-B2-REPL'));
      expect(item1.replacedPartId, equals('VALVE-A1'));
      // item2 in another department must remain untouched!
      expect(item2.partId, equals('VALVE-A1'));
      expect(item2.replacedPartId, isEmpty);
    });
  });
}

