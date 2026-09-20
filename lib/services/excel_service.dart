import 'dart:io';
import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../engine/column_mapper.dart';
import '../models/picklist_item.dart';
import '../models/session_metadata.dart';
import 'log_service.dart';

class ExcelService {
  final ColumnMapper columnMapper;

  ExcelService({ColumnMapper? mapper}) : columnMapper = mapper ?? ColumnMapper();

  /// Reads an Excel (.xlsx) picklist file and maps its columns using the dynamic [columnMapper].
  /// Returns a tuple-like Map containing:
  /// - 'unitId': inferred or found unit name
  /// - 'departments': set of detected department names
  /// - 'items': list of parsed [PicklistItem] objects
  Future<Map<String, dynamic>> parseExcelFile(
    String filePath, {
    List<String> autoIssueDepartments = const [],
    List<String> autoIssueResourceIds = const [],
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Excel file not found at path: $filePath');
    }

    final bytes = await file.readAsBytes();
    final excel = Excel.decodeBytes(bytes);

    if (excel.tables.isEmpty) {
      throw Exception('The provided Excel file contains no worksheets.');
    }

    // Use first non-empty sheet
    String? targetSheetName;
    for (final name in excel.tables.keys) {
      if (excel.tables[name]?.rows.isNotEmpty ?? false) {
        targetSheetName = name;
        break;
      }
    }

    if (targetSheetName == null) {
      throw Exception('All worksheets in the Excel file are empty.');
    }

    final sheet = excel.tables[targetSheetName]!;
    if (sheet.rows.isEmpty) {
      throw Exception('Worksheet has no rows.');
    }

    // 1. Identify header row (usually row 0)
    final headerRow = sheet.rows.first;
    final columnIndexMap = <String, int>{};
    final originalHeaders = <String>[];

    for (int col = 0; col < headerRow.length; col++) {
      final cell = headerRow[col];
      final rawValue = cell?.value?.toString() ?? '';
      originalHeaders.add(rawValue);
      if (rawValue.trim().isNotEmpty) {
        final canonicalKey = columnMapper.identifyColumn(rawValue);
        if (canonicalKey != null) {
          columnIndexMap[canonicalKey] = col;
        }
      }
    }

    final defaultUnitName = p.basenameWithoutExtension(filePath);
    final items = <PicklistItem>[];
    final departments = <String>{};
    const uuid = Uuid();

    final fileUnitId = defaultUnitName;

    // 2. Parse data rows
    for (int rowIdx = 1; rowIdx < sheet.rows.length; rowIdx++) {
      final row = sheet.rows[rowIdx];
      if (row.isEmpty) continue;

      String getVal(String canonicalKey, [String defaultValue = '']) {
        final colIdx = columnIndexMap[canonicalKey];
        if (colIdx == null || colIdx >= row.length) return defaultValue;
        final cell = row[colIdx];
        if (cell == null || cell.value == null) return defaultValue;
        return cell.value.toString().trim();
      }

      double getDoubleVal(String canonicalKey, [double defaultValue = 0.0]) {
        final str = getVal(canonicalKey, '');
        if (str.isEmpty) return defaultValue;
        final parsed = double.tryParse(str.replaceAll(',', ''));
        return parsed ?? defaultValue;
      }

      // Collect all raw column key-value pairs for dynamic preservation on export
      final rawColumns = <String, dynamic>{};
      for (int c = 0; c < originalHeaders.length && c < row.length; c++) {
        final h = originalHeaders[c].trim();
        if (h.isNotEmpty) {
          final cell = row[c];
          rawColumns[h] = cell?.value?.toString() ?? '';
        }
      }

      final subUnit = getVal(ColumnMapper.keyUnit, defaultUnitName);
      final rawDept = getVal(ColumnMapper.keyDepartment, '');
      final department = rawDept.trim().isEmpty ? '(Empty / Unassigned)' : rawDept.trim();
      final line = getVal(ColumnMapper.keyLine, 'Line 1');
      final workOrder = getVal(ColumnMapper.keyWorkOrder, 'WO-0');
      final partId = getVal(ColumnMapper.keyPartId, '');
      final partDesc = getVal(ColumnMapper.keyPartDescription, '');
      final qtyReq = getDoubleVal(ColumnMapper.keyQtyRequired, 0.0);
      double qtyDue = getDoubleVal(ColumnMapper.keyQtyDue, qtyReq);
      double qtyPicked = getDoubleVal(ColumnMapper.keyQtyPicked, 0.0);
      final pickDate = getVal(ColumnMapper.keyPickDate, '');
      final prodDate = getVal(ColumnMapper.keyProdDate, '');
      final resourceId = getVal(ColumnMapper.keyResourceId, '');
      final componentResourceId = getVal(ColumnMapper.keyComponentResourceId, '');
      var onHand = getVal(ColumnMapper.keyOnHand, '');
      if (onHand.isEmpty) {
        for (final entry in rawColumns.entries) {
          final norm = ColumnMapper.normalize(entry.key);
          if (norm == 'ON HAND' ||
              norm.contains('ON HAND') ||
              norm.contains('ONHAND') ||
              norm.contains('LOCATION') ||
              norm.contains('BIN') ||
              norm.contains('STOCK') ||
              norm.contains('INVENTORY') ||
              norm == 'BIN LOCATION' ||
              norm == 'BIN LOC' ||
              norm == 'LOCATION' ||
              norm == 'LOC' ||
              norm == 'STOCK' ||
              norm == 'OH') {
            final v = entry.value?.toString().trim() ?? '';
            if (v.isNotEmpty && v.toLowerCase() != 'null') {
              onHand = v;
              break;
            }
          }
        }
      }
      var uom = getVal(ColumnMapper.keyUom, '');
      if (uom.isEmpty) {
        for (final entry in rawColumns.entries) {
          final norm = ColumnMapper.normalize(entry.key);
          if (norm == 'UOM' ||
              norm == 'UM' ||
              norm == 'U M' ||
              norm == 'UNIT OF MEASURE' ||
              norm == 'UNIT OF MEASUREMENT' ||
              norm == 'MEASURE' ||
              norm == 'MEAS' ||
              norm == 'QTY UOM' ||
              norm == 'UOM CODE') {
            final v = entry.value?.toString().trim() ?? '';
            if (v.isNotEmpty && v.toLowerCase() != 'null') {
              uom = v;
              break;
            }
          }
        }
      }
      rawColumns['_uom'] = uom.isNotEmpty ? uom : 'NA';

      final deptTypeRaw = getVal(ColumnMapper.keyDeptType, '');
      final deptType = ColumnMapper.parseDeptType(deptTypeRaw);

      // Auto-issue: applies to Component Resources (where parts originate from)
      final isPtfDept = department.toUpperCase().contains('PTF');
      final isComponentEmpty = componentResourceId.trim().isEmpty;
      final isAutoResource = isComponentEmpty
          ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
          : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == componentResourceId.trim().toLowerCase());
      if (autoIssueDepartments.contains(department) || isPtfDept || isAutoResource) {
        qtyPicked = qtyReq;
        qtyDue = 0.0;
      }

      // Skip row if partId is blank
      if (partId.isEmpty && qtyReq <= 0) continue;

      departments.add(department);

      items.add(PicklistItem(
        id: uuid.v4(),
        unitId: fileUnitId,
        department: department,
        line: line,
        workOrder: workOrder,
        partId: partId,
        partDescription: partDesc,
        qtyRequired: qtyReq,
        qtyDue: qtyDue,
        qtyPicked: qtyPicked,
        rowOrder: rowIdx,
        pickDate: pickDate,
        prodDate: prodDate,
        subUnit: subUnit.isNotEmpty ? subUnit : fileUnitId,
        resourceId: resourceId,
        componentResourceId: componentResourceId,
        onHand: onHand,
        deptType: deptType,
        rawColumns: rawColumns,
      ));
    }

    return {
      'unitId': fileUnitId,
      'departments': departments.toList(),
      'items': items,
      'headers': originalHeaders,
    };
  }

  /// Calculates the export sorting tier for a picklist item:
  /// - Tier 0: Any row with any comments (Picker Note, return comments, remove reason/flag, missing flag).
  /// - Tier 1: Manually added parts (isManualAdd).
  /// - Tier 2: Replaced parts (replacedPartId is not empty).
  /// - Tier 3: Standard unedited parts.
  static int getItemSortingTier({
    required PicklistItem item,
    required Map<String, String> partNotes,
    required Map<String, List<String>> returnComments,
    required Map<String, String> removeComments,
    required Map<String, dynamic>? missingFlag,
  }) {
    final pickerNote = partNotes[item.partId] ?? '';
    final hasReturn = (returnComments[item.partId]?.isNotEmpty ?? false);
    final removeNote = removeComments[item.partId] ?? item.removeNote;
    final flagType = missingFlag?['flag_type']?.toString().toUpperCase() ?? '';
    final isFlagRemoved = flagType == 'REMOVED';
    final isRemoved = item.isRemoved || removeNote.isNotEmpty || isFlagRemoved;
    final isMissing = flagType == 'MISSING';

    final hasAnyComment = pickerNote.isNotEmpty || hasReturn || isRemoved || isMissing;
    if (hasAnyComment) return 0; // Tier 0: Any comments, removed, missing, or returns
    if (item.isManualAdd) return 1; // Tier 1: Manually added parts
    if (item.replacedPartId.isNotEmpty) return 2; // Tier 2: Replaced parts
    return 3; // Tier 3: Standard parts
  }

  static int compareItemsByTier({
    required PicklistItem a,
    required PicklistItem b,
    required Map<String, String> partNotes,
    required Map<String, List<String>> returnComments,
    required Map<String, String> removeComments,
    required Map<String, Map<String, dynamic>> partFlags,
  }) {
    final tierA = getItemSortingTier(
      item: a,
      partNotes: partNotes,
      returnComments: returnComments,
      removeComments: removeComments,
      missingFlag: partFlags[a.partId],
    );
    final tierB = getItemSortingTier(
      item: b,
      partNotes: partNotes,
      returnComments: returnComments,
      removeComments: removeComments,
      missingFlag: partFlags[b.partId],
    );
    if (tierA != tierB) {
      return tierA.compareTo(tierB);
    }
    return a.rowOrder.compareTo(b.rowOrder);
  }

  static String formatMissingComment(Map<String, dynamic> flag) {
    final ts = flag['created_at'] as int?;
    final dateStr = ts != null
        ? DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(ts))
        : '';
    final note = flag['note']?.toString() ?? '';
    String pickerName = flag['worker_name']?.toString() ?? '';
    if (pickerName.isEmpty) {
      if (note.contains('Marked missing by ')) {
        pickerName = note.replaceAll('Marked missing by ', '').replaceAll(' in Pick Mode', '').trim();
      } else if (note.isNotEmpty) {
        pickerName = note;
      } else {
        pickerName = 'Picker';
      }
    }
    return '⚠️ MISSING • $pickerName${dateStr.isNotEmpty ? ' • $dateStr' : ''}';
  }

  /// Exports the picking results to a new file named after the session display name.
  ///
  /// Output path: `{exportDir}/{sessionDisplayName}_{timestamp}.xlsx`
  /// A backup of the source file is also created next to the source.
  ///
  /// [returnComments]: map of {partId: [comment1, comment2, ...]} for the RETURN COMMENTS column.
  /// If [outputPath] is provided it overrides the auto-generated path.
  ///
  /// Returns the final output file path.
  Future<String> exportAndOverwrite({
    required String originalFilePath,
    required List<PicklistItem> items,
    required SessionMetadata session,
    String unitName = '',
    Map<String, List<String>> returnComments = const {},
    String? outputPath,
    List<String> autoIssueResourceIds = const [],
    Map<String, String> removeComments = const {},
    List<Map<String, dynamic>> manualPicks = const [],
    Map<String, String> partNotes = const {},
    Map<String, Map<String, dynamic>> partFlags = const {},
  }) async {
    final originalFile = File(originalFilePath);
    if (!await originalFile.exists()) {
      throw Exception('Source file not found: $originalFilePath');
    }

    // 1. Determine output path — named after session display name
    final dir = originalFile.parent.path;
    final ts = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final displayName = session.displayName(unitName).replaceAll(RegExp(r'[^\w_\-]'), '_');
    final sessionFileName = '${displayName}_$ts.xlsx';
    final resolvedOutputPath = outputPath ?? p.join(dir, sessionFileName);
    final backupPath = p.join(dir, '${session.id}_backup.xlsx');

    // 2. Create a backup of the source file before any writes
    try {
      await originalFile.copy(backupPath);
    } catch (e) {
      LogService.warn('EXCEL', 'Could not create backup next to original ($backupPath): $e');
    }

    // 2. Decode original workbook to preserve existing structure and formatting
    final bytes = await originalFile.readAsBytes();
    final excel = Excel.decodeBytes(bytes);

    String targetSheetName = excel.tables.keys.first;
    for (final name in excel.tables.keys) {
      if (excel.tables[name]?.rows.isNotEmpty ?? false) {
        targetSheetName = name;
        break;
      }
    }

    final sheet = excel.tables[targetSheetName]!;

    // Precalculate Work Order progress per (department, workOrder) with equal Part ID weighting:
    final woGroups = <String, List<PicklistItem>>{};
    for (final item in items) {
      final key = '${item.department}___${item.workOrder}';
      woGroups.putIfAbsent(key, () => []).add(item);
    }

    final woStatusMap = <String, String>{};
    final woProgressMap = <String, String>{};

    for (final entry in woGroups.entries) {
      final woItems = entry.value;
      // Group by unique partId
      final partReqMap = <String, double>{};
      final partPickedMap = <String, double>{};
      for (final it in woItems) {
        partReqMap[it.partId] = (partReqMap[it.partId] ?? 0.0) + it.qtyRequired;
        partPickedMap[it.partId] = (partPickedMap[it.partId] ?? 0.0) + it.qtyPicked;
      }

      if (partReqMap.isEmpty) {
        woStatusMap[entry.key] = 'Not Picked';
        woProgressMap[entry.key] = '0.0%';
        continue;
      }

      double totalRatio = 0.0;
      for (final partId in partReqMap.keys) {
        final req = partReqMap[partId] ?? 0.0;
        final picked = partPickedMap[partId] ?? 0.0;
        if (req > 0) {
          final ratio = (picked / req).clamp(0.0, 1.0);
          totalRatio += ratio;
        } else {
          totalRatio += 1.0;
        }
      }

      final progressRatio = totalRatio / partReqMap.length;
      final progressPercent = progressRatio * 100.0;
      woProgressMap[entry.key] = '${progressPercent.toStringAsFixed(1)}%';

      if (progressRatio >= 1.0) {
        woStatusMap[entry.key] = 'Fully Picked';
      } else if (progressRatio > 0.0) {
        woStatusMap[entry.key] = 'Partially Picked';
      } else {
        woStatusMap[entry.key] = 'Not Picked';
      }
    }

    // 1. Gather original headers and order them with 'Qty Picked' between Required and Due
    final origHeaderRow = sheet.rows.first;
    final origHeaders = origHeaderRow.map((c) => c?.value?.toString().trim() ?? '').toList();
    final orderedHeaders = orderHeadersWithQtyPicked(origHeaders);

    final headerToCol = <String, int>{};
    int? colPicked;
    int? colDue;

    for (int i = 0; i < orderedHeaders.length; i++) {
      final h = orderedHeaders[i];
      headerToCol[h.toLowerCase()] = i;
      final key = columnMapper.identifyColumn(h);
      if (key == ColumnMapper.keyQtyPicked && colPicked == null) colPicked = i;
      if (key == ColumnMapper.keyQtyDue && colDue == null) colDue = i;
    }

    // Next available column index for service headers
    int nextCol = orderedHeaders.length;
    final serviceHeaders = [
      'WO Status',
      'WO Progress %',
      'Total Picked',
      'Session Picked',
      'Session ID',
      'Worker Name',
      'Pick Date',
      'Start Time',
      'End Time',
      'Issued Status',
      'Technical Comments',
      'Picker Note',
    ];

    final serviceColIndices = <String, int>{};
    for (final sHeader in serviceHeaders) {
      int? existingCol = headerToCol[sHeader.toLowerCase()];
      if (sHeader == 'Technical Comments' && existingCol == null) {
        existingCol = headerToCol['system comments'];
      }
      if (existingCol != null) {
        serviceColIndices[sHeader] = existingCol;
      } else {
        serviceColIndices[sHeader] = nextCol;
        nextCol++;
      }
    }

    // Create item lookup by rowOrder or partId+workOrder
    final itemByRowOrder = <int, PicklistItem>{};
    for (final item in items) {
      itemByRowOrder[item.rowOrder] = item;
    }

    final timeFormatter = DateFormat('HH:mm:ss');
    final startTimeStr = timeFormatter.format(DateTime.fromMillisecondsSinceEpoch(session.startTime));
    final endTimeStr = session.endTime != null
        ? timeFormatter.format(DateTime.fromMillisecondsSinceEpoch(session.endTime!))
        : '';

    // Create a new Excel workbook containing ONLY picked or auto-issued rows
    final outExcel = Excel.createExcel();
    final defaultSheet = outExcel.getDefaultSheet();
    final outSheet = outExcel[targetSheetName];
    if (defaultSheet != null && defaultSheet != targetSheetName) {
      outExcel.delete(defaultSheet);
    }

    // Write row 0 headers (ordered original columns + service columns)
    for (int i = 0; i < orderedHeaders.length; i++) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0)).value =
          TextCellValue(orderedHeaders[i]);
    }
    for (final entry in serviceColIndices.entries) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: entry.value, rowIndex: 0)).value =
          TextCellValue(entry.key);
    }

    int outRowIdx = 1;

    CellValue qtyToCell(double val) {
      if (val % 1 == 0) return IntCellValue(val.toInt());
      return DoubleCellValue(val);
    }

    // Incorporate manual picks into export items if not already present
    final allExportItems = List<PicklistItem>.from(items);
    final existingPartIds = allExportItems.map((i) => i.partId).toSet();
    for (final mp in manualPicks) {
      final mpPartId = mp['part_id']?.toString() ?? '';
      if (mpPartId.isNotEmpty && !existingPartIds.contains(mpPartId)) {
        final mpQty = (mp['qty_picked'] as num?)?.toDouble() ?? 0.0;
        final mpNote = mp['note']?.toString() ?? '';
        final mpDept = mp['department']?.toString() ?? '';
        final mpWo = mp['work_order']?.toString() ?? 'MANUAL';
        final mpWorker = mp['worker_name']?.toString() ?? session.workerName;
        allExportItems.add(PicklistItem(
          id: 'manual_${mpPartId}_${mp['created_at']}',
          unitId: session.unitId,
          department: mpDept,
          line: '',
          workOrder: mpWo,
          partId: mpPartId,
          partDescription: mpNote,
          qtyRequired: mpQty,
          qtyDue: 0.0,
          qtyPicked: mpQty,
          rowOrder: 999999,
          rawColumns: {
            '_manual_add': true,
            '_manual_note': mpNote,
            '_manual_worker': mpWorker,
          },
        ));
      }
    }

    // Collect eligible rows first so we can sort (Tier 0 Comments -> Tier 1 Added -> Tier 2 Replaced -> Tier 3 Standard)
    final eligibleItems = <PicklistItem>[];
    for (final item in allExportItems) {
      final isComponentResEmpty = item.componentResourceId.trim().isEmpty;
      final isAutoResource = isComponentResEmpty
          ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
          : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.componentResourceId.trim().toLowerCase());

      final tier = getItemSortingTier(
        item: item,
        partNotes: partNotes,
        returnComments: returnComments,
        removeComments: removeComments,
        missingFlag: partFlags[item.partId],
      );
      final isNonStandard = tier < 3;

      final shouldExport = item.qtyPicked > 0.0001 || isAutoResource || isNonStandard;
      if (!shouldExport) {
        continue;
      }
      eligibleItems.add(item);
    }

    // Sort: Tier 0 (Comments) -> Tier 1 (Added) -> Tier 2 (Replaced) -> Tier 3 (Standard)
    eligibleItems.sort((a, b) => compareItemsByTier(
          a: a,
          b: b,
          partNotes: partNotes,
          returnComments: returnComments,
          removeComments: removeComments,
          partFlags: partFlags,
        ));

    // Export eligible data rows
    for (final item in eligibleItems) {
      final rowIdx = item.rowOrder;
      final isComponentResEmpty = item.componentResourceId.trim().isEmpty;
      final isAutoResource = isComponentResEmpty
          ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
          : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.componentResourceId.trim().toLowerCase());

      if (rowIdx > 0 && rowIdx < sheet.rows.length) {
        // Copy original cells from this row according to header mapping
        final origRow = sheet.rows[rowIdx];
        for (int c = 0; c < origRow.length && c < origHeaders.length; c++) {
          final cellVal = origRow[c]?.value;
          final targetCol = headerToCol[origHeaders[c].toLowerCase()];
          if (targetCol != null && cellVal != null) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value = cellVal;
          }
        }
      } else {
        // Manually added part or row outside original sheet
        for (final h in orderedHeaders) {
          final key = columnMapper.identifyColumn(h);
          final targetCol = headerToCol[h.toLowerCase()];
          if (targetCol == null) continue;
          if (key == ColumnMapper.keyPartId) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.partId);
          } else if (key == ColumnMapper.keyPartDescription) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.partDescription.isNotEmpty ? item.partDescription : (item.manualNote.isNotEmpty ? 'MANUAL ADD: ${item.manualNote}' : ''));
          } else if (key == ColumnMapper.keyDepartment) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.department);
          } else if (key == ColumnMapper.keyWorkOrder) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.workOrder);
          } else if (key == ColumnMapper.keyLine) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.line);
          } else if (key == ColumnMapper.keyResourceId) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.resourceId);
          } else if (key == ColumnMapper.keyComponentResourceId) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.componentResourceId);
          } else if (key == ColumnMapper.keyUom) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.uom);
          } else if (key == ColumnMapper.keyOnHand) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.onHand);
          } else if (key == ColumnMapper.keyUnit) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                TextCellValue(item.subUnit.isNotEmpty ? item.subUnit : unitName);
          }
        }
      }

      // Also copy any raw columns from item.rawColumns if not already set
      for (final e in item.rawColumns.entries) {
        if (e.key.startsWith('_')) continue;
        final targetCol = headerToCol[e.key.toLowerCase()];
        if (targetCol != null) {
          final cell = outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx));
          cell.value ??= TextCellValue(e.value.toString());
        }
      }

      final woKey = '${item.department}___${item.workOrder}';
      final woStatus = woStatusMap[woKey] ?? 'Not Picked';
      final woProgress = woProgressMap[woKey] ?? '0.0%';

      final pickedVal = isAutoResource ? item.qtyRequired : item.qtyPicked;
      final dueVal = isAutoResource ? 0.0 : item.qtyDue;

      // Update Qty Picked & Qty Due in their properly ordered columns
      if (colPicked != null) {
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colPicked, rowIndex: outRowIdx)).value =
            qtyToCell(pickedVal);
      }
      if (colDue != null) {
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colDue, rowIndex: outRowIdx)).value =
            qtyToCell(dueVal);
      }

      // Set WO Status & Progress Columns
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['WO Status']!, rowIndex: outRowIdx)).value =
          TextCellValue(woStatus);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['WO Progress %']!, rowIndex: outRowIdx)).value =
          TextCellValue(woProgress);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Total Picked']!, rowIndex: outRowIdx)).value =
          qtyToCell(pickedVal);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Session Picked']!, rowIndex: outRowIdx)).value =
          qtyToCell(pickedVal);

      // Set ERP Audit Columns
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Session ID']!, rowIndex: outRowIdx)).value =
          TextCellValue(session.id);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Worker Name']!, rowIndex: outRowIdx)).value =
          TextCellValue(session.workerName);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Pick Date']!, rowIndex: outRowIdx)).value =
          TextCellValue(item.pickDate.isNotEmpty ? item.pickDate : session.pickDate);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Start Time']!, rowIndex: outRowIdx)).value =
          TextCellValue(startTimeStr);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['End Time']!, rowIndex: outRowIdx)).value =
          TextCellValue(endTimeStr);
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Issued Status']!, rowIndex: outRowIdx)).value =
          TextCellValue(session.issuedStatus);

      // Populate Technical Comments and Picker Note
      final techComments = <String>[];
      if (item.isManualAdd) {
        techComments.add('➕ MANUAL ADD${item.manualWorker.isNotEmpty ? ' • by ${item.manualWorker}' : ''}${item.manualNote.isNotEmpty ? ': "${item.manualNote}"' : ''}');
      }
      if (item.replacedPartId.isNotEmpty) {
        techComments.add('🔄 REPLACED • was: ${item.replacedPartId}${item.replacementNote.isNotEmpty ? ' (${item.replacementNote})' : ''}');
      }
      var removeNote = removeComments[item.partId] ?? item.removeNote;
      final flagType = partFlags[item.partId]?['flag_type']?.toString().toUpperCase() ?? '';
      if (removeNote.isEmpty && flagType == 'REMOVED') {
        removeNote = partFlags[item.partId]?['note']?.toString() ?? '';
      }
      if (item.isRemoved || removeNote.isNotEmpty || flagType == 'REMOVED') {
        techComments.add('⛔ REMOVED FROM PICKING${removeNote.isNotEmpty ? ' • $removeNote' : ''}');
      }
      final missingFlag = partFlags[item.partId];
      if (missingFlag != null && missingFlag['flag_type']?.toString().toUpperCase() == 'MISSING') {
        techComments.add(formatMissingComment(missingFlag));
      }
      final itemRetComments = returnComments[item.partId] ?? [];
      if (itemRetComments.isNotEmpty) {
        techComments.add('RETURN: ${itemRetComments.join(', ')}');
      }
      final techCol = serviceColIndices['Technical Comments'] ?? serviceColIndices['System Comments'];
      if (techCol != null) {
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: techCol, rowIndex: outRowIdx)).value =
            TextCellValue(techComments.join(' | '));
      }
      if (serviceColIndices.containsKey('Picker Note')) {
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Picker Note']!, rowIndex: outRowIdx)).value =
            TextCellValue(partNotes[item.partId] ?? '');
      }

      outRowIdx++;
    }

    // 3. Encode and write to the session-named output file (NOT the source file)
    final updatedBytes = outExcel.encode();
    if (updatedBytes != null) {
      try {
        final outputFile = File(resolvedOutputPath);
        if (!await outputFile.parent.exists()) {
          await outputFile.parent.create(recursive: true);
        }
        await outputFile.writeAsBytes(updatedBytes, flush: true);
        LogService.info('EXCEL', 'Exported session to: $resolvedOutputPath');
        return resolvedOutputPath;
      } on FileSystemException catch (e) {
        LogService.warn('EXCEL', 'Failed writing to $resolvedOutputPath ($e). Trying fallback storage directory.');
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final fallbackPath = p.join(appDir.path, sessionFileName);
          final fallbackFile = File(fallbackPath);
          await fallbackFile.writeAsBytes(updatedBytes, flush: true);
          LogService.info('EXCEL', 'Exported session via fallback to: $fallbackPath');
          return fallbackPath;
        } catch (fallbackErr) {
          LogService.error('EXCEL', 'Fallback export also failed: $fallbackErr');
          rethrow;
        }
      }
    }

    return resolvedOutputPath;
  }

  /// Reorders [rawHeaders] such that the 'Qty Picked' column is placed
  /// directly between 'Qty Required' and 'Qty Due'.
  /// Preserves all other original and arbitrary columns in their relative order.
  static List<String> orderHeadersWithQtyPicked(List<String> rawHeaders, [ColumnMapper? mapper]) {
    final colMapper = mapper ?? ColumnMapper();
    final headers = List<String>.from(rawHeaders);
    int? pickedIdx;
    int? reqIdx;
    int? dueIdx;

    for (int i = 0; i < headers.length; i++) {
      final key = colMapper.identifyColumn(headers[i]);
      if (key == ColumnMapper.keyQtyPicked) pickedIdx = i;
      if (key == ColumnMapper.keyQtyRequired) reqIdx = i;
      if (key == ColumnMapper.keyQtyDue) dueIdx = i;
    }

    String pickedHeaderName = 'Qty Picked';
    if (pickedIdx != null) {
      pickedHeaderName = headers.removeAt(pickedIdx);
      reqIdx = null;
      dueIdx = null;
      for (int i = 0; i < headers.length; i++) {
        final key = colMapper.identifyColumn(headers[i]);
        if (key == ColumnMapper.keyQtyRequired) reqIdx = i;
        if (key == ColumnMapper.keyQtyDue) dueIdx = i;
      }
    }

    if (dueIdx != null) {
      headers.insert(dueIdx, pickedHeaderName);
    } else if (reqIdx != null) {
      headers.insert(reqIdx + 1, pickedHeaderName);
    } else {
      headers.add(pickedHeaderName);
    }

    return headers;
  }

  /// Exports a consolidated Super Export Excel file combining multiple unexported sessions
  /// across multiple units into ONE single file.
  ///
  /// The consolidated workbook contains:
  /// - Column 0: 'File Name'
  /// - Columns 1..N: all preserved original & extra picklist columns with 'Qty Picked' placed between 'Qty Required' and 'Qty Due'
  /// - Columns N+1..: ERP audit columns (WO Status, WO Progress %, Total Picked, Session Picked, Session ID, etc.)
  Future<String> exportMultiUnitBatchSuperSession({
    required Map<String, String> unitOriginalFiles,
    required Map<String, List<PicklistItem>> unitItems,
    required Map<String, String> unitNames,
    required List<SessionMetadata> sessions,
    required Map<String, Map<String, List<String>>> unitReturnComments,
    required String outputPath,
    Map<String, List<String>> unitAutoIssueResourceIds = const {},
    Map<String, Set<String>> unitBatchPickedPartIds = const {},
    String issuedStatus = 'Pending Issue',
    Map<String, Map<String, String>> unitRemoveComments = const {},
    Map<String, List<Map<String, dynamic>>> unitManualPicks = const {},
    Map<String, Map<String, String>> unitPartNotes = const {},
    Map<String, Map<String, Map<String, dynamic>>> unitPartFlags = const {},
  }) async {
    if (sessions.isEmpty) {
      throw Exception('No sessions provided for batch export.');
    }
    if (unitOriginalFiles.isEmpty) {
      throw Exception('No unit files provided for batch export.');
    }

    final earliestStart = sessions.map((s) => s.startTime).reduce((a, b) => a < b ? a : b);
    final latestEnd = sessions.map((s) => s.endTime ?? s.startTime).reduce((a, b) => a > b ? a : b);
    final workers = sessions
        .map((s) => s.workerName.trim())
        .where((w) => w.isNotEmpty)
        .toSet()
        .join(', ');

    final seqNos = sessions.map((s) => s.sessionSeqNo).where((n) => n > 0).toSet().toList()..sort();
    final seqListStr = seqNos.isNotEmpty
        ? seqNos.map((n) => '#$n').join(', ')
        : sessions.map((s) => s.id.length > 8 ? s.id.substring(0, 8) : s.id).join(', ');
    final sessionDetails = sessions.map((s) {
      final sSeq = s.sessionSeqNo > 0 ? '#${s.sessionSeqNo}' : s.id.substring(0, 6);
      return '$sSeq (${s.workerName}: ${s.totalItemsPicked} parts, ${s.formattedDuration})';
    }).join(' | ');
    final batchLabel = 'Batch: $seqListStr [$sessionDetails]';

    final pickDates = sessions.map((s) => s.pickDate).where((d) => d.isNotEmpty).toSet();
    final combinedPickDate = pickDates.isNotEmpty ? pickDates.join(', ') : '';

    final timeFormatter = DateFormat('HH:mm:ss');
    final startTimeStr = timeFormatter.format(DateTime.fromMillisecondsSinceEpoch(earliestStart));
    final endTimeStr = timeFormatter.format(DateTime.fromMillisecondsSinceEpoch(latestEnd));

    // 1. Gather all unique original headers across all unit files
    final allHeaders = <String>[];
    String targetSheetName = 'Sheet1';

    for (final unitId in unitOriginalFiles.keys) {
      final filePath = unitOriginalFiles[unitId];
      if (filePath == null) continue;
      final file = File(filePath);
      if (!file.existsSync()) continue;
      try {
        final bytes = file.readAsBytesSync();
        final unitExcel = Excel.decodeBytes(bytes);
        for (final name in unitExcel.tables.keys) {
          final s = unitExcel.tables[name];
          if (s != null && s.rows.isNotEmpty) {
            targetSheetName = name;
            final hRow = s.rows.first;
            for (final cell in hRow) {
              final hStr = cell?.value?.toString().trim() ?? '';
              if (hStr.isNotEmpty &&
                  !allHeaders.any((existing) => existing.toLowerCase() == hStr.toLowerCase())) {
                allHeaders.add(hStr);
              }
            }
            break;
          }
        }
      } catch (_) {}
    }

    // Fallback if allHeaders is still empty: collect from item.rawColumns
    if (allHeaders.isEmpty) {
      for (final items in unitItems.values) {
        for (final item in items) {
          for (final k in item.rawColumns.keys) {
            if (!allHeaders.any((existing) => existing.toLowerCase() == k.toLowerCase())) {
              allHeaders.add(k);
            }
          }
        }
      }
    }

    // Order headers with 'Qty Picked' placed directly between 'Qty Required' and 'Qty Due'
    final orderedHeaders = orderHeadersWithQtyPicked(allHeaders);

    // Map orderedHeaders to their column indices in outSheet (shifted by 1 for 'File Name' in col 0)
    final headerToOutCol = <String, int>{};
    int? colPicked;
    int? colDue;
    int? colUnit;

    for (int i = 0; i < orderedHeaders.length; i++) {
      final h = orderedHeaders[i];
      final col = i + 1;
      headerToOutCol[h.toLowerCase()] = col;
      final key = columnMapper.identifyColumn(h);
      if (key == ColumnMapper.keyQtyPicked && colPicked == null) colPicked = col;
      if (key == ColumnMapper.keyQtyDue && colDue == null) colDue = col;
      if (key == ColumnMapper.keyUnit && colUnit == null) colUnit = col;
    }

    int nextCol = orderedHeaders.length + 1;
    final serviceHeaders = [
      'WO Status',
      'WO Progress %',
      'Total Picked',
      'Session Picked',
      'Session ID',
      'Worker Name',
      'Pick Date',
      'Start Time',
      'End Time',
      'Issued Status',
      'Technical Comments',
      'Picker Note',
    ];

    final serviceColIndices = <String, int>{};
    for (final sHeader in serviceHeaders) {
      int? existingCol = headerToOutCol[sHeader.toLowerCase()];
      if (sHeader == 'Technical Comments' && existingCol == null) {
        existingCol = headerToOutCol['system comments'];
      }
      if (existingCol != null) {
        serviceColIndices[sHeader] = existingCol;
      } else {
        serviceColIndices[sHeader] = nextCol;
        nextCol++;
      }
    }

    // 2. Create target workbook
    final outExcel = Excel.createExcel();
    final defaultSheet = outExcel.getDefaultSheet();
    final outSheet = outExcel[targetSheetName];
    if (defaultSheet != null && defaultSheet != targetSheetName) {
      outExcel.delete(defaultSheet);
    }

    // Write row 0 headers — Column 0 is reserved for File Name
    outSheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).value =
        TextCellValue('File Name');

    for (int i = 0; i < orderedHeaders.length; i++) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: i + 1, rowIndex: 0)).value =
          TextCellValue(orderedHeaders[i]);
    }
    for (final entry in serviceColIndices.entries) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: entry.value, rowIndex: 0)).value =
          TextCellValue(entry.key);
    }

    int outRowIdx = 1;

    CellValue qtyToCell(double val) {
      if (val % 1 == 0) return IntCellValue(val.toInt());
      return DoubleCellValue(val);
    }

    // 3. Process each unit's rows
    for (final unitId in unitOriginalFiles.keys) {
      final filePath = unitOriginalFiles[unitId]!;
      final items = unitItems[unitId] ?? [];
      final unitName = unitNames[unitId] ?? unitId;
      final returnComments = unitReturnComments[unitId] ?? {};
      final removeComments = unitRemoveComments[unitId] ?? {};
      final manualPicks = unitManualPicks[unitId] ?? [];
      final autoIssueResourceIds = unitAutoIssueResourceIds[unitId] ?? [];
      final partNotes = unitPartNotes[unitId] ?? {};
      final currentUnitFlags = unitPartFlags[unitId] ?? {};

      final file = File(filePath);
      if (!await file.exists()) continue;

      final bytes = await file.readAsBytes();
      final unitExcel = Excel.decodeBytes(bytes);
      String sheetName = unitExcel.tables.keys.first;
      for (final name in unitExcel.tables.keys) {
        if (unitExcel.tables[name]?.rows.isNotEmpty ?? false) {
          sheetName = name;
          break;
        }
      }
      final unitSheet = unitExcel.tables[sheetName];
      if (unitSheet == null || unitSheet.rows.isEmpty) continue;

      // Precalculate Work Order progress per (department, workOrder) for this unit
      final woGroups = <String, List<PicklistItem>>{};
      for (final item in items) {
        final key = '${item.department}___${item.workOrder}';
        woGroups.putIfAbsent(key, () => []).add(item);
      }

      final woStatusMap = <String, String>{};
      final woProgressMap = <String, String>{};

      for (final entry in woGroups.entries) {
        final woItems = entry.value;
        final partReqMap = <String, double>{};
        final partPickedMap = <String, double>{};
        for (final it in woItems) {
          partReqMap[it.partId] = (partReqMap[it.partId] ?? 0.0) + it.qtyRequired;
          partPickedMap[it.partId] = (partPickedMap[it.partId] ?? 0.0) + it.qtyPicked;
        }

        if (partReqMap.isEmpty) {
          woStatusMap[entry.key] = 'Not Picked';
          woProgressMap[entry.key] = '0.0%';
          continue;
        }

        double totalRatio = 0.0;
        for (final partId in partReqMap.keys) {
          final req = partReqMap[partId] ?? 0.0;
          final picked = partPickedMap[partId] ?? 0.0;
          if (req > 0) {
            final ratio = (picked / req).clamp(0.0, 1.0);
            totalRatio += ratio;
          } else {
            totalRatio += 1.0;
          }
        }

        final progressRatio = totalRatio / partReqMap.length;
        final progressPercent = progressRatio * 100.0;
        woProgressMap[entry.key] = '${progressPercent.toStringAsFixed(1)}%';

        if (progressRatio >= 1.0) {
          woStatusMap[entry.key] = 'Fully Picked';
        } else if (progressRatio > 0.0) {
          woStatusMap[entry.key] = 'Partially Picked';
        } else {
          woStatusMap[entry.key] = 'Not Picked';
        }
      }

      final itemByRowOrder = <int, PicklistItem>{};
      for (final item in items) {
        itemByRowOrder[item.rowOrder] = item;
      }

      final unitHeaderRow = unitSheet.rows.first;
      final sourceFileName = p.basename(filePath);

      // Incorporate manual picks into export items for this unit if not already present
      final allUnitExportItems = List<PicklistItem>.from(items);
      final existingPartIds = allUnitExportItems.map((i) => i.partId).toSet();
      for (final mp in manualPicks) {
        final mpPartId = mp['part_id']?.toString() ?? '';
        if (mpPartId.isNotEmpty && !existingPartIds.contains(mpPartId)) {
          final mpQty = (mp['qty_picked'] as num?)?.toDouble() ?? 0.0;
          final mpNote = mp['note']?.toString() ?? '';
          final mpDept = mp['department']?.toString() ?? '';
          final mpWo = mp['work_order']?.toString() ?? 'MANUAL';
          final mpWorker = mp['worker_name']?.toString() ?? workers;
          allUnitExportItems.add(PicklistItem(
            id: 'manual_${mpPartId}_${mp['created_at']}',
            unitId: unitId,
            department: mpDept,
            line: '',
            workOrder: mpWo,
            partId: mpPartId,
            partDescription: mpNote,
            qtyRequired: mpQty,
            qtyDue: 0.0,
            qtyPicked: mpQty,
            rowOrder: 999999,
            rawColumns: {
              '_manual_add': true,
              '_manual_note': mpNote,
              '_manual_worker': mpWorker,
            },
          ));
        }
      }

      // Collect eligible rows first so we can sort (Tier 0 Comments -> Tier 1 Added -> Tier 2 Replaced -> Tier 3 Standard)
      final eligibleItems = <PicklistItem>[];
      for (final item in allUnitExportItems) {
        final isComponentResEmpty = item.componentResourceId.trim().isEmpty;
        final isAutoResource = isComponentResEmpty
            ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
            : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.componentResourceId.trim().toLowerCase());

        final batchPartIds = unitBatchPickedPartIds[unitId] ?? <String>{};
        final wasPickedInBatch = unitBatchPickedPartIds.containsKey(unitId)
            ? batchPartIds.contains(item.partId)
            : item.qtyPicked > 0.0001;

        final tier = getItemSortingTier(
          item: item,
          partNotes: partNotes,
          returnComments: returnComments,
          removeComments: removeComments,
          missingFlag: currentUnitFlags[item.partId],
        );
        final isNonStandard = tier < 3;

        if (wasPickedInBatch || isAutoResource || isNonStandard) {
          eligibleItems.add(item);
        }
      }

      // Sort: Tier 0 (Comments) -> Tier 1 (Added) -> Tier 2 (Replaced) -> Tier 3 (Standard)
      eligibleItems.sort((a, b) => compareItemsByTier(
            a: a,
            b: b,
            partNotes: partNotes,
            returnComments: returnComments,
            removeComments: removeComments,
            partFlags: currentUnitFlags,
          ));

      for (final item in eligibleItems) {
        final rowIdx = item.rowOrder;
        final isComponentResEmpty = item.componentResourceId.trim().isEmpty;
        final isAutoResource = isComponentResEmpty
            ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
            : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.componentResourceId.trim().toLowerCase());

        // Write source File Name in Column 0
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: outRowIdx)).value =
            TextCellValue(sourceFileName);

        if (rowIdx > 0 && rowIdx < unitSheet.rows.length) {
          final origRow = unitSheet.rows[rowIdx];
          for (int c = 0; c < origRow.length && c < unitHeaderRow.length; c++) {
            final uHeader = unitHeaderRow[c]?.value?.toString().trim().toLowerCase() ?? '';
            final targetCol = headerToOutCol[uHeader];
            final cellVal = origRow[c]?.value;
            if (targetCol != null && cellVal != null) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value = cellVal;
            }
          }
        } else {
          // Manually added part or row outside original sheet
          for (final h in orderedHeaders) {
            final key = columnMapper.identifyColumn(h);
            final targetCol = headerToOutCol[h.toLowerCase()];
            if (targetCol == null) continue;
            if (key == ColumnMapper.keyPartId) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.partId);
            } else if (key == ColumnMapper.keyPartDescription) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.partDescription.isNotEmpty ? item.partDescription : (item.manualNote.isNotEmpty ? 'MANUAL ADD: ${item.manualNote}' : ''));
            } else if (key == ColumnMapper.keyDepartment) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.department);
            } else if (key == ColumnMapper.keyWorkOrder) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.workOrder);
            } else if (key == ColumnMapper.keyLine) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.line);
            } else if (key == ColumnMapper.keyResourceId) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.resourceId);
            } else if (key == ColumnMapper.keyComponentResourceId) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.componentResourceId);
            } else if (key == ColumnMapper.keyUom) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.uom);
            } else if (key == ColumnMapper.keyOnHand) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.onHand);
            } else if (key == ColumnMapper.keyUnit) {
              outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value =
                  TextCellValue(item.subUnit.isNotEmpty ? item.subUnit : unitName);
            }
          }
        }

        // Also copy any raw columns from item.rawColumns if not already set
        for (final e in item.rawColumns.entries) {
          if (e.key.startsWith('_')) continue;
          final targetCol = headerToOutCol[e.key.toLowerCase()];
          if (targetCol != null) {
            final cell = outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx));
            cell.value ??= TextCellValue(e.value.toString());
          }
        }

        final woKey = '${item.department}___${item.workOrder}';
        final woStatus = woStatusMap[woKey] ?? 'Not Picked';
        final woProgress = woProgressMap[woKey] ?? '0.0%';

        final pickedVal = isAutoResource ? item.qtyRequired : item.qtyPicked;
        final dueVal = isAutoResource ? 0.0 : item.qtyDue;

        if (colPicked != null) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colPicked, rowIndex: outRowIdx)).value =
              qtyToCell(pickedVal);
        }
        if (colDue != null) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colDue, rowIndex: outRowIdx)).value =
              qtyToCell(dueVal);
        }

        if (serviceColIndices.containsKey('WO Status')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['WO Status']!, rowIndex: outRowIdx)).value =
              TextCellValue(woStatus);
        }
        if (serviceColIndices.containsKey('WO Progress %')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['WO Progress %']!, rowIndex: outRowIdx)).value =
              TextCellValue(woProgress);
        }
        if (serviceColIndices.containsKey('Total Picked')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Total Picked']!, rowIndex: outRowIdx)).value =
              qtyToCell(pickedVal);
        }
        if (serviceColIndices.containsKey('Session Picked')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Session Picked']!, rowIndex: outRowIdx)).value =
              qtyToCell(pickedVal);
        }
        if (serviceColIndices.containsKey('Session ID')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Session ID']!, rowIndex: outRowIdx)).value =
              TextCellValue(batchLabel);
        }
        if (serviceColIndices.containsKey('Worker Name')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Worker Name']!, rowIndex: outRowIdx)).value =
              TextCellValue(workers);
        }
        if (serviceColIndices.containsKey('Pick Date')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Pick Date']!, rowIndex: outRowIdx)).value =
              TextCellValue(item.pickDate.isNotEmpty ? item.pickDate : combinedPickDate);
        }
        if (serviceColIndices.containsKey('Start Time')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Start Time']!, rowIndex: outRowIdx)).value =
              TextCellValue(startTimeStr);
        }
        if (serviceColIndices.containsKey('End Time')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['End Time']!, rowIndex: outRowIdx)).value =
              TextCellValue(endTimeStr);
        }
        if (serviceColIndices.containsKey('Issued Status')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Issued Status']!, rowIndex: outRowIdx)).value =
              TextCellValue(issuedStatus);
        }
        if (colUnit != null) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colUnit, rowIndex: outRowIdx)).value =
              TextCellValue(item.subUnit.isNotEmpty ? item.subUnit : unitName);
        }

        // Populate Technical Comments and Picker Note
        final techComments = <String>[];
        if (item.isManualAdd) {
          techComments.add('➕ MANUAL ADD${item.manualWorker.isNotEmpty ? ' • by ${item.manualWorker}' : ''}${item.manualNote.isNotEmpty ? ': "${item.manualNote}"' : ''}');
        }
        if (item.replacedPartId.isNotEmpty) {
          techComments.add('🔄 REPLACED • was: ${item.replacedPartId}${item.replacementNote.isNotEmpty ? ' (${item.replacementNote})' : ''}');
        }
        var removeNote = removeComments[item.partId] ?? item.removeNote;
        final flagType = currentUnitFlags[item.partId]?['flag_type']?.toString().toUpperCase() ?? '';
        if (removeNote.isEmpty && flagType == 'REMOVED') {
          removeNote = currentUnitFlags[item.partId]?['note']?.toString() ?? '';
        }
        if (item.isRemoved || removeNote.isNotEmpty || flagType == 'REMOVED') {
          techComments.add('⛔ REMOVED FROM PICKING${removeNote.isNotEmpty ? ' • $removeNote' : ''}');
        }
        final missingFlag = currentUnitFlags[item.partId];
        if (missingFlag != null && missingFlag['flag_type']?.toString().toUpperCase() == 'MISSING') {
          techComments.add(formatMissingComment(missingFlag));
        }
        final itemRetComments = returnComments[item.partId] ?? [];
        if (itemRetComments.isNotEmpty) {
          techComments.add('RETURN: ${itemRetComments.join(', ')}');
        }
        final techCol = serviceColIndices['Technical Comments'] ?? serviceColIndices['System Comments'];
        if (techCol != null) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: techCol, rowIndex: outRowIdx)).value =
              TextCellValue(techComments.join(' | '));
        }
        if (serviceColIndices.containsKey('Picker Note')) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Picker Note']!, rowIndex: outRowIdx)).value =
              TextCellValue(partNotes[item.partId] ?? '');
        }

        outRowIdx++;
      }
    }

    final updatedBytes = outExcel.encode();
    if (updatedBytes != null) {
      try {
        final outputFile = File(outputPath);
        if (!await outputFile.parent.exists()) {
          await outputFile.parent.create(recursive: true);
        }
        await outputFile.writeAsBytes(updatedBytes, flush: true);
        LogService.info('EXCEL', 'Exported multi-unit super session to: $outputPath');
        return outputPath;
      } on FileSystemException catch (e) {
        LogService.warn('EXCEL', 'Failed writing to $outputPath ($e). Trying fallback storage directory.');
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final fileName = p.basename(outputPath);
          final fallbackPath = p.join(appDir.path, fileName);
          final fallbackFile = File(fallbackPath);
          await fallbackFile.writeAsBytes(updatedBytes, flush: true);
          LogService.info('EXCEL', 'Exported multi-unit super session via fallback to: $fallbackPath');
          return fallbackPath;
        } catch (fallbackErr) {
          LogService.error('EXCEL', 'Fallback export also failed: $fallbackErr');
          rethrow;
        }
      }
    }

    return outputPath;
  }

  /// Exports a consolidated Super Export Excel file combining multiple unexported sessions for a single unit.
  /// Delegates to [exportMultiUnitBatchSuperSession].
  Future<String> exportBatchSuperSession({
    required String originalFilePath,
    required List<PicklistItem> items,
    required List<SessionMetadata> sessions,
    required String unitName,
    required Map<String, List<String>> returnComments,
    required String outputPath,
    List<String> autoIssueResourceIds = const [],
    String issuedStatus = 'Pending Issue',
    Map<String, String> removeComments = const {},
    List<Map<String, dynamic>> manualPicks = const [],
    Map<String, String> partNotes = const {},
  }) async {
    if (sessions.isEmpty) {
      throw Exception('No sessions provided for batch export.');
    }

    final unitId = sessions.first.unitId;
    return exportMultiUnitBatchSuperSession(
      unitOriginalFiles: {unitId: originalFilePath},
      unitItems: {unitId: items},
      unitNames: {unitId: unitName},
      sessions: sessions,
      unitReturnComments: {unitId: returnComments},
      outputPath: outputPath,
      unitAutoIssueResourceIds: {unitId: autoIssueResourceIds},
      issuedStatus: issuedStatus,
      unitRemoveComments: {unitId: removeComments},
      unitManualPicks: {unitId: manualPicks},
      unitPartNotes: {unitId: partNotes},
    );
  }
}
