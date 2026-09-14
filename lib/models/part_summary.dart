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
    );
  }
}
