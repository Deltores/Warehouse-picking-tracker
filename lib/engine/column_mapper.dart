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
  static const String keyComponentResourceId = 'component_resource_id';
  static const String keyOnHand = 'on_hand';
  static const String keyDeptType = 'dept_type';

  final Map<String, List<String>> aliases;

  ColumnMapper({Map<String, List<String>>? customAliases})
      : aliases = _initAliases(customAliases);

  static Map<String, List<String>> _initAliases(Map<String, List<String>>? custom) {
    final map = <String, List<String>>{};
    for (final entry in defaultAliases.entries) {
      map[entry.key] = List<String>.from(entry.value);
    }
    if (custom != null) {
      for (final entry in custom.entries) {
        if (!map.containsKey(entry.key)) {
          map[entry.key] = List<String>.from(entry.value);
        } else {
          final existingNorm = entry.value.map((s) => normalize(s)).toSet();
          final list = List<String>.from(entry.value);
          for (final def in defaultAliases[entry.key] ?? <String>[]) {
            if (existingNorm.add(normalize(def))) {
              list.add(def);
            }
          }
          map[entry.key] = list;
        }
      }
    }
    return map;
  }

  static Map<String, List<String>> get defaultAliases => {
    keyComponentResourceId: [
      'COMPONENT RESOURCE ID',
      'COMPONENT RESOURCE',
      'COMPONENT_RESOURCE_ID',
      'COMPONENT_RESOURCE',
      'COMP RESOURCE ID',
      'COMP RESOURCE',
      'COMP_RESOURCE_ID',
      'COMP_RESOURCE',
      'COMPONENT RES ID',
      'COMP RES ID',
      'COMPONENT RES',
      'COMP RES',
      'COMPONENT WORK CENTER',
      'COMPONENT WORKCENTER',
      'COMPONENT WC',
      'COMPONENT SPEC',
      'COMP SPEC',
      'PART RESOURCE',
      'PART RESOURCE ID',
      'SOURCE RESOURCE',
      'SOURCE RESOURCE ID',
    ],
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
      'ON-HAND',
      'ON HAND QTY',
      'ON-HAND QTY',
      'ON_HAND_QTY',
      'ONHAND QTY',
      'ON HAND QUANTITY',
      'ON-HAND QUANTITY',
      'ON HAND LOCATION',
      'ON-HAND LOCATION',
      'ON_HAND_LOCATION',
      'ON HAND LOC',
      'ON-HAND LOC',
      'ON_HAND_LOC',
      'ON HAND STOCK',
      'ON-HAND STOCK',
      'QTY ON HAND',
      'QTY ON-HAND',
      'QTY_ON_HAND',
      'QTY ONHAND',
      'STOCK ON HAND',
      'STOCK_ON_HAND',
      'TOTAL ON HAND',
      'CURRENT ON HAND',
      'LOCATIONS',
      'LOCATION',
      'LOC',
      'BIN LOCATION',
      'BIN LOC',
      'BIN_LOCATION',
      'BIN',
      'BINS',
      'STORAGE LOCATION',
      'WAREHOUSE LOCATION',
      'WH LOCATION',
      'WH LOC',
      'STOCK LOCATION',
      'STOCK',
      'STOCK QTY',
      'CURRENT STOCK',
      'PRIMARY BIN',
      'PRIMARY LOCATION',
      'ITEM LOCATION',
      'PART LOCATION',
      'AVAILABLE',
      'AVAIL',
      'AVAILABLE QTY',
      'AVAIL QTY',
      'INVENTORY',
      'INV',
      'INVENTORY LOCATION',
      'INV LOCATION',
      'OH',
      'OH QTY',
      'OH LOC',
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
    // 1. Exact match pass
    for (final entry in aliases.entries) {
      for (final alias in entry.value) {
        if (cleaned == normalize(alias)) {
          return entry.key;
        }
      }
    }
    // Direct ON-HAND match pass
    if (cleaned == 'ON HAND' || cleaned.contains('ON HAND') || cleaned.contains('ONHAND')) {
      if (aliases.containsKey(keyOnHand)) return keyOnHand;
    }
    // 2. Secondary loose containment check if exact match fails
    for (final entry in aliases.entries) {
      // Prevent keyResourceId or keyPartId from loosely matching component resource headers
      if ((entry.key == keyResourceId || entry.key == keyPartId) &&
          (cleaned.contains('COMPONENT') || cleaned.contains('COMP ') || cleaned.startsWith('COMP'))) {
        continue;
      }
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
