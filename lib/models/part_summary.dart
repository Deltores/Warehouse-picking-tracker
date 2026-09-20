import 'picklist_item.dart';

/// PartSummary: Aggregates multiple row items of the same Part ID in a department.
class PartSummary {
  final String partId;
  final String description;
  final double qtyPicked;
  final double qtyRequired;
  final double qtyDue;
  final int minRowOrder;
  final String line;
  final String resourceId;
  final String subUnit;
  final String onHand;
  final List<String> workOrders;
  final bool isManualAdd;
  final String manualNote;
  final String manualWorker;
  final String replacedPartId;
  final String replacementNote;
  final bool isRemoved;
  final String removeNote;
  final String removeWorker;
  final String uom;

  const PartSummary({
    required this.partId,
    required this.description,
    required this.qtyPicked,
    required this.qtyRequired,
    required this.qtyDue,
    required this.minRowOrder,
    this.line = '',
    this.resourceId = '',
    this.subUnit = '',
    this.onHand = '',
    this.workOrders = const [],
    this.isManualAdd = false,
    this.manualNote = '',
    this.manualWorker = '',
    this.replacedPartId = '',
    this.replacementNote = '',
    this.isRemoved = false,
    this.removeNote = '',
    this.removeWorker = '',
    this.uom = 'NA',
  });

  bool get isComplete => qtyPicked >= qtyRequired && qtyRequired > 0;
  bool get isPartial => qtyPicked > 0 && qtyPicked < qtyRequired;
  bool get isUnpicked => qtyPicked == 0;
  double get progress => qtyRequired > 0 ? (qtyPicked / qtyRequired).clamp(0.0, 1.0) : 0.0;

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
  String get uomLabel => formatUom(uom);

  /// Formats the unit of measure label.
  /// If UOM is EA, PCS, PC, NA, or blank, standardizes to 'PCS'.
  /// For any other measurement unit (e.g. M, FT, KG, BOX, SET, ROLL, LBS), returns that exact unit.
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

  factory PartSummary.fromItem(PicklistItem item) => PartSummary(
    partId: item.partId,
    description: item.partDescription,
    qtyPicked: item.qtyPicked,
    qtyRequired: item.qtyRequired,
    qtyDue: item.qtyDue,
    minRowOrder: item.rowOrder,
    line: item.line,
    resourceId: item.resourceId,
    subUnit: item.subUnit,
    onHand: item.onHand,
    workOrders: item.workOrder.isNotEmpty ? [item.workOrder] : [],
    isManualAdd: item.isManualAdd,
    manualNote: item.manualNote,
    manualWorker: item.manualWorker,
    replacedPartId: item.replacedPartId,
    replacementNote: item.replacementNote,
    isRemoved: item.isRemoved,
    removeNote: item.removeNote,
    removeWorker: item.removeWorker,
    uom: item.uom,
  );

  PartSummary add(PicklistItem item) {
    final updatedWOs = List<String>.from(workOrders);
    if (item.workOrder.isNotEmpty && !updatedWOs.contains(item.workOrder)) {
      updatedWOs.add(item.workOrder);
    }
    return PartSummary(
      partId: partId,
      description: description.isNotEmpty ? description : item.partDescription,
      qtyPicked: qtyPicked + item.qtyPicked,
      qtyRequired: qtyRequired + item.qtyRequired,
      qtyDue: qtyDue + item.qtyDue,
      minRowOrder: minRowOrder < item.rowOrder ? minRowOrder : item.rowOrder,
      line: line.isNotEmpty ? line : item.line,
      resourceId: resourceId.isNotEmpty ? resourceId : item.resourceId,
      subUnit: subUnit.isNotEmpty ? subUnit : item.subUnit,
      onHand: onHand.isNotEmpty ? onHand : item.onHand,
      workOrders: updatedWOs,
      isManualAdd: isManualAdd || item.isManualAdd,
      manualNote: manualNote.isNotEmpty ? manualNote : item.manualNote,
      manualWorker: manualWorker.isNotEmpty ? manualWorker : item.manualWorker,
      replacedPartId: replacedPartId.isNotEmpty ? replacedPartId : item.replacedPartId,
      replacementNote: replacementNote.isNotEmpty ? replacementNote : item.replacementNote,
      isRemoved: isRemoved || item.isRemoved,
      removeNote: removeNote.isNotEmpty ? removeNote : item.removeNote,
      removeWorker: removeWorker.isNotEmpty ? removeWorker : item.removeWorker,
      uom: uom != 'NA' ? uom : item.uom,
    );
  }

  PartSummary copyWith({
    String? partId,
    String? description,
    double? qtyPicked,
    double? qtyRequired,
    double? qtyDue,
    int? minRowOrder,
    String? line,
    String? resourceId,
    String? subUnit,
    String? onHand,
    List<String>? workOrders,
    bool? isManualAdd,
    String? manualNote,
    String? manualWorker,
    String? replacedPartId,
    String? replacementNote,
    bool? isRemoved,
    String? removeNote,
    String? removeWorker,
    String? uom,
  }) =>
      PartSummary(
        partId: partId ?? this.partId,
        description: description ?? this.description,
        qtyPicked: qtyPicked ?? this.qtyPicked,
        qtyRequired: qtyRequired ?? this.qtyRequired,
        qtyDue: qtyDue ?? this.qtyDue,
        minRowOrder: minRowOrder ?? this.minRowOrder,
        line: line ?? this.line,
        resourceId: resourceId ?? this.resourceId,
        subUnit: subUnit ?? this.subUnit,
        onHand: onHand ?? this.onHand,
        workOrders: workOrders ?? this.workOrders,
        isManualAdd: isManualAdd ?? this.isManualAdd,
        manualNote: manualNote ?? this.manualNote,
        manualWorker: manualWorker ?? this.manualWorker,
        replacedPartId: replacedPartId ?? this.replacedPartId,
        replacementNote: replacementNote ?? this.replacementNote,
        isRemoved: isRemoved ?? this.isRemoved,
        removeNote: removeNote ?? this.removeNote,
        removeWorker: removeWorker ?? this.removeWorker,
        uom: uom ?? this.uom,
      );
}

