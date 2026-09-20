import '../models/picklist_item.dart';

class FifoAllocationEngine {
  /// Allocates a total picked quantity across items belonging strictly to the
  /// specified [department] and [partId] using FIFO (First-In, First-Out).
  ///
  /// Items are sorted by their original [rowOrder].
  ///
  /// Example:
  /// Total required = 182, Total picked entered = 168
  /// - WO-1 (Req: 50)  -> Picked: 50, Due: 0
  /// - WO-2 (Req: 100) -> Picked: 100, Due: 0
  /// - WO-3 (Req: 32)  -> Picked: 18, Due: 14
  /// - WO-4 (Req: 0)   -> Picked: 0, Due: 0
  ///
  /// Critical: Any items outside the specified [department] are NOT touched.
  static List<PicklistItem> allocateByPartId({
    required List<PicklistItem> allItems,
    required String department,
    required String partId,
    required double totalPickedToAllocate,
  }) {
    // Separate items that belong to the target department & partId from the rest
    final targetIndices = <int>[];
    final targetItems = <PicklistItem>[];

    for (int i = 0; i < allItems.length; i++) {
      final item = allItems[i];
      final bool matchesScope;
      if (department.toLowerCase().startsWith('resource:')) {
        final cleanRes = department
            .replaceFirst(RegExp(r'resource:\s*', caseSensitive: false), '')
            .replaceAll(RegExp(r'\s*\(main line\)', caseSensitive: false), '')
            .trim()
            .toLowerCase();
        matchesScope = item.resourceId.toLowerCase().trim() == cleanRes;
      } else {
        matchesScope = (department.isEmpty ||
            department.toLowerCase() == 'all departments' ||
            item.department.toLowerCase().trim() == department.toLowerCase().trim());
      }
      if (matchesScope &&
          item.partId.toLowerCase().trim() == partId.toLowerCase().trim()) {
        targetIndices.add(i);
        targetItems.add(item);
      }
    }

    if (targetItems.isEmpty) {
      return allItems;
    }

    // Sort target items by rowOrder to guarantee FIFO order
    final indexedTarget = List.generate(targetItems.length, (i) => i);
    indexedTarget.sort((a, b) => targetItems[a].rowOrder.compareTo(targetItems[b].rowOrder));

    double remainingToPick = totalPickedToAllocate < 0 ? 0.0 : totalPickedToAllocate;
    final updatedTargetItems = List<PicklistItem>.from(targetItems);

    for (final idx in indexedTarget) {
      final current = targetItems[idx];
      final req = current.qtyRequired;

      if (remainingToPick >= req) {
        // Fully satisfy this work order
        updatedTargetItems[idx] = current.copyWith(
          qtyPicked: req,
          qtyDue: 0.0,
        );
        remainingToPick -= req;
      } else {
        // Partially satisfy or 0
        final picked = remainingToPick;
        final due = req - picked;
        updatedTargetItems[idx] = current.copyWith(
          qtyPicked: picked,
          qtyDue: due > 0 ? due : 0.0,
        );
        remainingToPick = 0.0;
      }
    }

    // If remainingToPick > 0 and target items contain a manually added item,
    // expand the manual item's quantity rather than truncating it.
    if (remainingToPick > 0.0001) {
      final manualIdx = updatedTargetItems.lastIndexWhere((it) => it.isManualAdd);
      if (manualIdx >= 0) {
        final manualItem = updatedTargetItems[manualIdx];
        final newPicked = manualItem.qtyPicked + remainingToPick;
        updatedTargetItems[manualIdx] = manualItem.copyWith(
          qtyPicked: newPicked,
          qtyRequired: newPicked,
          qtyDue: 0.0,
        );
        remainingToPick = 0.0;
      }
    }

    // Reconstruct full item list preserving original indices
    final result = List<PicklistItem>.from(allItems);
    for (int i = 0; i < targetIndices.length; i++) {
      final origIdx = targetIndices[i];
      result[origIdx] = updatedTargetItems[i];
    }

    return result;
  }

  /// Updates a single work order row directly (manual override)
  static PicklistItem updateSingleItem(PicklistItem item, double newQtyPicked) {
    final picked = newQtyPicked < 0 ? 0.0 : newQtyPicked;
    final due = item.qtyRequired - picked;
    return item.copyWith(
      qtyPicked: picked,
      qtyDue: due > 0 ? due : 0.0,
    );
  }
}
