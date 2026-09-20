import '../models/grouping_preset.dart';
import '../models/picklist_item.dart';

/// TreeNode: one node in the accordion hierarchy tree.
class TreeNode {
  final GroupLevel level;
  final String key;
  final String label;
  final String? partDescription;
  final String? onHand;
  final double totalRequired;
  final double totalDue;
  final double totalPicked;
  final int totalParts;
  final int completedParts;
  final List<TreeNode> children;
  final List<PicklistItem> leafItems;

  TreeNode({
    required this.level,
    required this.key,
    required this.label,
    this.partDescription,
    this.onHand,
    required this.totalRequired,
    required this.totalDue,
    required this.totalPicked,
    this.totalParts = 0,
    this.completedParts = 0,
    this.children = const [],
    this.leafItems = const [],
  });

  bool get isLeaf => children.isEmpty && leafItems.isNotEmpty;
  double get partProgress => totalParts > 0 ? (completedParts / totalParts) * 100 : 0.0;
  double get progress => totalRequired > 0 ? (totalPicked / totalRequired) * 100 : 0.0;
  bool get isComplete => isLeaf
      ? (totalPicked >= totalRequired && totalRequired > 0)
      : (totalParts > 0 && completedParts >= totalParts);
  bool get isPartial => isLeaf
      ? (totalPicked > 0 && totalPicked < totalRequired)
      : (completedParts > 0 && completedParts < totalParts);
  bool get isUnpicked => isLeaf ? totalPicked == 0 : completedParts == 0;
}

/// GroupingEngine: builds a dynamic accordion tree from picklist items.
class GroupingEngine {
  /// Builds a dynamic tree based on the provided [preset] and [activeDepartments] filter.
  static List<TreeNode> buildTree({
    required List<PicklistItem> items,
    required GroupingPreset preset,
    Set<String>? activeDepartments,
    Map<String, String>? componentMapping,
  }) {
    // Filter by active departments if provided
    final filtered = activeDepartments == null || activeDepartments.isEmpty
        ? items
        : items
            .where((i) => activeDepartments.any(
                (dept) => dept.toLowerCase().trim() == i.department.toLowerCase().trim()))
            .toList();

    if (filtered.isEmpty) return [];

    return _buildSubtree(
      filtered,
      preset.levels,
      0,
      componentMapping ?? const {},
    );
  }

  static List<TreeNode> _buildSubtree(
    List<PicklistItem> items,
    List<GroupLevel> levels,
    int levelIndex,
    Map<String, String> componentMapping,
  ) {
    if (levelIndex >= levels.length || items.isEmpty) return [];

    final currentLevel = levels[levelIndex];
    final isFinalLevel = levelIndex == levels.length - 1;

    // Group items by the key for the current level
    final groups = <String, List<PicklistItem>>{};
    for (final item in items) {
      final key = _extractKey(item, currentLevel, componentMapping);
      groups.putIfAbsent(key, () => []).add(item);
    }

    final nodes = <TreeNode>[];

    for (final entry in groups.entries) {
      final key = entry.key;
      final groupItems = entry.value;

      final double totalReq = groupItems.fold<double>(0.0, (sum, i) => sum + i.qtyRequired);
      final double totalDue = groupItems.fold<double>(0.0, (sum, i) => sum + i.qtyDue);
      final double totalPicked = groupItems.fold<double>(0.0, (sum, i) => sum + i.qtyPicked);

      // Calculate part counts for this node
      final uniquePartIds = groupItems.map((i) => i.partId).toSet();
      final totalParts = uniquePartIds.length;
      final completedParts = uniquePartIds.where((pid) {
        final partRows = groupItems.where((i) => i.partId == pid);
        final due = partRows.fold<double>(0.0, (s, i) => s + i.qtyDue);
        return due <= 0;
      }).length;

      final desc = currentLevel == GroupLevel.partId && groupItems.isNotEmpty
          ? groupItems.firstWhere((i) => i.partDescription.trim().isNotEmpty, orElse: () => groupItems.first).partDescription.trim()
          : null;
      final onHand = currentLevel == GroupLevel.partId && groupItems.isNotEmpty
          ? groupItems.firstWhere((i) => i.onHand.trim().isNotEmpty, orElse: () => groupItems.first).onHand.trim()
          : null;

      if (isFinalLevel) {
        nodes.add(TreeNode(
          level: currentLevel,
          key: key,
          label: key,
          partDescription: desc,
          onHand: onHand,
          totalRequired: totalReq,
          totalDue: totalDue,
          totalPicked: totalPicked,
          totalParts: 1,
          completedParts: totalDue <= 0 ? 1 : 0,
          children: const [],
          leafItems: groupItems,
        ));
      } else {
        final childNodes = _buildSubtree(groupItems, levels, levelIndex + 1, componentMapping);
        nodes.add(TreeNode(
          level: currentLevel,
          key: key,
          label: key,
          partDescription: desc,
          onHand: onHand,
          totalRequired: totalReq,
          totalDue: totalDue,
          totalPicked: totalPicked,
          totalParts: totalParts,
          completedParts: completedParts,
          children: childNodes,
          leafItems: groupItems,
        ));
      }
    }

    return nodes;
  }

  static String _extractKey(
    PicklistItem item,
    GroupLevel level,
    Map<String, String> componentMapping,
  ) {
    switch (level) {
      case GroupLevel.unit:
        if (item.subUnit.isNotEmpty) return item.subUnit;
        return item.unitId.isNotEmpty ? item.unitId : 'Unit-General';
      case GroupLevel.deptType:
        if (item.deptType.isNotEmpty) return item.deptType;
        final norm = item.department.toUpperCase().trim();
        return (norm.contains('MAIN') || norm.contains('MACG')) ? 'MAIN LINE' : 'SUBASSEMBLY';
      case GroupLevel.component:
        return componentMapping[item.department] ??
               componentMapping[item.department.toLowerCase().trim()] ??
               item.department;
      case GroupLevel.department:
        return item.department.isNotEmpty ? item.department : '(Empty / Unassigned)';
      case GroupLevel.resourceId:
        return item.resourceId.isNotEmpty ? item.resourceId : '(Empty / Unassigned)';
      case GroupLevel.line:
        return item.line.isNotEmpty ? item.line : 'Line-General';
      case GroupLevel.workOrder:
        return item.workOrder.isNotEmpty ? item.workOrder : 'WO-General';
      case GroupLevel.partId:
        return item.partId.isNotEmpty ? item.partId : 'Unknown-Part';
    }
  }

  /// Automatically resolves whether a department is MAIN LINE or SUBASSEMBLY:
  /// - If whole resource scope -> never groups by Line. Combined: Unit → Resource ID → Part ID. By Dept: Unit → Resource ID → Dept → Part ID.
  /// - If department contains 'MAIN' or 'MACG' (case-insensitive) -> MAIN LINE mode
  /// - Otherwise -> SUBASSEMBLY mode.
  /// [includeLine]: If true, groups by Line before Part ID; if false, skips Line level.
  /// [bypassDepartmentLevel]: If true (when picking whole MAIN LINE resource in Combined mode), skips Department level.
  static GroupingPreset getPresetForDepartment(
    String department, {
    bool includeLine = true,
    bool bypassDepartmentLevel = false,
    bool isResourceScope = false,
    List<GroupingPreset>? customPresets,
  }) {
    final norm = department.toUpperCase().trim();
    final isResScope = isResourceScope || (norm.startsWith('RESOURCE: ') && norm.endsWith(' (MAIN LINE)'));

    if (isResScope) {
      // Whole Resource ID picking: strictly NO Line level!
      // In Combined view: Unit → Resource ID → Part ID
      // In By Dept view: Unit → Resource ID → Department → Part ID
      if (bypassDepartmentLevel) {
        return const GroupingPreset(
          id: 'preset_main_line_whole_resource_combined',
          name: 'Main Line Resource Combined (Unit → Resource ID → Part ID)',
          levels: [GroupLevel.unit, GroupLevel.resourceId, GroupLevel.partId],
        );
      } else {
        return const GroupingPreset(
          id: 'preset_main_line_whole_resource_by_dept',
          name: 'Main Line Resource by Dept (Unit → Resource ID → Department → Part ID)',
          levels: [GroupLevel.unit, GroupLevel.resourceId, GroupLevel.department, GroupLevel.partId],
        );
      }
    }

    final isMainLine = norm.contains('MAIN') || norm.contains('MACG');

    if (isMainLine) {
      return GroupingPreset(
        id: 'preset_main_line',
        name: includeLine
            ? 'Main Line (Unit → Dept → Resource ID → Line → Part ID)'
            : 'Main Line (Unit → Dept → Resource ID → Part ID)',
        levels: includeLine
            ? [GroupLevel.unit, GroupLevel.department, GroupLevel.resourceId, GroupLevel.line, GroupLevel.partId]
            : [GroupLevel.unit, GroupLevel.department, GroupLevel.resourceId, GroupLevel.partId],
      );
    } else {
      return GroupingPreset(
        id: 'preset_subassembly',
        name: includeLine
            ? 'Subassembly (Unit → Dept → Line → Part ID)'
            : 'Subassembly (Unit → Dept → Part ID)',
        levels: includeLine
            ? [GroupLevel.unit, GroupLevel.department, GroupLevel.line, GroupLevel.partId]
            : [GroupLevel.unit, GroupLevel.department, GroupLevel.partId],
        isDefault: true,
      );
    }
  }
}
