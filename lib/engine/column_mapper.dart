import 'dart:convert';

class ColumnMapper {
  static const String keyUnit = 'unit';
  static const String keyDepartment = 'department';
  static const String keyLine = 'line';
  static const String keyWorkOrder = 'work_order';
  static const String keyPartId = 'part_id';
  static const String keyPartDescription = 'part_description';
  static const String keyQtyRequired = 'qty_required';
  static const String keyQtyDue = 'qty_due';
  static const String keyQtyPicked = 'qty_picked';
  static const String keyPickDate = 'pick_date';
  static const String keyProdDate = 'prod_date';
  static const String keyResourceId = 'resource_id';
  static const String keyOnHand = 'on_hand';
  static const String keyDeptType = 'dept_type';

  final Map<String, List<String>> aliases;

  ColumnMapper({Map<String, List<String>>? customAliases})
      : aliases = customAliases ?? defaultAliases;

  static Map<String, List<String>> get defaultAliases => {
    keyResourceId: [
      'RESOURCE ID',
      'RESOURCE_ID',
      'RESOURCE',
      'RESOURCEID',
      'RES ID',
      'WORK CENTER',
      'WORKCENTER',
      'WC',
      'MACHINE',
    ],
    keyOnHand: [
      'ON HAND',
      'ON_HAND',
      'ONHAND',
      'STOCK',
      'QTY ON HAND',
      'LOCATIONS',
      'LOCATION',
      'BIN LOCATION',
      'BIN',
      'STORAGE LOCATION',
    ],
    keyUnit: [
      'UNIT',
      'UNIT#',
      'UNIT NUMBER',
      'UNIT ID',
      'UNIT NAME',
    ],
    keyDepartment: [
      'DEPARTMENT',
      'DEPT',
      'AREA',
      'DEPT NAME',
      'SECTION',
    ],
    keyLine: [
      'LINE',
      'PROD LINE',
      'PRODUCTION LINE',
      'LINE NUMBER',
      'LINE#',
    ],
    keyWorkOrder: [
      'WORK ORDER',
      'WO',
      'WO#',
      'WORKORDER',
      'ORDER NUMBER',
      'ORDER',
      'WORK ORDER (WO)',
      'WORK ORDER WO',
    ],
    keyPartId: [
      'PART ID',
      'PART',
      'PART#',
      'PART NUMBER',
      'ITEM NUMBER',
      'SKU',
      'COMPONENT',
    ],
    keyPartDescription: [
      'PART DESCRIPTION',
      'DESCRIPTION',
      'PART DESC',
      'DESC',
      'ITEM DESCRIPTION',
    ],
    keyQtyRequired: [
      'QTY REQUIRED',
      'REQUIRED QTY',
      'REQ QTY',
      'QTY REQ',
      'REQUIRED',
      'REQ',
      'QUANTITY REQUIRED',
    ],
    keyQtyDue: [
      'QTY DUE',
      'DUE QTY',
      'DUE',
      'REMAINING',
      'QTY REMAINING',
      'BALANCE',
    ],
    keyQtyPicked: [
      'QTY PICKED',
      'PICKED QTY',
      'PICKED',
      'QTY ISSUED',
      'ISSUED QTY',
      'COLLECTED',
    ],
    keyPickDate: [
      'PICK DATE',
      'PICKDATE',
      'DATE PICK',
      'PICKING DATE',
      'PICK_DATE',
      'DUE DATE',
    ],
    keyProdDate: [
      'PROD DATE',
      'PRODDATE',
      'PRODUCTION DATE',
      'PROD_DATE',
      'PROD',
    ],
    keyDeptType: [
      'DEPT TYPE',
      'DEPARTMENT TYPE',
      'LINE TYPE',
      'TYPE',
      'DEPT CATEGORY',
      'CATEGORY',
    ],
  };

  /// Normalizes a raw dept-type cell value to 'MAIN LINE', 'SUBASSEMBLY', or ''.
  /// Values containing MAIN or MACG are treated as MAIN LINE.
  static String parseDeptType(String rawValue) {
    final up = rawValue.toUpperCase().trim();
    if (up.isEmpty) return '';
    if (up.contains('MAIN') || up.contains('MACG')) return 'MAIN LINE';
    if (up.contains('SUB') || up.contains('ASSEMBLY') || up.contains('SUBASS')) return 'SUBASSEMBLY';
    // If the cell just says a dept name, return it uppercased for future use
    return up;
  }

  /// Normalizes a string by converting to uppercase, stripping special characters, and trimming spaces.
  static String normalize(String raw) {
    return raw
        .toUpperCase()
        .replaceAll(RegExp(r'[\(\)\[\]_\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Identifies the canonical key for a given raw header title.
  String? identifyColumn(String rawHeader) {
    final cleaned = normalize(rawHeader);
    for (final entry in aliases.entries) {
      for (final alias in entry.value) {
        if (cleaned == normalize(alias)) {
          return entry.key;
        }
      }
    }
    // Secondary loose containment check if exact match fails
    for (final entry in aliases.entries) {
      for (final alias in entry.value) {
        final normAlias = normalize(alias);
        if (cleaned.contains(normAlias) || normAlias.contains(cleaned)) {
          return entry.key;
        }
      }
    }
    return null;
  }

  /// Add a custom alias for a canonical column
  void addAlias(String canonicalKey, String newAlias) {
    if (!aliases.containsKey(canonicalKey)) {
      aliases[canonicalKey] = [];
    }
    final norm = normalize(newAlias);
    if (!aliases[canonicalKey]!.contains(norm)) {
      aliases[canonicalKey]!.add(norm);
    }
  }

  /// Removes an alias for a canonical column
  bool removeAlias(String canonicalKey, String aliasToRemove) {
    if (!aliases.containsKey(canonicalKey)) return false;
    final norm = normalize(aliasToRemove);
    return aliases[canonicalKey]!.remove(norm) || aliases[canonicalKey]!.remove(aliasToRemove);
  }

  String toJson() => jsonEncode(aliases);

  factory ColumnMapper.fromJson(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final map = <String, List<String>>{};
      for (final e in decoded.entries) {
        map[e.key] = (e.value as List).map((i) => i.toString()).toList();
      }
      return ColumnMapper(customAliases: map);
    } catch (_) {
      return ColumnMapper();
    }
  }
}
