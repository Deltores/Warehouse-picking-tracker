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

    test('Allows dynamic alias addition', () {
      mapper.addAlias(ColumnMapper.keyPartId, 'CUSTOM_SKU_CODE');
      expect(mapper.identifyColumn('custom_sku_code'), equals(ColumnMapper.keyPartId));
    });
  });
}
