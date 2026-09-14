import 'package:test/test.dart';
import '../lib/engine/grouping_engine.dart';
import '../lib/models/grouping_preset.dart';
import '../lib/models/picklist_item.dart';

void main() {
  group('GroupingEngine Tests', () {
    final items = [
      PicklistItem(
        id: '1',
        unitId: 'UNIT-100',
        department: 'Assembly',
        line: 'Line A',
        workOrder: 'WO-1',
        partId: 'BOLT-1',
        partDescription: 'Steel Bolt',
        qtyRequired: 10,
        qtyDue: 10,
        qtyPicked: 10,
        rowOrder: 1,
      ),
      PicklistItem(
        id: '2',
        unitId: 'UNIT-100',
        department: 'Assembly',
        line: 'Line A',
        workOrder: 'WO-2',
        partId: 'BOLT-1',
        partDescription: 'Steel Bolt',
        qtyRequired: 20,
        qtyDue: 15,
        qtyPicked: 5,
        rowOrder: 2,
      ),
      PicklistItem(
        id: '3',
        unitId: 'UNIT-100',
        department: 'Paint',
        line: 'Line B',
        workOrder: 'WO-3',
        partId: 'PAINT-CAN',
        partDescription: 'Blue Spray',
        qtyRequired: 5,
        qtyDue: 5,
        qtyPicked: 0,
        rowOrder: 3,
      ),
    ];

    test('Filters departments correctly based on tablet assignment', () {
      final preset = const GroupingPreset(
        id: 'unit_dept_part',
        name: 'Unit -> Dept -> Part',
        levels: [GroupLevel.unit, GroupLevel.department, GroupLevel.partId],
      );

      // Only Assembly is active for this device
      final tree = GroupingEngine.buildTree(
        items: items,
        preset: preset,
        activeDepartments: {'Assembly'},
      );

      expect(tree.length, equals(1)); // UNIT-100
      final unitNode = tree.first;
      expect(unitNode.children.length, equals(1)); // Assembly
      expect(unitNode.children.first.key, equals('Assembly'));

      // Paint department is excluded!
      expect(unitNode.children.any((c) => c.key == 'Paint'), isFalse);
    });

    test('Aggregates totals and status accurately', () {
      final preset = const GroupingPreset(
        id: 'unit_dept_part',
        name: 'Unit -> Dept -> Part',
        levels: [GroupLevel.unit, GroupLevel.department, GroupLevel.partId],
      );
      final tree = GroupingEngine.buildTree(
        items: items,
        preset: preset,
      );

      final unitNode = tree.first;
      // Total required = 10 + 20 + 5 = 35
      expect(unitNode.totalRequired, equals(35));
      // Total picked = 10 + 5 + 0 = 15
      expect(unitNode.totalPicked, equals(15));
      expect(unitNode.totalParts, equals(2));
      expect(unitNode.completedParts, equals(0));
    });

    test('Supports GroupLevel.deptType in hierarchy', () {
      final preset = const GroupingPreset(
        id: 'unit_type_dept_part',
        name: 'Unit -> Type -> Dept -> Part',
        levels: [GroupLevel.unit, GroupLevel.deptType, GroupLevel.department, GroupLevel.partId],
      );

      final testItems = [
        PicklistItem(
          id: '1',
          unitId: 'U1',
          department: 'MAIN ASSEMBLY',
          deptType: 'MAIN LINE',
          line: 'L1',
          workOrder: 'W1',
          partId: 'P1',
          partDescription: '',
          qtyRequired: 5,
          qtyDue: 0,
          qtyPicked: 5,
          rowOrder: 1,
        ),
        PicklistItem(
          id: '2',
          unitId: 'U1',
          department: 'SUB-WELD',
          deptType: 'SUBASSEMBLY',
          line: 'L2',
          workOrder: 'W2',
          partId: 'P2',
          partDescription: '',
          qtyRequired: 3,
          qtyDue: 3,
          qtyPicked: 0,
          rowOrder: 2,
        ),
      ];

      final tree = GroupingEngine.buildTree(items: testItems, preset: preset);
      expect(tree.length, equals(1)); // U1
      final typeNodes = tree.first.children;
      expect(typeNodes.length, equals(2)); // MAIN LINE and SUBASSEMBLY
      expect(typeNodes.map((n) => n.key).toSet(), equals({'MAIN LINE', 'SUBASSEMBLY'}));
    });
  });
}
