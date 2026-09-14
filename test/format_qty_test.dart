import 'package:flutter_test/flutter_test.dart';
import 'package:picklist_tracker/models/part_summary.dart';
import 'package:picklist_tracker/models/picklist_item.dart';

void main() {
  group('formatQty Tests', () {
    test('Formats decimal quantities to max 2 decimals without trailing zeros', () {
      expect(PartSummary.formatQty(6.20), equals('6.2'));
      expect(PartSummary.formatQty(6.00), equals('6'));
      expect(PartSummary.formatQty(6.25), equals('6.25'));
      expect(PartSummary.formatQty(0.0), equals('0'));
      expect(PartSummary.formatQty(0.000001), equals('0'));
      expect(PartSummary.formatQty(12.345), equals('12.35'));
      expect(PartSummary.formatQty(100.1), equals('100.1'));
      expect(PartSummary.formatQty(100.0), equals('100'));

      expect(PicklistItem.formatQty(6.20), equals('6.2'));
      expect(PicklistItem.formatQty(6.00), equals('6'));
      expect(PicklistItem.formatQty(6.25), equals('6.25'));
      expect(PicklistItem.formatQty(0.0), equals('0'));
    });
  });
}
