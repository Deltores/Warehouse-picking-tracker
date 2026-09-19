import 'package:test/test.dart';
import '../lib/engine/column_mapper.dart';

void main() {
  group('ColumnMapper Tests', () {
    final mapper = ColumnMapper();

    test('Normalizes various casing and punctuation', () {
      expect(ColumnMapper.normalize('  unit_number  '), equals('UNIT NUMBER'));
      expect(ColumnMapper.normalize('WORK-ORDER'), equals('WORK ORDER'));
      expect(ColumnMapper.normalize('QTY   REQUIRED'), equals('QTY REQUIRED'));
    });

    test('Identifies standard column headers across various aliases', () {
      expect(mapper.identifyColumn('Unit'), equals(ColumnMapper.keyUnit));
      expect(mapper.identifyColumn('UNIT #'), equals(ColumnMapper.keyUnit));
      expect(mapper.identifyColumn('DEPT'), equals(ColumnMapper.keyDepartment));
      expect(mapper.identifyColumn('Production Line'), equals(ColumnMapper.keyLine));
      expect(mapper.identifyColumn('WO#'), equals(ColumnMapper.keyWorkOrder));
      expect(mapper.identifyColumn('Part ID'), equals(ColumnMapper.keyPartId));
      expect(mapper.identifyColumn('PART DESCRIPTION'), equals(ColumnMapper.keyPartDescription));
      expect(mapper.identifyColumn('Qty Required'), equals(ColumnMapper.keyQtyRequired));
      expect(mapper.identifyColumn('Req Qty'), equals(ColumnMapper.keyQtyRequired));
      expect(mapper.identifyColumn('Qty Due'), equals(ColumnMapper.keyQtyDue));
      expect(mapper.identifyColumn('Picked Qty'), equals(ColumnMapper.keyQtyPicked));
    });

    test('Distinguishes Component Resource ID and Resource ID', () {
      expect(mapper.identifyColumn('Component Resource id'), equals(ColumnMapper.keyComponentResourceId));
      expect(mapper.identifyColumn('Component Resource ID'), equals(ColumnMapper.keyComponentResourceId));
      expect(mapper.identifyColumn('COMP RESOURCE ID'), equals(ColumnMapper.keyComponentResourceId));
      expect(mapper.identifyColumn('Resource id'), equals(ColumnMapper.keyResourceId));
      expect(mapper.identifyColumn('Resource ID'), equals(ColumnMapper.keyResourceId));
    });

    test('Allows dynamic alias addition', () {
      mapper.addAlias(ColumnMapper.keyPartId, 'CUSTOM_SKU_CODE');
      expect(mapper.identifyColumn('custom_sku_code'), equals(ColumnMapper.keyPartId));
    });

    test('Identifies ON HAND column headers across various aliases', () {
      expect(mapper.identifyColumn('ON HAND'), equals(ColumnMapper.keyOnHand));
      expect(mapper.identifyColumn('ON-HAND'), equals(ColumnMapper.keyOnHand));
      expect(mapper.identifyColumn('ON HAND QTY'), equals(ColumnMapper.keyOnHand));
      expect(mapper.identifyColumn('BIN LOCATION'), equals(ColumnMapper.keyOnHand));
      expect(mapper.identifyColumn('LOCATION'), equals(ColumnMapper.keyOnHand));
      expect(mapper.identifyColumn('STOCK'), equals(ColumnMapper.keyOnHand));
      expect(mapper.identifyColumn('INVENTORY'), equals(ColumnMapper.keyOnHand));
    });

    test('ColumnMapper.fromJson preserves keyComponentResourceId even from legacy JSON config', () {
      final legacyJson = '{"part_id": ["ITEM_NO"], "work_order": ["ORDER_NO"]}';
      final restoredMapper = ColumnMapper.fromJson(legacyJson);
      expect(restoredMapper.aliases.containsKey(ColumnMapper.keyComponentResourceId), isTrue);
      expect(restoredMapper.aliases.containsKey(ColumnMapper.keyOnHand), isTrue);
      expect(restoredMapper.identifyColumn('Component Resource id'), equals(ColumnMapper.keyComponentResourceId));
      expect(restoredMapper.identifyColumn('ITEM_NO'), equals(ColumnMapper.keyPartId));
      expect(restoredMapper.identifyColumn('ON-HAND'), equals(ColumnMapper.keyOnHand));
    });
  });
}

