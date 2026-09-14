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

    for (int col = 0; col < headerRow.length; col++) {
      final cell = headerRow[col];
      final rawValue = cell?.value?.toString() ?? '';
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
    final uuid = const Uuid();

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
      final onHand = getVal(ColumnMapper.keyOnHand, '');
      final deptTypeRaw = getVal(ColumnMapper.keyDeptType, '');
      final deptType = ColumnMapper.parseDeptType(deptTypeRaw);

      // Auto-issue: if department or resourceId is designated for auto-issue OR name contains 'PTF', mark 100% picked
      final isPtfDept = department.toUpperCase().contains('PTF');
      final isAutoResource = resourceId.trim().isNotEmpty &&
          autoIssueResourceIds.any((r) => r.trim().toLowerCase() == resourceId.trim().toLowerCase());
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
        onHand: onHand,
        deptType: deptType,
      ));
    }

    return {
      'unitId': fileUnitId,
      'departments': departments.toList(),
      'items': items,
    };
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

    // Find header column indices
    final headerRow = sheet.rows.first;
    int? colPicked;
    int? colDue;

    for (int col = 0; col < headerRow.length; col++) {
      final val = headerRow[col]?.value?.toString() ?? '';
      final key = columnMapper.identifyColumn(val);
      if (key == ColumnMapper.keyQtyPicked) colPicked = col;
      if (key == ColumnMapper.keyQtyDue) colDue = col;
    }

    // Append service ERP columns to the header if not already present
    int nextCol = headerRow.length;
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
      'Return Comments',
    ];

    final serviceColIndices = <String, int>{};
    for (final sHeader in serviceHeaders) {
      bool found = false;
      for (int c = 0; c < headerRow.length; c++) {
        if (headerRow[c]?.value?.toString().trim().toLowerCase() == sHeader.toLowerCase()) {
          serviceColIndices[sHeader] = c;
          found = true;
          break;
        }
      }
      if (!found) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: nextCol, rowIndex: 0)).value =
            TextCellValue(sHeader);
        serviceColIndices[sHeader] = nextCol;
        nextCol++;
      }
    }

    // If colPicked or colDue did not exist originally, append them as well
    if (colPicked == null) {
      colPicked = nextCol;
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: colPicked, rowIndex: 0)).value =
          TextCellValue('Qty Picked');
      nextCol++;
    }
    if (colDue == null) {
      colDue = nextCol;
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: colDue, rowIndex: 0)).value =
          TextCellValue('Qty Due');
      nextCol++;
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

    // Update data rows
    for (int rowIdx = 1; rowIdx < sheet.rows.length; rowIdx++) {
      final item = itemByRowOrder[rowIdx];
      if (item != null) {
        final woKey = '${item.department}___${item.workOrder}';
        final woStatus = woStatusMap[woKey] ?? 'Not Picked';
        final woProgress = woProgressMap[woKey] ?? '0.0%';

        CellValue qtyToCell(double val) {
          if (val % 1 == 0) return IntCellValue(val.toInt());
          return DoubleCellValue(val);
        }

        final isItemResEmpty = item.resourceId.trim().isEmpty;
        final isAutoResource = isItemResEmpty
            ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
            : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.resourceId.trim().toLowerCase());
        final pickedVal = isAutoResource ? item.qtyRequired : item.qtyPicked;
        final dueVal = isAutoResource ? 0.0 : item.qtyDue;

        // Update Qty Picked
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: colPicked, rowIndex: rowIdx)).value =
            qtyToCell(pickedVal);

        // Update Qty Due
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: colDue, rowIndex: rowIdx)).value =
            qtyToCell(dueVal);

        // Set WO Status & Progress Columns
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['WO Status']!, rowIndex: rowIdx)).value =
            TextCellValue(woStatus);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['WO Progress %']!, rowIndex: rowIdx)).value =
            TextCellValue(woProgress);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Total Picked']!, rowIndex: rowIdx)).value =
            qtyToCell(pickedVal);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Session Picked']!, rowIndex: rowIdx)).value =
            qtyToCell(pickedVal);

        // Set ERP Audit Columns
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Session ID']!, rowIndex: rowIdx)).value =
            TextCellValue(session.id);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Worker Name']!, rowIndex: rowIdx)).value =
            TextCellValue(session.workerName);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Pick Date']!, rowIndex: rowIdx)).value =
            TextCellValue(item.pickDate.isNotEmpty ? item.pickDate : session.pickDate);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Start Time']!, rowIndex: rowIdx)).value =
            TextCellValue(startTimeStr);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['End Time']!, rowIndex: rowIdx)).value =
            TextCellValue(endTimeStr);
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Issued Status']!, rowIndex: rowIdx)).value =
            TextCellValue(session.issuedStatus);

        // Return Comments: join all return comments for this part ID with " | " separator
        if (serviceColIndices.containsKey('Return Comments')) {
          final comments = returnComments[item.partId] ?? [];
          final commentsStr = comments.join(' | ');
          sheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Return Comments']!, rowIndex: rowIdx)).value =
              commentsStr.isNotEmpty ? TextCellValue(commentsStr) : TextCellValue('');
        }
      }
    }

    // 3. Encode and write to the session-named output file (NOT the source file)
    final updatedBytes = excel.encode();
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
}
