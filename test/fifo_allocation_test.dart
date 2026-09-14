import 'package:test/test.dart';
import '../lib/engine/fifo_allocation_engine.dart';
import '../lib/models/picklist_item.dart';

void main() {
  group('FifoAllocationEngine Tests', () {
    test('Cascades quantity across Work Orders strictly within Department', () {
      final items = [
        // Target Department: Hardware
        PicklistItem(
          id: 'item_1',
          unitId: 'Unit_A',
          department: 'Hardware',
          line: 'Line 1',
          workOrder: 'WO-1',
          partId: 'BRK-001',
          partDescription: 'Bracket Type A',
          qtyRequired: 50,
          qtyDue: 50,
          qtyPicked: 0,
          rowOrder: 1,
        ),
        PicklistItem(
          id: 'item_2',
          unitId: 'Unit_A',
          department: 'Hardware',
          line: 'Line 1',
          workOrder: 'WO-2',
          partId: 'BRK-001',
          partDescription: 'Bracket Type A',
          qtyRequired: 100,
          qtyDue: 100,
          qtyPicked: 0,
          rowOrder: 2,
        ),
        PicklistItem(
          id: 'item_3',
          unitId: 'Unit_A',
          department: 'Hardware',
          line: 'Line 2',
          workOrder: 'WO-3',
          partId: 'BRK-001',
          partDescription: 'Bracket Type A',
          qtyRequired: 32,
          qtyDue: 32,
          qtyPicked: 0,
          rowOrder: 3,
        ),
        PicklistItem(
          id: 'item_4',
          unitId: 'Unit_A',
          department: 'Hardware',
          line: 'Line 2',
          workOrder: 'WO-4',
          partId: 'BRK-001',
          partDescription: 'Bracket Type A',
          qtyRequired: 50,
          qtyDue: 50,
          qtyPicked: 0,
          rowOrder: 4,
        ),

        // Another Department: Chassis (same Part ID: BRK-001)
        PicklistItem(
          id: 'item_other_dept',
          unitId: 'Unit_A',
          department: 'Chassis',
          line: 'Line 10',
          workOrder: 'WO-99',
          partId: 'BRK-001',
          partDescription: 'Bracket Type A (Chassis)',
          qtyRequired: 20,
          qtyDue: 20,
          qtyPicked: 0,
          rowOrder: 5,
        ),
      ];

      // User enters 168 pieces for BRK-001 in Hardware
      final result = FifoAllocationEngine.allocateByPartId(
        allItems: items,
        department: 'Hardware',
        partId: 'BRK-001',
        totalPickedToAllocate: 168,
      );

      // Verify WO-1: 50 required -> 50 picked, 0 due
      final wo1 = result.firstWhere((i) => i.id == 'item_1');
      expect(wo1.qtyPicked, equals(50));
      expect(wo1.qtyDue, equals(0));

      // Verify WO-2: 100 required -> 100 picked, 0 due
      final wo2 = result.firstWhere((i) => i.id == 'item_2');
      expect(wo2.qtyPicked, equals(100));
      expect(wo2.qtyDue, equals(0));

      // Verify WO-3: 32 required -> 18 picked, 14 due
      final wo3 = result.firstWhere((i) => i.id == 'item_3');
      expect(wo3.qtyPicked, equals(18));
      expect(wo3.qtyDue, equals(14));

      // Verify WO-4: 50 required -> 0 picked, 50 due
      final wo4 = result.firstWhere((i) => i.id == 'item_4');
      expect(wo4.qtyPicked, equals(0));
      expect(wo4.qtyDue, equals(50));

      // CRITICAL: Verify Chassis department was NOT touched!
      final chassisItem = result.firstWhere((i) => i.id == 'item_other_dept');
      expect(chassisItem.qtyPicked, equals(0));
      expect(chassisItem.qtyDue, equals(20));
    });

    test('Manual single item override updates correctly', () {
      final item = PicklistItem(
        id: 'item_1',
        unitId: 'Unit_A',
        department: 'Hardware',
        line: 'Line 1',
        workOrder: 'WO-1',
        partId: 'BRK-001',
        partDescription: 'Bracket Type A',
        qtyRequired: 50,
        qtyDue: 50,
        qtyPicked: 0,
        rowOrder: 1,
      );

      final updated = FifoAllocationEngine.updateSingleItem(item, 25);
      expect(updated.qtyPicked, equals(25));
      expect(updated.qtyDue, equals(25));
    });
  });
}
