/// GroupLevel: the dimension used to group picklist items in the accordion tree.
///
/// Ordering matters — GroupingEngine consumes these left-to-right to build the hierarchy.
enum GroupLevel {
  unit,
  deptType,
  component,  // Admin-defined picker specialty group (e.g. "Purchasing", "PRIMA", "Warehouse")
  department,
  resourceId,
  line,
  workOrder,
  partId;

  String get displayName {
    switch (this) {
      case GroupLevel.unit:
        return 'Unit';
      case GroupLevel.deptType:
        return 'Type (Main Line / Subassembly)';
      case GroupLevel.component:
        return 'Component Group';
      case GroupLevel.department:
        return 'Department';
      case GroupLevel.resourceId:
        return 'Resource ID';
      case GroupLevel.line:
        return 'Line';
      case GroupLevel.workOrder:
        return 'Work Order';
      case GroupLevel.partId:
        return 'Part ID';
    }
  }
}

class GroupingPreset {
  final String id;
  final String name;
  final List<GroupLevel> levels;
  final bool isDefault;

  const GroupingPreset({
    required this.id,
    required this.name,
    required this.levels,
    this.isDefault = false,
  });

  static List<GroupingPreset> get defaultPresets => [
    const GroupingPreset(
      id: 'preset_main_line',
      name: 'Main Line (Unit → Dept → Resource ID → Line → Part ID)',
      levels: [GroupLevel.unit, GroupLevel.department, GroupLevel.resourceId, GroupLevel.line, GroupLevel.partId],
    ),
    const GroupingPreset(
      id: 'preset_subassembly',
      name: 'Subassembly (Unit → Dept → Line → Part ID)',
      levels: [GroupLevel.unit, GroupLevel.department, GroupLevel.line, GroupLevel.partId],
      isDefault: true,
    ),
  ];

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'levels': levels.map((l) => l.name).toList(),
      'is_default': isDefault ? 1 : 0,
    };
  }

  factory GroupingPreset.fromMap(Map<String, dynamic> map) {
    final levelsList = (map['levels'] as List<dynamic>?)
            ?.map((e) => GroupLevel.values.firstWhere(
                  (val) => val.name == e.toString(),
                  orElse: () => GroupLevel.partId,
                ))
            .toList() ??
        [GroupLevel.unit, GroupLevel.department, GroupLevel.partId];

    return GroupingPreset(
      id: map['id'] as String,
      name: map['name'] as String,
      levels: levelsList,
      isDefault: (map['is_default'] == 1 || map['is_default'] == true),
    );
  }
}
