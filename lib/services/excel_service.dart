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
      'Return Comments',
    ];

    final serviceColIndices = <String, int>{};
    for (final sHeader in serviceHeaders) {
      final existingCol = headerToCol[sHeader.toLowerCase()];
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
    // Export data rows — ONLY those with qtyPicked > 0 or belonging to Auto-Issue resource IDs
    for (int rowIdx = 1; rowIdx < sheet.rows.length; rowIdx++) {
      final item = itemByRowOrder[rowIdx];
      if (item == null) continue;

      final isComponentResEmpty = item.componentResourceId.trim().isEmpty;
      final isAutoResource = isComponentResEmpty
          ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
          : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.componentResourceId.trim().toLowerCase());

      final shouldExport = item.qtyPicked > 0.0001 || isAutoResource;
      if (!shouldExport) {
        continue; // Skip unpicked and non-auto-issued rows!
      }

      // Copy original cells from this row according to header mapping
      final origRow = sheet.rows[rowIdx];
      for (int c = 0; c < origRow.length && c < origHeaders.length; c++) {
        final cellVal = origRow[c]?.value;
        final targetCol = headerToCol[origHeaders[c].toLowerCase()];
        if (targetCol != null && cellVal != null) {
          outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value = cellVal;
        }
      }

      // Also copy any raw columns from item.rawColumns if not already set
      for (final e in item.rawColumns.entries) {
        final targetCol = headerToCol[e.key.toLowerCase()];
        if (targetCol != null) {
          final cell = outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx));
          if (cell.value == null) {
            cell.value = TextCellValue(e.value.toString());
          }
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
      'Return Comments',
    ];

    final serviceColIndices = <String, int>{};
    for (final sHeader in serviceHeaders) {
      final existingCol = headerToOutCol[sHeader.toLowerCase()];
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

      final unitHeaderRow = unitSheet.rows.first;
      final sourceFileName = p.basename(filePath);

      for (int rowIdx = 1; rowIdx < unitSheet.rows.length; rowIdx++) {
        final item = itemByRowOrder[rowIdx];
        if (item == null) continue;

        final isComponentResEmpty = item.componentResourceId.trim().isEmpty;
        final isAutoResource = isComponentResEmpty
            ? autoIssueResourceIds.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
            : autoIssueResourceIds.any((r) => r.trim().toLowerCase() == item.componentResourceId.trim().toLowerCase());

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
        for (int c = 0; c < origRow.length && c < unitHeaderRow.length; c++) {
          final uHeader = unitHeaderRow[c]?.value?.toString().trim().toLowerCase() ?? '';
          final targetCol = headerToOutCol[uHeader];
          final cellVal = origRow[c]?.value;
          if (targetCol != null && cellVal != null) {
            outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx)).value = cellVal;
          }
        }

        // Also copy any raw columns from item.rawColumns if not already set
        for (final e in item.rawColumns.entries) {
          final targetCol = headerToOutCol[e.key.toLowerCase()];
          if (targetCol != null) {
            final cell = outSheet.cell(CellIndex.indexByColumnRow(columnIndex: targetCol, rowIndex: outRowIdx));
            if (cell.value == null) {
              cell.value = TextCellValue(e.value.toString());
            }
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
