import 'dart:convert';

/// Core picklist row model.
///
/// All quantity fields use [double] to support measurement units (m, ft, kg, etc.).
/// [deptType]: populated from an optional Excel column (e.g. "DEPT TYPE", "LINE TYPE");
///             expected values: 'MAIN LINE', 'SUBASSEMBLY', or '' (auto-detected when blank).
/// [resourceId]: Destination / assembly resource ID (where parts are assembled).
/// [componentResourceId]: Component resource ID / part source (where parts originate).
/// [rawColumns]: Raw original column values from the Excel row for dynamic preservation on export.
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
  final String componentResourceId;
  final String onHand;
  final String deptType; // 'MAIN LINE' | 'SUBASSEMBLY' | ''
  final Map<String, dynamic> rawColumns;
  // Part ID replacement tracking (Replace Part ID feature)
  final String replacedPartId;   // original Part ID if this item was re-keyed
  final String replacementNote;  // mandatory comment entered when replacing
  final int? replacedAt;         // timestamp (ms since epoch) of replacement
  final String replacedBy;       // worker name who performed the replacement

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
    this.componentResourceId = '',
    this.onHand = '',
    this.deptType = '',
    this.rawColumns = const {},
    this.replacedPartId = '',
    this.replacementNote = '',
    this.replacedAt,
    this.replacedBy = '',
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

  bool get isManualAdd {
    final flag = rawColumns['_manual_add'];
    return flag == true || flag == 1 || flag == 'true';
  }
  String get manualNote => rawColumns['_manual_note']?.toString() ?? '';
  String get manualWorker => rawColumns['_manual_worker']?.toString() ?? '';

  bool get isRemoved {
    final flag = rawColumns['_is_removed'];
    return flag == true || flag == 1 || flag == 'true';
  }
  String get removeNote => rawColumns['_remove_note']?.toString() ?? '';
  String get removeWorker => rawColumns['_remove_worker']?.toString() ?? '';

  String get uom {
    final raw = rawColumns['_uom'] ??
        rawColumns['uom'] ??
        rawColumns['UOM'] ??
        rawColumns['Unit of Measure'] ??
        rawColumns['UNIT OF MEASURE'] ??
        rawColumns['UM'] ??
        rawColumns['Um'];
    if (raw != null) {
      final s = raw.toString().trim();
      if (s.isNotEmpty && s.toLowerCase() != 'null') return s;
    }
    return 'NA';
  }

  String get uomLabel => formatUom(uom);

  static String formatUom(String? rawUom) {
    final u = rawUom?.trim() ?? '';
    final upper = u.toUpperCase();
    if (upper.isEmpty ||
        upper == 'NA' ||
        upper == 'N/A' ||
        upper == 'EA' ||
        upper == 'PCS' ||
        upper == 'PC') {
      return 'PCS';
    }
    return u;
  }

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
    String? componentResourceId,
    String? onHand,
    String? deptType,
    Map<String, dynamic>? rawColumns,
    bool? isRemoved,
    String? replacedPartId,
    String? replacementNote,
    int? replacedAt,
    bool clearReplacedAt = false,
    String? replacedBy,
  }) {
    Map<String, dynamic>? updatedRaw = rawColumns != null ? Map<String, dynamic>.from(rawColumns) : null;
    if (isRemoved != null) {
      updatedRaw ??= Map<String, dynamic>.from(this.rawColumns);
      updatedRaw['_is_removed'] = isRemoved;
    }

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
      componentResourceId: componentResourceId ?? this.componentResourceId,
      onHand: onHand ?? this.onHand,
      deptType: deptType ?? this.deptType,
      rawColumns: updatedRaw ?? this.rawColumns,
      replacedPartId: replacedPartId ?? this.replacedPartId,
      replacementNote: replacementNote ?? this.replacementNote,
      replacedAt: clearReplacedAt ? null : (replacedAt ?? this.replacedAt),
      replacedBy: replacedBy ?? this.replacedBy,
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
      'component_resource_id': componentResourceId,
      'on_hand': onHand,
      'dept_type': deptType,
      'raw_columns': jsonEncode(rawColumns),
      'replaced_part_id': replacedPartId,
      'replacement_note': replacementNote,
      'replaced_at': replacedAt,
      'replaced_by': replacedBy,
    };
  }

  factory PicklistItem.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> parsedRaw = {};
    if (map['raw_columns'] != null && map['raw_columns'] is String) {
      final str = (map['raw_columns'] as String).trim();
      if (str.isNotEmpty) {
        try {
          parsedRaw = jsonDecode(str) as Map<String, dynamic>;
        } catch (_) {}
      }
    }

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
      componentResourceId: (map['component_resource_id'] ?? '') as String,
      onHand: (map['on_hand'] ?? '') as String,
      deptType: (map['dept_type'] ?? '') as String,
      rawColumns: parsedRaw,
      replacedPartId: (map['replaced_part_id'] ?? '') as String,
      replacementNote: (map['replacement_note'] ?? '') as String,
      replacedAt: (map['replaced_at'] as num?)?.toInt(),
      replacedBy: (map['replaced_by'] ?? '') as String,
    );
  }
}
