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

    // Create a new Excel workbook containing ONLY picked or auto-issued rows
    final outExcel = Excel.createExcel();
    final defaultSheet = outExcel.getDefaultSheet();
    final outSheet = outExcel[targetSheetName];
    if (defaultSheet != null && defaultSheet != targetSheetName) {
      outExcel.delete(defaultSheet);
    }

    // Write row 0 headers (original columns + service columns)
    for (int col = 0; col < headerRow.length; col++) {
      final v = headerRow[col]?.value;
      if (v != null) {
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0)).value = v;
      }
    }
    for (final entry in serviceColIndices.entries) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: entry.value, rowIndex: 0)).value =
          TextCellValue(entry.key);
    }
    if (colPicked != null) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colPicked, rowIndex: 0)).value =
          TextCellValue('Qty Picked');
    }
    if (colDue != null) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colDue, rowIndex: 0)).value =
          TextCellValue('Qty Due');
    }

    int outRowIdx = 1;
    // Export data rows — ONLY those with qtyPicked > 0 or belonging to Auto-Issue resource IDs
    for (int rowIdx = 1; rowIdx < sheet.rows.length; rowIdx++) {
      final item = itemByRowOrder[rowIdx];
      if (item == null) continue;

      final isItemResEmpty = item.resourceId.trim().isEmpty;
      final isAutoResource = isItemResEmpty
          ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
          : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.resourceId.trim().toLowerCase());

      final shouldExport = item.qtyPicked > 0.0001 || isAutoResource;
      if (!shouldExport) {
        continue; // Skip unpicked and non-auto-issued rows!
      }

      // Copy original cells from this row
      final origRow = sheet.rows[rowIdx];
      for (int c = 0; c < origRow.length; c++) {
        final cellVal = origRow[c]?.value;
        if (cellVal != null) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: outRowIdx)).value = cellVal;
        }
      }

      final woKey = '${item.department}___${item.workOrder}';
      final woStatus = woStatusMap[woKey] ?? 'Not Picked';
      final woProgress = woProgressMap[woKey] ?? '0.0%';

      CellValue qtyToCell(double val) {
        if (val % 1 == 0) return IntCellValue(val.toInt());
        return DoubleCellValue(val);
      }

      final pickedVal = isAutoResource ? item.qtyRequired : item.qtyPicked;
      final dueVal = isAutoResource ? 0.0 : item.qtyDue;

      // Update Qty Picked
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colPicked, rowIndex: outRowIdx)).value =
          qtyToCell(pickedVal);

      // Update Qty Due
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colDue, rowIndex: outRowIdx)).value =
          qtyToCell(dueVal);

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

      // Return Comments: join all return comments for this part ID with " | " separator
      if (serviceColIndices.containsKey('Return Comments')) {
        final comments = returnComments[item.partId] ?? [];
        final commentsStr = comments.join(' | ');
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Return Comments']!, rowIndex: outRowIdx)).value =
            commentsStr.isNotEmpty ? TextCellValue(commentsStr) : TextCellValue('');
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

  /// Exports a consolidated Super Export Excel file combining multiple unexported sessions across one or more units.
  /// Writes all picked items from all participating units, with consolidated audit columns:
  /// - Session ID: list of session sequence numbers (e.g. "Batch: #1, #2, #3")
  /// - Worker Name: comma-separated distinct worker names (e.g. "Alex, John")
  /// - Start Time: earliest session start time
  /// - End Time: latest session end time
  /// - Issued Status: ERP status (e.g. "Pending Issue" or custom)
  Future<String> exportMultiUnitBatchSuperSession({
    required Map<String, String> unitOriginalFiles, // unitId -> filePath
    required Map<String, List<PicklistItem>> unitItems, // unitId -> items
    required Map<String, String> unitNames, // unitId -> unitName
    required List<SessionMetadata> sessions,
    required Map<String, Map<String, List<String>>> unitReturnComments, // unitId -> partId -> comments
    required String outputPath,
    Map<String, List<String>> unitAutoIssueResourceIds = const {},
    Map<String, Set<String>> unitBatchPickedPartIds = const {}, // unitId -> set of picked partIds in this batch
    String issuedStatus = 'Pending Issue',
  }) async {
    if (sessions.isEmpty || unitOriginalFiles.isEmpty) {
      throw Exception('No sessions or units provided for multi-unit batch export.');
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

    // 1. Read first available unit file as reference structure
    final firstUnitId = unitOriginalFiles.keys.first;
    final firstFilePath = unitOriginalFiles[firstUnitId]!;
    final firstFile = File(firstFilePath);
    if (!await firstFile.exists()) {
      throw Exception('Source file not found: $firstFilePath');
    }

    final firstBytes = await firstFile.readAsBytes();
    final firstExcel = Excel.decodeBytes(firstBytes);
    String targetSheetName = firstExcel.tables.keys.first;
    for (final name in firstExcel.tables.keys) {
      if (firstExcel.tables[name]?.rows.isNotEmpty ?? false) {
        targetSheetName = name;
        break;
      }
    }

    final firstSheet = firstExcel.tables[targetSheetName]!;
    final firstHeaderRow = firstSheet.rows.first;

    final headerNames = <String>[];
    int? origColPicked;
    int? origColDue;
    int? origColUnit;

    for (int col = 0; col < firstHeaderRow.length; col++) {
      final val = firstHeaderRow[col]?.value?.toString() ?? '';
      headerNames.add(val);
      final key = columnMapper.identifyColumn(val);
      if (key == ColumnMapper.keyQtyPicked) origColPicked = col;
      if (key == ColumnMapper.keyQtyDue) origColDue = col;
      if (key == ColumnMapper.keyUnit) origColUnit = col;
    }

    // Next available column index after 'File Name' (col 0) and all original headers (cols 1..length)
    int nextCol = firstHeaderRow.length + 1;
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
      for (int c = 0; c < firstHeaderRow.length; c++) {
        if (firstHeaderRow[c]?.value?.toString().trim().toLowerCase() == sHeader.toLowerCase()) {
          serviceColIndices[sHeader] = c + 1;
          found = true;
          break;
        }
      }
      if (!found) {
        serviceColIndices[sHeader] = nextCol;
        nextCol++;
      }
    }

    final int colPicked = origColPicked != null ? (origColPicked + 1) : nextCol++;
    final int colDue = origColDue != null ? (origColDue + 1) : nextCol++;
    final int colUnit = origColUnit != null ? (origColUnit + 1) : nextCol++;

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

    for (int col = 0; col < firstHeaderRow.length; col++) {
      final v = firstHeaderRow[col]?.value;
      if (v != null) {
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: col + 1, rowIndex: 0)).value = v;
      }
    }
    for (final entry in serviceColIndices.entries) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: entry.value, rowIndex: 0)).value =
          TextCellValue(entry.key);
    }
    if (origColPicked == null) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colPicked, rowIndex: 0)).value =
          TextCellValue('Qty Picked');
    }
    if (origColDue == null) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colDue, rowIndex: 0)).value =
          TextCellValue('Qty Due');
    }
    if (origColUnit == null) {
      outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colUnit, rowIndex: 0)).value =
          TextCellValue('Unit');
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
      final autoIssueResourceIds = unitAutoIssueResourceIds[unitId] ?? [];

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

      // Map unitSheet column indices to outSheet column indices
      final unitHeaderRow = unitSheet.rows.first;
      final colMapping = <int, int>{};
      for (int uCol = 0; uCol < unitHeaderRow.length; uCol++) {
        final uHeader = unitHeaderRow[uCol]?.value?.toString().trim().toLowerCase() ?? '';
        int? matchedOutCol;
        for (int oCol = 0; oCol < headerNames.length; oCol++) {
          if (headerNames[oCol].trim().toLowerCase() == uHeader) {
            matchedOutCol = oCol + 1; // Shifted by 1 because col 0 is File Name
            break;
          }
        }
        colMapping[uCol] = matchedOutCol ?? (uCol + 1);
      }

      final sourceFileName = p.basename(filePath);

      for (int rowIdx = 1; rowIdx < unitSheet.rows.length; rowIdx++) {
        final item = itemByRowOrder[rowIdx];
        if (item == null) continue;

        final isItemResEmpty = item.resourceId.trim().isEmpty;
        final isAutoResource = isItemResEmpty
            ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
            : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.resourceId.trim().toLowerCase());

        final batchPartIds = unitBatchPickedPartIds[unitId] ?? <String>{};
        final wasPickedInBatch = unitBatchPickedPartIds.containsKey(unitId)
            ? batchPartIds.contains(item.partId)
            : item.qtyPicked > 0.0001;

        final shouldExport = wasPickedInBatch || isAutoResource;
        if (!shouldExport) continue;

        // Write source File Name in Column 0
        outSheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: outRowIdx)).value =
            TextCellValue(sourceFileName);

        final origRow = unitSheet.rows[rowIdx];
        for (int c = 0; c < origRow.length; c++) {
          final targetCol = colMapping[c];
          final cellVal = origRow[c]?.value;
          if (targetCol != null && cellVal != null) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value = cellVal;
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
        if (serviceColIndices.containsKey('Return Comments')) {
          final comments = returnComments[item.partId] ?? [];
          final commentsStr = comments.join(' | ');
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: serviceColIndices['Return Comments']!, rowIndex: outRowIdx)).value =
              commentsStr.isNotEmpty ? TextCellValue(commentsStr) : TextCellValue('');
        }
        if (colUnit != null) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: colUnit, rowIndex: outRowIdx)).value =
              TextCellValue(item.subUnit.isNotEmpty ? item.subUnit : unitName);
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
    );
  }
}
