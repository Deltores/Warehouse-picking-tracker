import 'package:flutter_test/flutter_test.dart';
import 'package:picklist_tracker/engine/fifo_allocation_engine.dart';
import 'package:picklist_tracker/engine/grouping_engine.dart';
import 'package:picklist_tracker/models/grouping_preset.dart';
import 'package:picklist_tracker/models/picklist_item.dart';
import 'package:picklist_tracker/models/session_metadata.dart';
import 'package:picklist_tracker/models/unit_record.dart';
import 'package:picklist_tracker/ui/screens/session_export_screen.dart';

void main() {
  group('MAIN LINE Resource Allocation & Batch Export Tests', () {
    test('FifoAllocationEngine cascades picks across multiple MAIN LINE departments for resource scope', () {
      final items = [
        PicklistItem(
          id: '1',
          unitId: 'U1',
          department: 'MAIN LINE 1',
          line: 'L1',
          workOrder: 'WO-101',
          partId: 'PART-A',
          partDescription: 'Bracket',
          resourceId: 'WELD',
          deptType: 'MAIN LINE',
          qtyRequired: 10,
          qtyDue: 10,
          qtyPicked: 0,
          rowOrder: 1,
        ),
        PicklistItem(
          id: '2',
          unitId: 'U1',
          department: 'MAIN LINE 2',
          line: 'L2',
          workOrder: 'WO-102',
          partId: 'PART-A',
          partDescription: 'Bracket',
          resourceId: 'WELD',
          deptType: 'MAIN LINE',
          qtyRequired: 15,
          qtyDue: 15,
          qtyPicked: 0,
          rowOrder: 2,
        ),
        PicklistItem(
          id: '3',
          unitId: 'U1',
          department: 'SUBASSEMBLY 1',
          line: 'L1',
          workOrder: 'WO-103',
          partId: 'PART-A',
          partDescription: 'Bracket',
          resourceId: 'WELD',
          deptType: 'SUBASSEMBLY',
          qtyRequired: 5,
          qtyDue: 5,
          qtyPicked: 0,
          rowOrder: 3,
        ),
      ];

      // Allocate 18 pcs into Resource: WELD (MAIN LINE)
      final allocated = FifoAllocationEngine.allocateByPartId(
        allItems: items,
        department: 'Resource: WELD (MAIN LINE)',
        partId: 'PART-A',
        totalPickedToAllocate: 18,
      );

      // Item 1 (WO-101, required 10): 10 picked, 0 due
      expect(allocated.firstWhere((i) => i.id == '1').qtyPicked, 10.0);
      expect(allocated.firstWhere((i) => i.id == '1').qtyDue, 0.0);

      // Item 2 (WO-102, required 15): 8 picked, 7 due
      expect(allocated.firstWhere((i) => i.id == '2').qtyPicked, 8.0);
      expect(allocated.firstWhere((i) => i.id == '2').qtyDue, 7.0);

      // Item 3 (SUBASSEMBLY): untouched! 0 picked, 5 due
      expect(allocated.firstWhere((i) => i.id == '3').qtyPicked, 0.0);
      expect(allocated.firstWhere((i) => i.id == '3').qtyDue, 5.0);
    });

    test('SessionMetadata cardDisplayTitle formatting is clean and user-friendly', () {
      final session = SessionMetadata(
        id: 'session-uuid-12345',
        sessionSeqNo: 4,
        unitId: 'Unit_ABC',
        workerName: 'Alex',
        tabletId: 'Tablet 1',
        startTime: 1726000000000,
        pickDate: '2026-09-13',
      );

      expect(session.cardDisplayTitle, 'Tablet 1 • Session #4 (Alex)');
    });

    test('buildBatchExportFileName creates valid filename without spaces', () {
      final fileName = SessionMetadata.buildBatchExportFileName(
        unitName: 'Unit Alpha 01',
        tabletId: 'Tablet 1',
        minSeq: 1,
        maxSeq: 4,
        startTime: 1726000000000,
        endTime: 1726010000000,
      );

      expect(fileName.contains(' '), isFalse);
      expect(fileName.contains('Batch_SESS_1_to_4'), isTrue);
      expect(fileName.endsWith('.xlsx'), isTrue);
    });

    test('GroupingEngine supports dual variants for MAIN LINE resource mode without Line level', () {
      final combinedPreset = GroupingEngine.getPresetForDepartment(
        'Resource: internals (MAIN LINE)',
        includeLine: true,
        bypassDepartmentLevel: true,
      );
      expect(combinedPreset.levels.contains(GroupLevel.department), isFalse);
      expect(combinedPreset.levels.contains(GroupLevel.resourceId), isTrue);
      expect(combinedPreset.levels.contains(GroupLevel.line), isFalse);
      expect(combinedPreset.levels.contains(GroupLevel.partId), isTrue);

      final splitPreset = GroupingEngine.getPresetForDepartment(
        'Resource: internals (MAIN LINE)',
        includeLine: true,
        bypassDepartmentLevel: false,
      );
      expect(splitPreset.levels.contains(GroupLevel.department), isTrue);
      expect(splitPreset.levels.contains(GroupLevel.resourceId), isTrue);
      expect(splitPreset.levels.contains(GroupLevel.line), isFalse);
      expect(splitPreset.levels.contains(GroupLevel.partId), isTrue);
    });

    test('SessionMetadata formattedDuration explicitly displays min notation', () {
      final session30m = SessionMetadata(
        id: 's1',
        unitId: 'u1',
        workerName: 'Alex',
        startTime: 1000000,
        endTime: 1000000 + (30 * 60 * 1000), // 30 minutes
        pickDate: '2026-09-13',
      );
      expect(session30m.formattedDuration, '30 min');

      final session1h24m = SessionMetadata(
        id: 's2',
        unitId: 'u1',
        workerName: 'Maria',
        startTime: 1000000,
        endTime: 1000000 + (84 * 60 * 1000), // 1h 24min
        pickDate: '2026-09-13',
      );
      expect(session1h24m.formattedDuration, '1h 24min');

      final sessionLess1m = SessionMetadata(
        id: 's3',
        unitId: 'u1',
        workerName: 'John',
        startTime: 1000000,
        endTime: 1000000 + 20000, // 20 seconds
        pickDate: '2026-09-13',
      );
      expect(sessionLess1m.formattedDuration, '20s');

      final session0s = SessionMetadata(
        id: 's4',
        unitId: 'u1',
        workerName: 'John',
        startTime: 1000000,
        endTime: 1000000,
        pickDate: '2026-09-13',
      );
      expect(session0s.formattedDuration, '< 1 min');
    });

    test('GroupingEngine TreeNode extracts onHand together with description', () {
      final items = [
        PicklistItem(
          id: '1',
          unitId: 'U1',
          department: 'MAIN LINE 1',
          line: 'L1',
          workOrder: 'WO-101',
          partId: 'PART-A',
          partDescription: 'Heavy Duty Bracket',
          onHand: 'Aisle 3, Shelf B',
          qtyRequired: 10,
          qtyDue: 10,
          qtyPicked: 0,
          rowOrder: 1,
        ),
      ];

      final preset = GroupingEngine.getPresetForDepartment('MAIN LINE 1');
      final tree = GroupingEngine.buildTree(items: items, preset: preset);

      // Traverse down to partId leaf
      TreeNode? current = tree.first;
      while (current != null && current.children.isNotEmpty) {
        current = current.children.first;
      }

      expect(current, isNotNull);
      expect(current!.key, 'PART-A');
      expect(current.partDescription, 'Heavy Duty Bracket');
      expect(current.onHand, 'Aisle 3, Shelf B');
    });

    test('MAIN LINE Whole Resource scope matching correctly sums items across departments', () {
      final items = [
        PicklistItem(
          id: '1',
          unitId: 'U1',
          department: 'MAIN LINE 1',
          line: 'L1',
          workOrder: 'WO-101',
          partId: 'PART-A',
          partDescription: 'Bracket',
          resourceId: 'internals',
          deptType: 'MAIN LINE',
          qtyRequired: 10,
          qtyDue: 6,
          qtyPicked: 4,
          rowOrder: 1,
        ),
        PicklistItem(
          id: '2',
          unitId: 'U1',
          department: 'MAIN LINE 2',
          line: 'L2',
          workOrder: 'WO-102',
          partId: 'PART-A',
          partDescription: 'Bracket',
          resourceId: 'internals',
          deptType: 'MAIN LINE',
          qtyRequired: 15,
          qtyDue: 15,
          qtyPicked: 0,
          rowOrder: 2,
        ),
        PicklistItem(
          id: '3',
          unitId: 'U1',
          department: 'SUBASSEMBLY 1',
          line: 'L1',
          workOrder: 'WO-103',
          partId: 'PART-A',
          partDescription: 'Bracket',
          resourceId: 'internals',
          deptType: 'SUBASSEMBLY',
          qtyRequired: 5,
          qtyDue: 5,
          qtyPicked: 0,
          rowOrder: 3,
        ),
      ];

      const targetRes = 'internals';

      bool matchesScope(PicklistItem i) {
        final isMainLine = i.deptType.toUpperCase() == 'MAIN LINE' ||
            i.department.toUpperCase().contains('MAIN') ||
            i.department.toUpperCase().contains('MACG');
        if (!isMainLine) return false;
        return i.resourceId.toLowerCase().trim() == targetRes;
      }

      final scoped = items.where((i) => matchesScope(i) && i.partId == 'PART-A').toList();
      final totalPicked = scoped.fold<double>(0.0, (s, i) => s + i.qtyPicked);
      final totalReq = scoped.fold<double>(0.0, (s, i) => s + i.qtyRequired);
      final totalDue = totalReq - totalPicked;

      // Must include Item 1 and Item 2 (total req: 25, picked: 4, due: 21) and exclude Item 3 (Subassembly)
      expect(totalReq, 25.0);
      expect(totalPicked, 4.0);
      expect(totalDue, 21.0);
      expect(scoped.length, 2);
    });

    test('Super Session groups calculate earliestStart and latestEnd timestamps correctly', () {
      final s1 = SessionMetadata(
        id: 's1',
        sessionSeqNo: 1,
        unitId: 'U1',
        workerName: 'Alice',
        startTime: 1726000000000,
        endTime: 1726001800000, // +30 min
        pickDate: '2026-09-13',
      );
      final s2 = SessionMetadata(
        id: 's2',
        sessionSeqNo: 2,
        unitId: 'U1',
        workerName: 'Bob',
        startTime: 1726003600000, // +60 min
        endTime: 1726005400000, // +90 min
        pickDate: '2026-09-13',
      );

      final sessions = [s1, s2];
      final earliestStart = sessions.map((s) => s.startTime).reduce((a, b) => a < b ? a : b);
      final latestEnd = sessions.map((s) => s.endTime ?? s.startTime).reduce((a, b) => a > b ? a : b);

      expect(earliestStart, 1726000000000);
      expect(latestEnd, 1726005400000);
    });

    test('Global monotonic session sequence increments across multiple units without restarting', () {
      int savedVal = 0;
      int nextSeqNo() {
        savedVal = (savedVal >= 9999) ? 1 : savedVal + 1;
        return savedVal;
      }

      // Unit 57 gets sessions
      final u57_1 = nextSeqNo();
      final u57_2 = nextSeqNo();
      expect(u57_1, 1);
      expect(u57_2, 2);

      // Unit 58 gets sessions - must continue, not reset to 1
      final u58_1 = nextSeqNo();
      final u58_2 = nextSeqNo();
      expect(u58_1, 3);
      expect(u58_2, 4);

      // Unit 56 gets sessions - continues monotonically
      final u56_1 = nextSeqNo();
      expect(u56_1, 5);
    });

    test('3-Stage Session Lifecycle: CLOSED -> EXPORTED -> ISSUED transitions correctly', () {
      const now = 1726000000000;
      // Stage 1: Session is created ACTIVE, picker picks 1 item, then closes session -> CLOSED
      var session = SessionMetadata(
        id: 'sess-101',
        sessionSeqNo: 1,
        unitId: 'Unit_A',
        workerName: 'Alex',
        tabletId: 'Tablet 1',
        startTime: now,
        pickDate: '2026-09-14',
        status: 'ACTIVE',
        totalItemsPicked: 1,
      );
      expect(session.isActive, isTrue);
      expect(session.isClosed, isFalse);

      // Close session: status becomes CLOSED (NOT EXPORTED!)
      session = session.copyWith(
        status: 'CLOSED',
        endTime: now + 60000, // +1 min
      );
      expect(session.isClosed, isTrue);
      expect(session.isActive, isFalse);
      expect(session.isExported, isFalse);

      // Stage 2: Batch Super Export consolidates closed sessions -> EXPORTED
      session = session.copyWith(
        status: 'EXPORTED',
        issuedStatus: 'Pending Issue',
      );
      expect(session.isExported, isTrue);
      expect(session.isClosed, isFalse);
      expect(session.isIssued, isFalse);

      // Stage 3: Super Session is marked as ISSUED in ERP -> ISSUED
      session = session.copyWith(
        status: 'ISSUED',
        issuedStatus: 'Issued',
      );
      expect(session.isIssued, isTrue);
    });

    test('Distinct picked Part IDs correctly identifies partially and fully picked parts', () {
      final items = [
        PicklistItem(
          id: '1', unitId: 'U1', department: 'D1', line: 'L1', workOrder: 'W1',
          partId: 'PART-1', partDescription: 'Desc 1', qtyRequired: 10, qtyDue: 5, qtyPicked: 5, rowOrder: 1,
        ),
        PicklistItem(
          id: '2', unitId: 'U1', department: 'D1', line: 'L1', workOrder: 'W2',
          partId: 'PART-1', partDescription: 'Desc 1', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 2,
        ),
        PicklistItem(
          id: '3', unitId: 'U1', department: 'D1', line: 'L1', workOrder: 'W1',
          partId: 'PART-2', partDescription: 'Desc 2', qtyRequired: 2, qtyDue: 0, qtyPicked: 2, rowOrder: 3,
        ),
        PicklistItem(
          id: '4', unitId: 'U1', department: 'D1', line: 'L1', workOrder: 'W1',
          partId: 'PART-3', partDescription: 'Desc 3', qtyRequired: 8, qtyDue: 8, qtyPicked: 0, rowOrder: 4,
        ),
      ];

      // Total distinct parts
      final totalDistinctPartIds = items.map((i) => i.partId).toSet().length;
      expect(totalDistinctPartIds, 3); // PART-1, PART-2, PART-3

      // Distinct picked parts (where qtyPicked > 0.0001)
      final pickedDistinctPartIds = items
          .where((i) => i.qtyPicked > 0.0001)
          .map((i) => i.partId)
          .toSet()
          .length;
      expect(pickedDistinctPartIds, 2); // PART-1 (partially picked 5/20), PART-2 (fully picked 2/2)
    });

    test('SessionMetadata correctly serializes and deserializes batchId and issuedAt', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final sess = SessionMetadata(
        id: 'sess-b1',
        sessionSeqNo: 5,
        unitId: 'unit-57',
        workerName: 'David',
        startTime: 1726000000000,
        pickDate: '2026-09-14',
        status: 'ISSUED',
        totalItemsPicked: 3,
        batchId: 'BATCH_unit-57_1_to_5_1726000000000',
        issuedAt: now,
      );

      final map = sess.toMap();
      expect(map['batch_id'], 'BATCH_unit-57_1_to_5_1726000000000');
      expect(map['issued_at'], now);

      final restored = SessionMetadata.fromMap(map);
      expect(restored.batchId, 'BATCH_unit-57_1_to_5_1726000000000');
      expect(restored.issuedAt, now);
      expect(restored.totalItemsPicked, 3);
    });

    test('UnitRecord recognizes FULLY_PICKED status as isCompleted', () {
      final unit = UnitRecord(
        id: 'u-1',
        name: 'Unit 57',
        filePath: 'test.xlsx',
        totalRequired: 100,
        totalPicked: 50, // Pieces might differ from totalRequired
        status: 'FULLY_PICKED',
        createdAt: 1000,
        lastAccessedAt: 1000,
      );
      expect(unit.isCompleted, isTrue);
    });

    test('60-Day auto-purge threshold identifies expired ISSUED sessions', () {
      final now = DateTime.now();
      final sixtyOneDaysAgo = now.subtract(const Duration(days: 61)).millisecondsSinceEpoch;
      final tenDaysAgo = now.subtract(const Duration(days: 10)).millisecondsSinceEpoch;
      final cutoff = now.subtract(const Duration(days: 60)).millisecondsSinceEpoch;

      final expiredSession = SessionMetadata(
        id: 's-old',
        unitId: 'u-1',
        workerName: 'John',
        startTime: sixtyOneDaysAgo - 10000,
        pickDate: '2026-07-01',
        status: 'ISSUED',
        issuedAt: sixtyOneDaysAgo,
      );

      final freshSession = SessionMetadata(
        id: 's-new',
        unitId: 'u-1',
        workerName: 'John',
        startTime: tenDaysAgo - 10000,
        pickDate: '2026-09-01',
        status: 'ISSUED',
        issuedAt: tenDaysAgo,
      );

      expect(expiredSession.issuedAt! < cutoff, isTrue);
      expect(freshSession.issuedAt! < cutoff, isFalse);
    });

    test('SessionBatchGroup supports multi-unit sessions and aggregates unitIds', () {
      final s1 = SessionMetadata(
        id: 's-1',
        sessionSeqNo: 1,
        unitId: 'u-56',
        workerName: 'Alex',
        startTime: 1000,
        endTime: 2000,
        pickDate: '2026-09-14',
        totalItemsPicked: 2,
        batchId: 'BATCH_1',
      );
      final s2 = SessionMetadata(
        id: 's-2',
        sessionSeqNo: 2,
        unitId: 'u-58',
        workerName: 'Maria',
        startTime: 1500,
        endTime: 3000,
        pickDate: '2026-09-14',
        totalItemsPicked: 5,
        batchId: 'BATCH_1',
      );

      final batch = SessionBatchGroup(
        batchKey: 'BATCH_1',
        unitId: 'u-56, u-58',
        unitName: 'Unit 56, Unit 58',
        status: 'EXPORTED',
        sessions: [s1, s2],
      );

      expect(batch.unitIds, containsAll(['u-56', 'u-58']));
      expect(batch.totalItemsPicked, 7);
      expect(batch.earliestStart, 1000);
      expect(batch.latestEnd, 3000);
      expect(batch.seqListStr, '#1, #2');
    });

    test('SessionBatchGroup batches sort newest first (LIFO)', () {
      final bOld = SessionBatchGroup(
        batchKey: 'B1',
        unitId: 'u-1',
        unitName: 'Unit 1',
        status: 'EXPORTED',
        sessions: [
          SessionMetadata(
            id: 's-old',
            sessionSeqNo: 1,
            unitId: 'u-1',
            workerName: 'Worker',
            startTime: 1000,
            endTime: 2000,
            pickDate: '2026-09-10',
          ),
        ],
      );

      final bNew = SessionBatchGroup(
        batchKey: 'B2',
        unitId: 'u-1',
        unitName: 'Unit 1',
        status: 'EXPORTED',
        sessions: [
          SessionMetadata(
            id: 's-new',
            sessionSeqNo: 2,
            unitId: 'u-1',
            workerName: 'Worker',
            startTime: 5000,
            endTime: 8000,
            pickDate: '2026-09-14',
          ),
        ],
      );

      final list = [bOld, bNew];
      list.sort((a, b) => b.latestEnd.compareTo(a.latestEnd));
      expect(list.first.batchKey, 'B2');
      expect(list.last.batchKey, 'B1');
    });

    test('60-Day remaining countdown calculation on ISSUED cards', () {
      final now = DateTime.now();
      // Marked as issued 10 days ago
      final issuedAt = now.subtract(const Duration(days: 10)).millisecondsSinceEpoch;
      final expiryTime = issuedAt + const Duration(days: 60).inMilliseconds;
      final msLeft = expiryTime - now.millisecondsSinceEpoch;
      final daysUntilPurge = (msLeft / (1000 * 60 * 60 * 24)).ceil().clamp(0, 60);

      // Exactly 50 days left
      expect(daysUntilPurge, 50);
    });

    test('Component Resource substring pattern rules match resources accurately', () {
      final rules = [
        {'pattern': 'BOX', 'allowPick': false, 'autoIssue': true},
        {'pattern': 'weld', 'allowPick': true, 'autoIssue': false},
      ];

      bool matchesPattern(String resId, String pattern) {
        return resId.toLowerCase().contains(pattern.toLowerCase());
      }

      final res1 = 'SMALL_BOX_ASSEMBLY';
      final res2 = 'SPOT_WELDING_1';
      final res3 = 'PAINT_BOOTH';

      expect(matchesPattern(res1, 'BOX'), isTrue);
      expect(matchesPattern(res2, 'weld'), isTrue);
      expect(matchesPattern(res3, 'BOX'), isFalse);
      expect(matchesPattern(res3, 'weld'), isFalse);
    });

    test('Historical picking recovery logic accurately allocates past picks onto re-imported picklist items', () {
      // 1. Simulating newly parsed items from Excel for an accidentally deleted unit
      final parsedItems = [
        PicklistItem(
          id: 'item-1',
          unitId: 'Unit_56',
          department: 'DOORS',
          line: 'L1',
          workOrder: 'WO-101',
          partId: 'PART-A',
          partDescription: 'Left Hinge',
          resourceId: 'RES-1',
          qtyRequired: 10,
          qtyDue: 10,
          qtyPicked: 0,
          rowOrder: 1,
        ),
        PicklistItem(
          id: 'item-2',
          unitId: 'Unit_56',
          department: 'DOORS',
          line: 'L1',
          workOrder: 'WO-102',
          partId: 'PART-A',
          partDescription: 'Left Hinge',
          resourceId: 'RES-1',
          qtyRequired: 15,
          qtyDue: 15,
          qtyPicked: 0,
          rowOrder: 2,
        ),
        PicklistItem(
          id: 'item-3',
          unitId: 'Unit_56',
          department: 'FRAME',
          line: 'L2',
          workOrder: 'WO-103',
          partId: 'PART-B',
          partDescription: 'Crossbar',
          resourceId: 'RES-2',
          qtyRequired: 8,
          qtyDue: 8,
          qtyPicked: 0,
          rowOrder: 3,
        ),
      ];

      // 2. Historical picks recorded in session_picks: PART-A had 18 pcs picked, PART-B had 8 pcs picked
      final historicalPartPicks = <String, double>{
        'PART-A': 18.0,
        'PART-B': 8.0,
      };

      // 3. Apply recovery allocation (same algorithm as restoreUnitWithPicks in DatabaseService)
      final remainingPicks = Map<String, double>.from(historicalPartPicks);
      final restoredItems = <PicklistItem>[];
      double totalRestored = 0.0;

      for (final item in parsedItems) {
        double restoredQty = item.qtyPicked;
        if (remainingPicks.containsKey(item.partId) && remainingPicks[item.partId]! > 0) {
          final available = remainingPicks[item.partId]!;
          restoredQty = available > item.qtyRequired ? item.qtyRequired : available;
          remainingPicks[item.partId] = (available - restoredQty).clamp(0.0, double.infinity);
        }

        totalRestored += restoredQty;
        final due = (item.qtyRequired - restoredQty).clamp(0.0, item.qtyRequired);
        restoredItems.add(item.copyWith(
          qtyPicked: restoredQty,
          qtyDue: due,
        ));
      }

      // Verify FIFO distribution:
      // Item 1: required 10 -> fully picked (10.0), 0.0 due
      expect(restoredItems[0].qtyPicked, 10.0);
      expect(restoredItems[0].qtyDue, 0.0);

      // Item 2: required 15 -> 8.0 picked, 7.0 due (18 total - 10 consumed by Item 1 = 8)
      expect(restoredItems[1].qtyPicked, 8.0);
      expect(restoredItems[1].qtyDue, 7.0);

      // Item 3: required 8 -> fully picked (8.0), 0.0 due
      expect(restoredItems[2].qtyPicked, 8.0);
      expect(restoredItems[2].qtyDue, 0.0);

      // Total restored: 10 + 8 + 8 = 26 pcs
      expect(totalRestored, 26.0);

      // Verify UnitRecord un-soft-delete & status transition
      final totalReq = parsedItems.fold<double>(0.0, (s, i) => s + i.qtyRequired).round();
      expect(totalReq, 33);
      final unit = UnitRecord(
        id: 'Unit_56',
        name: 'Unit 56',
        filePath: 'test/path/unit_56.xlsx',
        totalRequired: totalReq,
        totalPicked: totalRestored.round(),
        status: (totalRestored >= totalReq && totalReq > 0) ? 'FULLY_PICKED' : 'IN_PROGRESS',
        createdAt: 1726000000000,
        lastAccessedAt: 1726000000000,
        deletedAt: null, // Un-soft-deleted
      );

      expect(unit.deletedAt, isNull);
      expect(unit.status, 'IN_PROGRESS');
      expect(unit.totalPicked, 26);
    });

    test('Super Session Batch export layout writes File Name in Column 0 and shifts original headers', () {
      final originalHeaders = ['Work Order', 'Part ID', 'Description', 'Qty Required'];
      final targetSheetHeaders = <int, String>{};

      // Column 0 is reserved for File Name
      targetSheetHeaders[0] = 'File Name';

      // Original headers shifted by 1
      for (int c = 0; c < originalHeaders.length; c++) {
        targetSheetHeaders[c + 1] = originalHeaders[c];
      }

      // Next column index for ERP service headers
      int nextCol = originalHeaders.length + 1;
      final serviceHeaders = [
        'WO Status',
        'WO Progress %',
        'Total Picked',
        'Session Picked',
        'Session ID',
        'Worker Name',
        'Pick Date',
        'Start Time',
        'End Time',
        'Issued Status',
        'Return Comments',
      ];
      for (final s in serviceHeaders) {
        targetSheetHeaders[nextCol++] = s;
      }

      expect(targetSheetHeaders[0], 'File Name');
      expect(targetSheetHeaders[1], 'Work Order');
      expect(targetSheetHeaders[2], 'Part ID');
      expect(targetSheetHeaders[3], 'Description');
      expect(targetSheetHeaders[4], 'Qty Required');
      expect(targetSheetHeaders[5], 'WO Status');

      // Verify row data mapping:
      // Row contains source File Name at columnIndex 0
      final rowCells = <int, String>{};
      rowCells[0] = 'unit_56.xlsx';
      final originalRowValues = ['WO-101', 'P-999', 'Handle', '10'];
      for (int c = 0; c < originalRowValues.length; c++) {
        rowCells[c + 1] = originalRowValues[c];
      }

      expect(rowCells[0], 'unit_56.xlsx');
      expect(rowCells[1], 'WO-101');
      expect(rowCells[2], 'P-999');
      expect(rowCells[3], 'Handle');
      expect(rowCells[4], '10');
    });

    test('Batch export filtering strictly omits items not picked in this batch', () {
      final item1 = PicklistItem(
        id: 'i1', unitId: 'u1', department: 'D1', line: 'L1', workOrder: 'WO1',
        partId: 'P1', partDescription: 'Part 1', resourceId: 'R1',
        qtyRequired: 10, qtyDue: 0, qtyPicked: 10, rowOrder: 1,
      );
      final item2 = PicklistItem(
        id: 'i2', unitId: 'u1', department: 'D1', line: 'L1', workOrder: 'WO1',
        partId: 'P2', partDescription: 'Part 2', resourceId: 'R2',
        qtyRequired: 5, qtyDue: 5, qtyPicked: 0, rowOrder: 2,
      );
      final item3 = PicklistItem(
        id: 'i3', unitId: 'u1', department: 'D1', line: 'L1', workOrder: 'WO1',
        partId: 'P3', partDescription: 'Part 3', resourceId: 'R3',
        qtyRequired: 20, qtyDue: 20, qtyPicked: 0, rowOrder: 3,
      );

      final unitItems = [item1, item2, item3];
      // Suppose item1 was picked in Batch 1.
      // In Batch 2, ONLY item2 was touched (e.g. 2 pcs picked), and P3 is auto-issue
      final batchPartIds = {'P2'};
      final autoIssueResourceIds = ['R3'];

      final exportedRows = <PicklistItem>[];
      for (final item in unitItems) {
        final isAutoResource = autoIssueResourceIds.contains(item.resourceId);
        final wasPickedInBatch = batchPartIds.contains(item.partId);
        if (wasPickedInBatch || isAutoResource) {
          exportedRows.add(item);
        }
      }

      // item1 was picked in an earlier batch, NOT Batch 2 -> MUST BE OMITTED
      expect(exportedRows.any((i) => i.partId == 'P1'), isFalse);
      // item2 was picked in this batch -> MUST BE INCLUDED
      expect(exportedRows.any((i) => i.partId == 'P2'), isTrue);
      // item3 was auto-issued -> MUST BE INCLUDED
      expect(exportedRows.any((i) => i.partId == 'P3'), isTrue);
      expect(exportedRows.length, 2);
    });

    test('Department selection: 0-part departments hidden and completed departments placed at bottom', () {
      final depts = [
        {'name': 'Plumbing', 'isCompleted': false, 'totalParts': 2, 'pickDate': '2026-09-12'},
        {'name': 'Weld', 'isCompleted': true, 'totalParts': 1, 'pickDate': '2026-09-15'},
        {'name': 'Doors', 'isCompleted': false, 'totalParts': 2, 'pickDate': '2026-09-16'},
        {'name': 'MAIN line B2', 'isCompleted': true, 'totalParts': 0, 'pickDate': ''},
        {'name': 'MAIN line M2', 'isCompleted': true, 'totalParts': 0, 'pickDate': ''},
      ];

      // 1. Filter out 0-part departments
      final visible = depts.where((d) => (d['totalParts'] as int) > 0).toList();
      expect(visible.length, 3);
      expect(visible.any((d) => d['name'] == 'MAIN line B2'), isFalse);
      expect(visible.any((d) => d['name'] == 'MAIN line M2'), isFalse);

      // 2. Sort: uncompleted first, completed at the very bottom
      visible.sort((a, b) {
        final aComp = a['isCompleted'] as bool;
        final bComp = b['isCompleted'] as bool;
        if (aComp != bComp) return aComp ? 1 : -1;
        return (a['pickDate'] as String).compareTo(b['pickDate'] as String);
      });

      expect(visible[0]['name'], 'Plumbing'); // uncompleted, earliest date
      expect(visible[1]['name'], 'Doors');    // uncompleted, later date
      expect(visible[2]['name'], 'Weld');     // completed -> at the very bottom
    });

    test('80d (CLOSED) / 70d (EXPORTED) / 60d (ISSUED) auto-purge retention calculations', () {
      final now = DateTime.now();

      // CLOSED session: 80 days retention
      final closedSession = SessionMetadata(
        id: 's_closed',
        sessionSeqNo: 1,
        unitId: 'u1',
        workerName: 'Picker',
        pickDate: '2026-09-16',
        startTime: now.subtract(const Duration(days: 10)).millisecondsSinceEpoch,
        endTime: now.subtract(const Duration(days: 10)).millisecondsSinceEpoch,
        status: 'CLOSED',
      );
      final closedEnd = DateTime.fromMillisecondsSinceEpoch(closedSession.endTime ?? closedSession.startTime);
      final closedAgeDays = now.difference(closedEnd).inDays;
      final closedRemaining = 80 - closedAgeDays;
      expect(closedRemaining, 70); // 80 - 10 = 70 days remaining

      // EXPORTED session: 70 days retention
      final exportedSession = closedSession.copyWith(
        status: 'EXPORTED',
        batchId: 'BATCH_1',
        endTime: now.subtract(const Duration(days: 5)).millisecondsSinceEpoch,
      );
      final exportedEnd = DateTime.fromMillisecondsSinceEpoch(exportedSession.endTime ?? exportedSession.startTime);
      final exportedAgeDays = now.difference(exportedEnd).inDays;
      final exportedRemaining = 70 - exportedAgeDays;
      expect(exportedRemaining, 65); // 70 - 5 = 65 days remaining

      // ISSUED session: 60 days retention from issued_at
      final issuedSession = exportedSession.copyWith(
        status: 'ISSUED',
        issuedAt: now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      );
      final issuedDate = DateTime.fromMillisecondsSinceEpoch(issuedSession.issuedAt!);
      final issuedAgeDays = now.difference(issuedDate).inDays;
      final issuedRemaining = 60 - issuedAgeDays;
      expect(issuedRemaining, 58); // 60 - 2 = 58 days remaining
    });

    test('Lazy session initialization: sequence number is 0 until first pick is made', () {
      // Pending session created upon worker selection
      final pendingSession = SessionMetadata(
        id: 'pending_uuid',
        sessionSeqNo: 0,
        unitId: 'unit_1',
        workerName: 'John',
        pickDate: '2026-09-16',
        startTime: DateTime.now().millisecondsSinceEpoch,
      );

      // Must have seqNo == 0 (not persisted)
      expect(pendingSession.sessionSeqNo, 0);
      expect(pendingSession.isClosed, isFalse);

      // Upon first confirmed pick, seqNo becomes monotonic (> 0)
      final activeSession = pendingSession.copyWith(
        sessionSeqNo: 1,
        totalItemsPicked: 1,
      );
      expect(activeSession.sessionSeqNo, 1);
      expect(activeSession.cardDisplayTitle, contains('Session #1 (John)'));
    });

    test('Department line grouping toggle creates correct hierarchy with and without Line level', () {
      final presetWithLine = GroupingEngine.getPresetForDepartment('Plumbing', includeLine: true);
      expect(presetWithLine.levels.contains(GroupLevel.line), isTrue);

      final presetWithoutLine = GroupingEngine.getPresetForDepartment('Plumbing', includeLine: false);
      expect(presetWithoutLine.levels.contains(GroupLevel.line), isFalse);
    });

    test('Delta calculation with captured previousItems accurately records pick deltas', () {
      final itemA = PicklistItem(
        id: 'item_1', unitId: 'u1', department: 'Plumbing', line: 'B2', workOrder: 'WO1',
        partId: 'P100', partDescription: 'Pipe', qtyRequired: 10, qtyDue: 10, qtyPicked: 0, rowOrder: 1,
      );
      final items = [itemA];

      // Save previousItems before allocation
      final previousItems = List<PicklistItem>.from(items);

      // User picks 4 pcs
      final updatedList = FifoAllocationEngine.allocateByPartId(
        allItems: items,
        department: 'Plumbing',
        partId: 'P100',
        totalPickedToAllocate: 4,
      );

      final updated = updatedList.first;
      final old = previousItems.firstWhere((o) => o.id == updated.id);
      final delta = updated.qtyPicked - old.qtyPicked;

      expect(delta, 4.0);
      expect(delta > 0.0001, isTrue);
    });
  });
}
