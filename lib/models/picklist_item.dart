/// Core picklist row model.
///
/// All quantity fields use [double] to support measurement units (m, ft, kg, etc.).
/// [deptType]: populated from an optional Excel column (e.g. "DEPT TYPE", "LINE TYPE");
///             expected values: 'MAIN LINE', 'SUBASSEMBLY', or '' (auto-detected when blank).
class PicklistItem {
  final String id;
  final String unitId;
  final String department;
  final String line;
  final String workOrder;
  final String partId;
  final String partDescription;
  final double qtyRequired;
  final double qtyDue;
  final double qtyPicked;
  final int rowOrder;
  final String pickDate;
  final String prodDate;
  final String subUnit;
  final String resourceId;
  final String onHand;
  final String deptType; // 'MAIN LINE' | 'SUBASSEMBLY' | ''

  PicklistItem({
    required this.id,
    required this.unitId,
    required this.department,
    required this.line,
    required this.workOrder,
    required this.partId,
    required this.partDescription,
    required this.qtyRequired,
    required this.qtyDue,
    required this.qtyPicked,
    required this.rowOrder,
    this.pickDate = '',
    this.prodDate = '',
    this.subUnit = '',
    this.resourceId = '',
    this.onHand = '',
    this.deptType = '',
  });

  static String formatQty(double val) {
    if (val.abs() < 0.00001) return '0';
    if (val % 1 == 0) {
      return val.toInt().toString();
    }
    final fixed = val.toStringAsFixed(2);
    return fixed.replaceAll(RegExp(r'0*$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  String get qtyRequiredStr => formatQty(qtyRequired);
  String get qtyDueStr => formatQty(qtyDue);
  String get qtyPickedStr => formatQty(qtyPicked);

  PicklistItem copyWith({
    String? id,
    String? unitId,
    String? department,
    String? line,
    String? workOrder,
    String? partId,
    String? partDescription,
    double? qtyRequired,
    double? qtyDue,
    double? qtyPicked,
    int? rowOrder,
    String? pickDate,
    String? prodDate,
    String? subUnit,
    String? resourceId,
    String? onHand,
    String? deptType,
  }) {
    return PicklistItem(
      id: id ?? this.id,
      unitId: unitId ?? this.unitId,
      department: department ?? this.department,
      line: line ?? this.line,
      workOrder: workOrder ?? this.workOrder,
      partId: partId ?? this.partId,
      partDescription: partDescription ?? this.partDescription,
      qtyRequired: qtyRequired ?? this.qtyRequired,
      qtyDue: qtyDue ?? this.qtyDue,
      qtyPicked: qtyPicked ?? this.qtyPicked,
      rowOrder: rowOrder ?? this.rowOrder,
      pickDate: pickDate ?? this.pickDate,
      prodDate: prodDate ?? this.prodDate,
      subUnit: subUnit ?? this.subUnit,
      resourceId: resourceId ?? this.resourceId,
      onHand: onHand ?? this.onHand,
      deptType: deptType ?? this.deptType,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'unit_id': unitId,
      'department': department,
      'line': line,
      'work_order': workOrder,
      'part_id': partId,
      'part_description': partDescription,
      'qty_required': qtyRequired,
      'qty_due': qtyDue,
      'qty_picked': qtyPicked,
      'row_order': rowOrder,
      'pick_date': pickDate,
      'prod_date': prodDate,
      'sub_unit': subUnit,
      'resource_id': resourceId,
      'on_hand': onHand,
      'dept_type': deptType,
    };
  }

  factory PicklistItem.fromMap(Map<String, dynamic> map) {
    return PicklistItem(
      id: map['id'] as String,
      unitId: map['unit_id'] as String,
      department: (map['department'] ?? '') as String,
      line: (map['line'] ?? '') as String,
      workOrder: (map['work_order'] ?? '') as String,
      partId: (map['part_id'] ?? '') as String,
      partDescription: (map['part_description'] ?? '') as String,
      qtyRequired: (map['qty_required'] as num?)?.toDouble() ?? 0.0,
      qtyDue: (map['qty_due'] as num?)?.toDouble() ?? 0.0,
      qtyPicked: (map['qty_picked'] as num?)?.toDouble() ?? 0.0,
      rowOrder: (map['row_order'] as num?)?.toInt() ?? 0,
      pickDate: (map['pick_date'] ?? '') as String,
      prodDate: (map['prod_date'] ?? '') as String,
      subUnit: (map['sub_unit'] ?? '') as String,
      resourceId: (map['resource_id'] ?? '') as String,
      onHand: (map['on_hand'] ?? '') as String,
      deptType: (map['dept_type'] ?? '') as String,
    );
  }
}
