import '../lib/engine/column_mapper.dart';
import '../lib/engine/fifo_allocation_engine.dart';
import '../lib/engine/grouping_engine.dart';
import '../lib/models/grouping_preset.dart';
import '../lib/models/picklist_item.dart';
import '../lib/models/unit_pick_date_urgency.dart';
import '../lib/models/unit_record.dart';
import '../lib/services/log_service.dart';

void main() {
  print('=== Running Pick List Tracker Verification Tests ===\n');

  int passed = 0;
  int failed = 0;

  void test(String description, void Function() body) {
    try {
      body();
      print(' [PASS] $description');
      passed++;
    } catch (e, stack) {
      print(' [FAIL] $description');
      print('        Error: $e');
      print('        $stack');
      failed++;
    }
  }

  void expect(dynamic actual, dynamic expected, [String? message]) {
    if (actual is List && expected is List) {
      if (actual.length != expected.length) {
        throw Exception('Expected list of length ${expected.length} but got ${actual.length}. ${message ?? ""}');
      }
      for (int i = 0; i < actual.length; i++) {
        if (actual[i] != expected[i]) {
          throw Exception('Expected element at index $i to be <${expected[i]}> but got <${actual[i]}>. ${message ?? ""}');
        }
      }
      return;
    }
    if (actual != expected) {
      throw Exception('Expected <$expected> but got <$actual>. ${message ?? ""}');
    }
  }

  // --- TEST SUITE 1: FIFO ALLOCATION & DEPARTMENT ISOLATION ---
  test('FIFO Allocation distributes 168 pieces correctly across Work Orders', () {
    final items = [
      PicklistItem(
        id: '1',
        unitId: 'U1',
        department: 'Hardware',
        line: 'Line 1',
        workOrder: 'WO-1',
        partId: 'BRK-001',
        partDescription: 'Bracket A',
        qtyRequired: 50,
        qtyDue: 50,
        qtyPicked: 0,
        rowOrder: 1,
      ),
      PicklistItem(
        id: '2',
        unitId: 'U1',
        department: 'Hardware',
        line: 'Line 1',
        workOrder: 'WO-2',
        partId: 'BRK-001',
        partDescription: 'Bracket A',
        qtyRequired: 100,
        qtyDue: 100,
        qtyPicked: 0,
        rowOrder: 2,
      ),
      PicklistItem(
        id: '3',
        unitId: 'U1',
        department: 'Hardware',
        line: 'Line 2',
        workOrder: 'WO-3',
        partId: 'BRK-001',
        partDescription: 'Bracket A',
        qtyRequired: 32,
        qtyDue: 32,
        qtyPicked: 0,
        rowOrder: 3,
      ),
      PicklistItem(
        id: '4',
        unitId: 'U1',
        department: 'Hardware',
        line: 'Line 2',
        workOrder: 'WO-4',
        partId: 'BRK-001',
        partDescription: 'Bracket A',
        qtyRequired: 50,
        qtyDue: 50,
        qtyPicked: 0,
        rowOrder: 4,
      ),
    ];

    final allocated = FifoAllocationEngine.allocateByPartId(
      allItems: items,
      department: 'Hardware',
      partId: 'BRK-001',
      totalPickedToAllocate: 168,
    );

    expect(allocated[0].qtyPicked, 50, 'WO-1 should be fully closed (50/50)');
    expect(allocated[0].qtyDue, 0);

    expect(allocated[1].qtyPicked, 100, 'WO-2 should be fully closed (100/100)');
    expect(allocated[1].qtyDue, 0);

    expect(allocated[2].qtyPicked, 18, 'WO-3 should have remaining 18 allocated (18/32)');
    expect(allocated[2].qtyDue, 14, 'WO-3 due should be 14');

    expect(allocated[3].qtyPicked, 0, 'WO-4 should have 0 allocated (0/50)');
    expect(allocated[3].qtyDue, 50, 'WO-4 due should be 50');
  });

  test('FIFO Allocation STRICTLY isolates by department (other depts untouched)', () {
    final items = [
      PicklistItem(
        id: 'hw_1',
        unitId: 'U1',
        department: 'Hardware',
        line: 'L1',
        workOrder: 'WO-10',
        partId: 'BRK-001',
        partDescription: 'Bracket',
        qtyRequired: 100,
        qtyDue: 100,
        qtyPicked: 0,
        rowOrder: 1,
      ),
      PicklistItem(
        id: 'chassis_1',
        unitId: 'U1',
        department: 'Chassis',
        line: 'L2',
        workOrder: 'WO-99',
        partId: 'BRK-001', // Same Part ID, different Department!
        partDescription: 'Bracket',
        qtyRequired: 80,
        qtyDue: 80,
        qtyPicked: 0,
        rowOrder: 2,
      ),
    ];

    final allocated = FifoAllocationEngine.allocateByPartId(
      allItems: items,
      department: 'Hardware',
      partId: 'BRK-001',
      totalPickedToAllocate: 75,
    );

    // Hardware got 75
    expect(allocated[0].qtyPicked, 75);
    expect(allocated[0].qtyDue, 25);

    // Chassis MUST remain 0!
    expect(allocated[1].qtyPicked, 0, 'Chassis department must NOT be affected!');
    expect(allocated[1].qtyDue, 80);
  });

  // --- TEST SUITE 2: DYNAMIC COLUMN MAPPER & NORMALIZATION ---
  test('ColumnMapper normalizes case and handles variations', () {
    final mapper = ColumnMapper();

    expect(mapper.identifyColumn('unit'), ColumnMapper.keyUnit);
    expect(mapper.identifyColumn('UNIT NUMBER'), ColumnMapper.keyUnit);
    expect(mapper.identifyColumn('dept'), ColumnMapper.keyDepartment);
    expect(mapper.identifyColumn('AREA'), ColumnMapper.keyDepartment);
    expect(mapper.identifyColumn('PROD LINE'), ColumnMapper.keyLine);
    expect(mapper.identifyColumn('WO#'), ColumnMapper.keyWorkOrder);
    expect(mapper.identifyColumn('Work Order'), ColumnMapper.keyWorkOrder);
    expect(mapper.identifyColumn('part id'), ColumnMapper.keyPartId);
    expect(mapper.identifyColumn('Part Description'), ColumnMapper.keyPartDescription);
    expect(mapper.identifyColumn('Qty Required'), ColumnMapper.keyQtyRequired);
    expect(mapper.identifyColumn('REQ QTY'), ColumnMapper.keyQtyRequired);
    expect(mapper.identifyColumn('Qty Due'), ColumnMapper.keyQtyDue);
    expect(mapper.identifyColumn('Qty Picked'), ColumnMapper.keyQtyPicked);
    expect(mapper.identifyColumn('PICKED'), ColumnMapper.keyQtyPicked);
  });

  test('ColumnMapper allows adding custom aliases dynamically', () {
    final mapper = ColumnMapper();
    mapper.addAlias(ColumnMapper.keyPartId, 'CUSTOM_SKU_123');
    expect(mapper.identifyColumn('custom_sku_123'), ColumnMapper.keyPartId);
  });

  // --- TEST SUITE 3: GROUPING ENGINE & FILTERING ---
  test('GroupingEngine respects active departments filter', () {
    final items = [
      PicklistItem(
        id: '1',
        unitId: 'UnitX',
        department: 'Assembly',
        line: 'L1',
        workOrder: 'WO-1',
        partId: 'P1',
        partDescription: 'Part 1',
        qtyRequired: 10,
        qtyDue: 10,
        qtyPicked: 10,
        rowOrder: 1,
      ),
      PicklistItem(
        id: '2',
        unitId: 'UnitX',
        department: 'Paint',
        line: 'L2',
        workOrder: 'WO-2',
        partId: 'P2',
        partDescription: 'Part 2',
        qtyRequired: 20,
        qtyDue: 20,
        qtyPicked: 0,
        rowOrder: 2,
      ),
    ];

    final preset = const GroupingPreset(
      id: 'preset_unit_dept_part',
      name: 'Unit -> Dept -> Part',
      levels: [GroupLevel.unit, GroupLevel.department, GroupLevel.partId],
    );
    final tree = GroupingEngine.buildTree(
      items: items,
      preset: preset,
      activeDepartments: {'Assembly'}, // Only Assembly allowed on this tablet!
    );

    expect(tree.length, 1);
    final unitNode = tree.first;
    expect(unitNode.children.length, 1);
    expect(unitNode.children.first.key, 'Assembly');
    expect(unitNode.children.any((c) => c.key == 'Paint'), false, 'Paint must be excluded');
  });

  // --- TEST SUITE 4: NEW COLUMNS & WORK ORDER (WO) PARENTHESES NORMALIZATION ---
  test('ColumnMapper normalizes Work Order (WO), Pick date, and Prod date headers', () {
    final mapper = ColumnMapper();
    expect(mapper.identifyColumn('Work Order (WO)'), ColumnMapper.keyWorkOrder);
    expect(mapper.identifyColumn('WORK ORDER (WO)'), ColumnMapper.keyWorkOrder);
    expect(mapper.identifyColumn('Pick date'), ColumnMapper.keyPickDate);
    expect(mapper.identifyColumn('PICK DATE'), ColumnMapper.keyPickDate);
    expect(mapper.identifyColumn('Prod date'), ColumnMapper.keyProdDate);
    expect(mapper.identifyColumn('PROD DATE'), ColumnMapper.keyProdDate);
    expect(mapper.identifyColumn('Production Date'), ColumnMapper.keyProdDate);
  });

  // --- TEST SUITE 5: EQUAL-WEIGHTED WORK ORDER PROGRESS (PART ID WEIGHT 50/50) ---
  test('Equal-weighted Work Order progress counts each Part ID as 1 entry', () {
    // 2 parts in WO-100:
    // Part A: 10,000 required, 10,000 picked (1.0 ratio)
    // Part B: 2 required, 0 picked (0.0 ratio)
    // Progress should be (1.0 + 0.0) / 2 = 50.0%
    final items = [
      PicklistItem(
        id: '1',
        unitId: 'Unit55',
        department: 'Assembly',
        line: 'L1',
        workOrder: 'WO-100',
        partId: 'PART-A',
        partDescription: 'Bulk Screws',
        qtyRequired: 10000,
        qtyDue: 10000,
        qtyPicked: 10000,
        rowOrder: 1,
      ),
      PicklistItem(
        id: '2',
        unitId: 'Unit55',
        department: 'Assembly',
        line: 'L1',
        workOrder: 'WO-100',
        partId: 'PART-B',
        partDescription: 'Special Bracket',
        qtyRequired: 2,
        qtyDue: 2,
        qtyPicked: 0,
        rowOrder: 2,
      ),
    ];

    // Simulate the logic used in ExcelService.exportAndOverwrite
    final Map<String, Map<String, List<PicklistItem>>> woPartMap = {};
    for (final item in items) {
      woPartMap.putIfAbsent(item.workOrder, () => {});
      woPartMap[item.workOrder]!.putIfAbsent(item.partId, () => []).add(item);
    }

    final Map<String, double> woProgressMap = {};
    final Map<String, String> woStatusMap = {};

    for (final entry in woPartMap.entries) {
      final wo = entry.key;
      final partEntries = entry.value;
      if (partEntries.isEmpty) continue;

      double totalPartRatios = 0.0;
      int fullyPickedPartsCount = 0;

      for (final partList in partEntries.values) {
        final req = partList.fold<double>(0.0, (sum, i) => sum + i.qtyRequired);
        final picked = partList.fold<double>(0.0, (sum, i) => sum + i.qtyPicked);
        final ratio = req > 0 ? (picked / req).clamp(0.0, 1.0) : 1.0;
        totalPartRatios += ratio;
        if (picked >= req && req > 0) {
          fullyPickedPartsCount++;
        }
      }

      final avgRatio = totalPartRatios / partEntries.length;
      final progressPercent = (avgRatio * 100).roundToDouble();
      woProgressMap[wo] = progressPercent;

      if (fullyPickedPartsCount == partEntries.length) {
        woStatusMap[wo] = 'Fully Picked';
      } else if (totalPartRatios > 0.0) {
        woStatusMap[wo] = 'Partially Picked';
      } else {
        woStatusMap[wo] = 'Not Picked';
      }
    }

    expect(woProgressMap['WO-100'], 50.0, '10k screws + 0/2 brackets must be 50%');
    expect(woStatusMap['WO-100'], 'Partially Picked');

    // Now test when Part B is fully picked too
    final updatedItemB = items[1].copyWith(qtyPicked: 2);
    final updatedItems = [items[0], updatedItemB];

    final Map<String, Map<String, List<PicklistItem>>> woPartMap2 = {};
    for (final item in updatedItems) {
      woPartMap2.putIfAbsent(item.workOrder, () => {});
      woPartMap2[item.workOrder]!.putIfAbsent(item.partId, () => []).add(item);
    }

    double totalPartRatios2 = 0.0;
    int fullyPicked2 = 0;
    for (final partList in woPartMap2['WO-100']!.values) {
      final req = partList.fold<double>(0.0, (sum, i) => sum + i.qtyRequired);
      final picked = partList.fold<double>(0.0, (sum, i) => sum + i.qtyPicked);
      final ratio = req > 0 ? (picked / req).clamp(0.0, 1.0) : 1.0;
      totalPartRatios2 += ratio;
      if (picked >= req && req > 0) fullyPicked2++;
    }

    final avgRatio2 = totalPartRatios2 / woPartMap2['WO-100']!.length;
    expect((avgRatio2 * 100).roundToDouble(), 100.0);
    expect(fullyPicked2 == woPartMap2['WO-100']!.length, true);
  });

  // --- TEST SUITE 6: MULTI-UNIT BATCH SUPPORT VIA subUnit ---
  test('GroupingEngine correctly groups rows with different subUnits in the same file', () {
    final fileUnitItems = [
      PicklistItem(
        id: '1',
        unitId: 'Batch_File_2026',
        subUnit: 'Unit-55',
        department: 'Assembly',
        line: 'L1',
        workOrder: 'WO-1',
        partId: 'P1',
        partDescription: 'Part 1',
        qtyRequired: 10,
        qtyDue: 10,
        qtyPicked: 0,
        rowOrder: 1,
      ),
      PicklistItem(
        id: '2',
        unitId: 'Batch_File_2026',
        subUnit: 'Unit-56',
        department: 'Assembly',
        line: 'L1',
        workOrder: 'WO-2',
        partId: 'P2',
        partDescription: 'Part 2',
        qtyRequired: 20,
        qtyDue: 20,
        qtyPicked: 0,
        rowOrder: 2,
      ),
    ];

    final tree = GroupingEngine.buildTree(
      items: fileUnitItems,
      preset: GroupingPreset.defaultPresets.firstWhere((p) => p.id == 'preset_subassembly'),
    );

    expect(tree.length, 2, 'Should create 2 unit root nodes for Unit-55 and Unit-56');
    expect(tree.any((n) => n.key == 'Unit-55'), true);
    expect(tree.any((n) => n.key == 'Unit-56'), true);
  });

  // --- TEST SUITE 7: MAIN LINE VS SUBASSEMBLY AUTOMATIC RESOLUTION ---
  test('GroupingEngine resolves MAIN LINE (MAIN/MACG) vs SUBASSEMBLY mode', () {
    final mainPreset1 = GroupingEngine.getPresetForDepartment('MAIN LINE ASSEMBLY');
    expect(mainPreset1.id, 'preset_main_line');
    expect(mainPreset1.levels.first, GroupLevel.unit);
    expect(mainPreset1.levels.contains(GroupLevel.resourceId), true);

    final mainPreset2 = GroupingEngine.getPresetForDepartment('MACG Dept');
    expect(mainPreset2.id, 'preset_main_line');

    final subPreset1 = GroupingEngine.getPresetForDepartment('Plumbing');
    expect(subPreset1.id, 'preset_subassembly');
    expect(subPreset1.levels.first, GroupLevel.unit);
    expect(subPreset1.levels.contains(GroupLevel.department), true);

    final subPreset2 = GroupingEngine.getPresetForDepartment('Electrical');
    expect(subPreset2.id, 'preset_subassembly');
  });

  // --- TEST SUITE 8: RESOURCE ID COLUMN MAPPING ---
  test('ColumnMapper normalizes Resource ID and aliases', () {
    final mapper = ColumnMapper();
    expect(mapper.identifyColumn('RESOURCE ID'), ColumnMapper.keyResourceId);
    expect(mapper.identifyColumn('RESOURCE_ID'), ColumnMapper.keyResourceId);
    expect(mapper.identifyColumn('RESOURCE'), ColumnMapper.keyResourceId);
    expect(mapper.identifyColumn('WORK CENTER'), ColumnMapper.keyResourceId);
  });

  // --- TEST SUITE 9: ON_HAND COLUMN MAPPING & ALIAS REMOVAL ---
  test('ColumnMapper identifies ON_HAND and supports alias removal', () {
    final mapper = ColumnMapper();
    expect(mapper.identifyColumn('ON_HAND'), ColumnMapper.keyOnHand);
    expect(mapper.identifyColumn('ON HAND'), ColumnMapper.keyOnHand);
    expect(mapper.identifyColumn('BIN LOCATION'), ColumnMapper.keyOnHand);

    // Test adding and removing custom alias
    mapper.addAlias(ColumnMapper.keyOnHand, 'SHELF_ZONE');
    expect(mapper.identifyColumn('SHELF_ZONE'), ColumnMapper.keyOnHand);
    mapper.removeAlias(ColumnMapper.keyOnHand, 'SHELF_ZONE');
    expect(mapper.identifyColumn('SHELF_ZONE'), null);
  });

  // --- TEST SUITE 10: DECIMAL DOUBLE QUANTITIES & FIFO ALLOCATION ---
  test('FifoAllocationEngine handles decimal double quantities accurately', () {
    final items = [
      PicklistItem(
        id: '1',
        unitId: 'Unit-1',
        department: 'Paint',
        line: 'L1',
        workOrder: 'WO-1',
        partId: 'PAINT-BLUE',
        partDescription: 'Blue Paint Litres',
        qtyRequired: 10.5,
        qtyDue: 10.5,
        qtyPicked: 0.0,
        rowOrder: 1,
      ),
      PicklistItem(
        id: '2',
        unitId: 'Unit-1',
        department: 'Paint',
        line: 'L1',
        workOrder: 'WO-2',
        partId: 'PAINT-BLUE',
        partDescription: 'Blue Paint Litres',
        qtyRequired: 5.0,
        qtyDue: 5.0,
        qtyPicked: 0.0,
        rowOrder: 2,
      ),
    ];

    // Allocate 12.5 litres (10.5 to WO-1, 2.0 to WO-2)
    final updated = FifoAllocationEngine.allocateByPartId(
      allItems: items,
      department: 'Paint',
      partId: 'PAINT-BLUE',
      totalPickedToAllocate: 12.5,
    );

    expect(updated[0].qtyPicked, 10.5);
    expect(updated[0].qtyDue, 0.0);
    expect(updated[1].qtyPicked, 2.0);
    expect(updated[1].qtyDue, 3.0);
  });

  // --- TEST SUITE 11: GROUPING BY LINE TOGGLE ---
  test('GroupingEngine supports optional Line grouping', () {
    // With line
    final withLineMain = GroupingEngine.getPresetForDepartment('MAIN LINE', includeLine: true);
    expect(withLineMain.levels.contains(GroupLevel.line), true);

    final withLineSub = GroupingEngine.getPresetForDepartment('Paint', includeLine: true);
    expect(withLineSub.levels.contains(GroupLevel.line), true);

    // Without line
    final noLineMain = GroupingEngine.getPresetForDepartment('MAIN LINE', includeLine: false);
    expect(noLineMain.levels.contains(GroupLevel.line), false);
    expect(noLineMain.levels, [GroupLevel.unit, GroupLevel.department, GroupLevel.resourceId, GroupLevel.partId]);

    final noLineSub = GroupingEngine.getPresetForDepartment('Paint', includeLine: false);
    expect(noLineSub.levels.contains(GroupLevel.line), false);
    expect(noLineSub.levels, [GroupLevel.unit, GroupLevel.department, GroupLevel.partId]);
  });

  // --- TEST SUITE 12: PART-ID LEVEL METRICS IN TREENODE ---
  test('GroupingEngine calculates totalParts and completedParts on TreeNodes', () {
    final items = [
      PicklistItem(id: '1', unitId: 'U1', department: 'Weld', line: 'L1', workOrder: 'WO1', partId: 'PART-A', partDescription: 'Bracket', qtyRequired: 10, qtyDue: 0, qtyPicked: 10, rowOrder: 1),
      PicklistItem(id: '2', unitId: 'U1', department: 'Weld', line: 'L1', workOrder: 'WO2', partId: 'PART-B', partDescription: 'Screw', qtyRequired: 5, qtyDue: 2, qtyPicked: 3, rowOrder: 2),
    ];

    final preset = GroupingEngine.getPresetForDepartment('Weld');
    final tree = GroupingEngine.buildTree(items: items, preset: preset);

    expect(tree.isNotEmpty, true);
    final deptNode = tree.first;
    expect(deptNode.totalParts, 2, 'Should detect 2 unique Part IDs');
    expect(deptNode.completedParts, 1, 'Only PART-A is 100% complete');
    expect(deptNode.partProgress, 50.0);
  });

  // --- TEST SUITE 13: UNIT PICK DATE URGENCY & ROBUST DATE PARSING ---
  test('UnitPickDateUrgency parses various date formats accurately', () {
    // ISO
    final iso = UnitPickDateUrgency.parseDateRobust('2026-09-15');
    expect(iso, DateTime(2026, 9, 15));

    // ISO with time
    final isoTime = UnitPickDateUrgency.parseDateRobust('2026-09-15 14:30:00.000');
    expect(isoTime, DateTime(2026, 9, 15));

    // US format
    final us = UnitPickDateUrgency.parseDateRobust('09/15/2026');
    expect(us, DateTime(2026, 9, 15));

    // EU slash format
    final eu = UnitPickDateUrgency.parseDateRobust('15/09/2026');
    expect(eu, DateTime(2026, 9, 15));

    // Dot format
    final dot = UnitPickDateUrgency.parseDateRobust('15.09.2026');
    expect(dot, DateTime(2026, 9, 15));

    // Excel serial number
    // 45548 = 2024-09-13
    final excel = UnitPickDateUrgency.parseDateRobust('45548');
    expect(excel, DateTime(2024, 9, 13));

    // Invalid string returns null
    final invalid = UnitPickDateUrgency.parseDateRobust('not-a-date');
    expect(invalid, null);
  });

  test('UnitPickDateUrgency evaluates pastDue (Red), dueSoon (Yellow), normal (Blue), and completed (Green)', () {
    final today = DateTime(2026, 9, 12);

    // 1. Past due (< 0 days) -> RED (pastDue)
    final past = UnitPickDateUrgency.evaluate(
      dateStr: '2026-09-10',
      department: 'Plumbing',
      isAllCompleted: false,
      referenceToday: today,
    );
    expect(past.status, UnitUrgencyStatus.pastDue);
    expect(past.daysRemaining, -2);
    expect(past.department, 'Plumbing');

    // 2. Today (0 days) -> YELLOW (dueSoon)
    final dueToday = UnitPickDateUrgency.evaluate(
      dateStr: '2026-09-12',
      department: 'Electrical',
      isAllCompleted: false,
      referenceToday: today,
    );
    expect(dueToday.status, UnitUrgencyStatus.dueSoon);
    expect(dueToday.daysRemaining, 0);

    // 3. Tomorrow (1 day) -> YELLOW (dueSoon)
    final dueTomorrow = UnitPickDateUrgency.evaluate(
      dateStr: '2026-09-13',
      department: 'Electrical',
      isAllCompleted: false,
      referenceToday: today,
    );
    expect(dueTomorrow.status, UnitUrgencyStatus.dueSoon);
    expect(dueTomorrow.daysRemaining, 1);

    // 4. In 2 days (2 days) -> YELLOW (dueSoon)
    final dueIn2Days = UnitPickDateUrgency.evaluate(
      dateStr: '2026-09-14',
      department: 'Electrical',
      isAllCompleted: false,
      referenceToday: today,
    );
    expect(dueIn2Days.status, UnitUrgencyStatus.dueSoon);
    expect(dueIn2Days.daysRemaining, 2);

    // 5. In 3 days (> 2 days) -> GREEN (normal)
    final in3Days = UnitPickDateUrgency.evaluate(
      dateStr: '2026-09-15',
      department: 'HVAC',
      isAllCompleted: false,
      referenceToday: today,
    );
    expect(in3Days.status, UnitUrgencyStatus.normal);
    expect(in3Days.daysRemaining, 3);

    // 6. In 10 days (> 2 days) -> GREEN (normal)
    final in10Days = UnitPickDateUrgency.evaluate(
      dateStr: '2026-09-22',
      department: 'Finishing',
      isAllCompleted: false,
      referenceToday: today,
    );
    expect(in10Days.status, UnitUrgencyStatus.normal);
    expect(in10Days.daysRemaining, 10);

    // 7. Completed unit -> GREEN (completed)
    final completed = UnitPickDateUrgency.evaluate(
      dateStr: '2026-09-10',
      department: 'Plumbing',
      isAllCompleted: true,
      referenceToday: today,
    );
    expect(completed.status, UnitUrgencyStatus.completed);
    expect(completed.isAllCompleted, true);
  });

  // --- TEST SUITE 14: MONOTONIC SESSION SEQUENCE NUMBERING ---
  test('Session sequence calculation monotonically increases and wraps at 9999', () {
    int getNextSeq(int savedVal, int dbMax) {
      final current = savedVal > dbMax ? savedVal : dbMax;
      return current >= 9999 ? 1 : current + 1;
    }

    // Starts at 1 when nothing saved
    expect(getNextSeq(0, 0), 1);

    // Advances to 2
    expect(getNextSeq(1, 1), 2);

    // If session 5 was created (savedVal = 5) but then deleted from DB (dbMax = 4),
    // next sequence MUST still be 6 (never reuse 5 or decrement)
    expect(getNextSeq(5, 4), 6);

    // If all sessions deleted from DB (dbMax = 0) but savedVal = 42,
    // next sequence MUST still be 43
    expect(getNextSeq(42, 0), 43);

    // Wraps around from 9999 to 1
    expect(getNextSeq(9999, 9999), 1);
  });

  test('UnitRecord soft-delete properties and serialization', () {
    final activeUnit = UnitRecord(
      id: 'unit-1',
      name: 'Active Unit',
      filePath: '/path/to/unit.xlsx',
      createdAt: 1000000,
      lastAccessedAt: 1000000,
      totalRequired: 100,
      totalPicked: 50,
      status: 'IN_PROGRESS',
    );
    expect(activeUnit.isDeleted, false);
    expect(activeUnit.deletedAt, null);

    final now = DateTime.now().millisecondsSinceEpoch;
    final deletedUnit = activeUnit.copyWith(deletedAt: now);
    expect(deletedUnit.isDeleted, true);
    expect(deletedUnit.deletedAt, now);

    final map = deletedUnit.toMap();
    expect(map['deleted_at'], now);

    final restoredFromMap = UnitRecord.fromMap(map);
    expect(restoredFromMap.isDeleted, true);
    expect(restoredFromMap.deletedAt, now);
    expect(restoredFromMap.id, 'unit-1');
    expect(restoredFromMap.name, 'Active Unit');

    // Test copyWith clearing deletedAt
    final unDeleted = deletedUnit.copyWith(clearDeletedAt: true);
    expect(unDeleted.isDeleted, false);
    expect(unDeleted.deletedAt, null);
  });

  test('30-day session retention cutoff calculation', () {
    final now = DateTime.now();
    const retentionDays = 30;
    final cutoff = now.subtract(const Duration(days: retentionDays)).millisecondsSinceEpoch;

    // Unit soft-deleted 10 days ago (within 30 days retention -> KEEP)
    final deleted10DaysAgo = now.subtract(const Duration(days: 10)).millisecondsSinceEpoch;
    final shouldKeep10 = deleted10DaysAgo >= cutoff;
    expect(shouldKeep10, true, 'Units deleted within 30 days must be preserved');

    // Unit soft-deleted 29 days ago (within 30 days retention -> KEEP)
    final deleted29DaysAgo = now.subtract(const Duration(days: 29)).millisecondsSinceEpoch;
    final shouldKeep29 = deleted29DaysAgo >= cutoff;
    expect(shouldKeep29, true, 'Units deleted 29 days ago must be preserved');

    // Unit soft-deleted 31 days ago (exceeded 30 days -> PURGE)
    final deleted31DaysAgo = now.subtract(const Duration(days: 31)).millisecondsSinceEpoch;
    final shouldPurge31 = deleted31DaysAgo < cutoff;
    expect(shouldPurge31, true, 'Units deleted older than 30 days must be purged');
  });

  test('LogService.escapeCsv complies with RFC 4180', () {
    // Normal string without special characters
    expect(LogService.escapeCsv('Normal text 123'), 'Normal text 123');

    // String containing comma
    expect(LogService.escapeCsv('Error in module, sub-operation'), '"Error in module, sub-operation"');

    // String containing double quotes
    expect(LogService.escapeCsv('User said "Hello"'), '"User said ""Hello"""');

    // String containing both commas and double quotes
    expect(LogService.escapeCsv('Value: "10,20"'), '"Value: ""10,20"""');

    // String containing newlines (multiline stack traces)
    expect(
      LogService.escapeCsv('Exception: Null pointer\nat Class.method(file.dart:42)\nat main()'),
      '"Exception: Null pointer\nat Class.method(file.dart:42)\nat main()"',
    );
  });

  test('LogService size threshold and pruning parameters', () {
    // Hard limit is strictly 49 MB
    expect(LogService.maxLogSizeBytes, 49 * 1024 * 1024);
    expect(LogService.maxLogSizeBytes, 51380224);

    // Pruning batch calculation logic
    int calcPruneCount(int totalCount) => (totalCount * 0.2).ceil().clamp(100, 5000);

    // For 200 items -> 20% is 40 -> clamped to minimum 100
    expect(calcPruneCount(200), 100);

    // For 1,000 items -> 20% is 200 -> within clamp
    expect(calcPruneCount(1000), 200);

    // For 50,000 items -> 20% is 10,000 -> clamped to maximum 5,000
    expect(calcPruneCount(50000), 5000);
  });

  print('\n=== Test Summary ===');
  print('Passed: $passed, Failed: $failed');
  if (failed > 0) {
    throw Exception('$failed tests failed.');
  }
  print('All verification tests passed successfully! ✨\n');
}
