import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../engine/column_mapper.dart';
import '../../engine/fifo_allocation_engine.dart';
import '../../engine/grouping_engine.dart';
import '../../models/grouping_preset.dart';
import '../../models/part_summary.dart';
import '../../models/picklist_item.dart';
import '../../models/session_metadata.dart';
import '../../models/unit_pick_date_urgency.dart';
import '../../models/unit_record.dart';
import '../../services/database_service.dart';
import '../../services/excel_service.dart';
import '../../services/log_service.dart';
import '../../services/storage_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/grouping_tree_view.dart';
import '../widgets/tablet_header.dart';
import 'pick_mode_screen.dart';

/// PickingScreen: Main picking list view (and full-screen pick mode).
///
/// Rules:
/// - Exit to Menu requires admin PIN (session stays ACTIVE).
/// - Sessions auto-close after 13 hours.
/// - On close session: auto-exports if export dir is configured and session has picks.
/// - Tapping a part in List view navigates to the unified PickModeScreen at that part index.
/// - Mode label: "List" (not "Accordion").
class PickingScreen extends StatefulWidget {
  final DatabaseService dbService;
  final StorageManager storageManager;
  final ExcelService excelService;
  final ColumnMapper columnMapper;

  final UnitRecord? initialUnit;
  final SessionMetadata? initialSession;
  final String? initialDepartment;

  const PickingScreen({
    super.key,
    required this.dbService,
    required this.storageManager,
    required this.excelService,
    required this.columnMapper,
    this.initialUnit,
    this.initialSession,
    this.initialDepartment,
  });

  @override
  State<PickingScreen> createState() => _PickingScreenState();
}

class _PickingScreenState extends State<PickingScreen> with WidgetsBindingObserver {
  UnitRecord? _activeUnit;
  SessionMetadata? _activeSession;
  List<PicklistItem> _items = [];
  Map<String, bool> _departmentsMap = {};
  late List<GroupingPreset> _presets;
  late GroupingPreset _selectedPreset;

  String? _activeDepartment;
  String _tabletId = '';
  Map<String, Map<String, dynamic>> _partFlags = {};

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _presets = GroupingPreset.defaultPresets;
    _activeDepartment = widget.initialDepartment;
    _selectedPreset = GroupingEngine.getPresetForDepartment(_activeDepartment ?? '', customPresets: _presets);

    if (widget.initialUnit != null) {
      _activeSession = widget.initialSession;
      _loadUnitData(widget.initialUnit!);
    } else {
      _restoreLastActiveUnit();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushActiveSessionState();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _flushActiveSessionState();
    }
  }

  Future<void> _flushActiveSessionState() async {
    if (_activeSession == null || _activeUnit == null) return;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final pickedPartsCount = _items.where((i) => i.qtyPicked > 0).length;
      await widget.dbService.updateSessionProgress(
        _activeSession!.id,
        pickedPartsCount,
        endTime: nowMs,
      );
      _activeSession = _activeSession!.copyWith(
        totalItemsPicked: pickedPartsCount,
        endTime: nowMs,
      );
    } catch (_) {}
  }

  Future<void> _restoreLastActiveUnit() async {
    setState(() => _isLoading = true);
    final allUnits = await widget.dbService.getAllUnits();
    if (allUnits.isNotEmpty) {
      final latestUnit = allUnits.first;
      await _loadUnitData(latestUnit);
    }
    setState(() => _isLoading = false);
  }

  Future<void> _loadUnitData(UnitRecord unit) async {
    setState(() => _isLoading = true);

    // Auto-close expired sessions (>13 hours) before loading
    await widget.dbService.autoCloseExpiredSessions();

    final items = await widget.dbService.getPicklistItems(unit.id);
    final depts = await widget.dbService.getDepartmentsForUnit(unit.id);

    SessionMetadata? session = _activeSession;
    if (session == null) {
      session = await widget.dbService.getActiveSession(unit.id);
    }

    final includeLine = await widget.dbService.shouldGroupByLineForDept(_activeDepartment ?? '');
    final autoPreset = GroupingEngine.getPresetForDepartment(
      _activeDepartment ?? '',
      customPresets: _presets,
      includeLine: includeLine,
    );

    final tabletId = await widget.dbService.getConfig('tablet_id') ?? '';

    // Load part flags for this unit
    final flagList = await widget.dbService.getPartFlags(unit.id);
    final flagMap = <String, Map<String, dynamic>>{};
    for (final f in flagList) {
      final pid = f['part_id']?.toString() ?? '';
      if (pid.isNotEmpty && !flagMap.containsKey(pid)) {
        flagMap[pid] = f;
      }
    }

    final blockedRes = await widget.dbService.getBlockedResourceIds();
    final isBlockedEmpty = blockedRes.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)');
    final blockedSet = blockedRes
        .map((r) => r.trim().toLowerCase())
        .where((s) => s.isNotEmpty && s != '(empty / unassigned)')
        .toSet();

    final autoIssueRes = await widget.dbService.getAutoIssueResourceIds();
    final isAutoEmpty = autoIssueRes.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)');
    final autoIssueResSet = autoIssueRes
        .map((r) => r.trim().toLowerCase())
        .where((s) => s.isNotEmpty && s != '(empty / unassigned)')
        .toSet();

    final visibleItems = items.where((i) {
      final r = i.resourceId.trim().toLowerCase();
      final isEmpty = r.isEmpty;
      if (isEmpty) {
        if (isBlockedEmpty || isAutoEmpty) return false;
      } else {
        if (blockedSet.contains(r) || autoIssueResSet.contains(r)) return false;
      }
      return true;
    }).toList();

    setState(() {
      _activeUnit = unit;
      _items = visibleItems;
      _departmentsMap = depts;
      _activeSession = session;
      _selectedPreset = autoPreset;
      _tabletId = tabletId;
      _partFlags = flagMap;
      _isLoading = false;
    });
  }

  Future<void> _handlePartQuantityChange(String department, String partId, double newPickedTotal) async {
    if (_activeUnit == null) return;

    final updatedList = FifoAllocationEngine.allocateByPartId(
      allItems: _items,
      department: department,
      partId: partId,
      totalPickedToAllocate: newPickedTotal,
    );

    final newTotalPicked = updatedList.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final updatedUnit = _activeUnit!.copyWith(
      totalPicked: newTotalPicked,
      status: newTotalPicked >= _activeUnit!.totalRequired && _activeUnit!.totalRequired > 0
          ? 'COMPLETED'
          : 'IN_PROGRESS',
      completedAt: newTotalPicked >= _activeUnit!.totalRequired && _activeUnit!.totalRequired > 0
          ? nowMs
          : null,
      lastAccessedAt: nowMs,
    );

    setState(() {
      _items = updatedList;
      _activeUnit = updatedUnit;
    });

    await widget.dbService.batchUpdateItems(updatedList);
    await widget.dbService.updateUnit(updatedUnit);

    final itemsForPart = updatedList.where((i) => i.partId == partId);
    final totalDue = itemsForPart.fold<double>(0.0, (s, i) => s + i.qtyDue);
    if (totalDue <= 0.0001) {
      await widget.dbService.clearPartFlag(unitId: _activeUnit!.id, partId: partId);
      setState(() => _partFlags.remove(partId));
    }
    LogService.picker('PICK: $partId (Allocated: $newPickedTotal) → Unit: ${_activeUnit?.name}, Dept: $department');

    if (_activeSession != null) {
      final pickedCount = updatedList.where((i) => i.qtyPicked > 0).length;
      await widget.dbService.updateSessionProgress(
        _activeSession!.id,
        pickedCount,
        endTime: nowMs,
      );
      _activeSession = _activeSession!.copyWith(
        totalItemsPicked: pickedCount,
        endTime: nowMs,
      );
    }
  }

  Future<void> _handleSingleItemOverride(PicklistItem item, double newPickedQty) async {
    if (_activeUnit == null) return;

    final updated = FifoAllocationEngine.updateSingleItem(item, newPickedQty);
    final idx = _items.indexWhere((i) => i.id == item.id);
    if (idx == -1) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _items[idx] = updated;
    final newTotalPicked = _items.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();
    final updatedUnit = _activeUnit!.copyWith(
      totalPicked: newTotalPicked,
      lastAccessedAt: nowMs,
    );

    setState(() {
      _activeUnit = updatedUnit;
    });

    await widget.dbService.updateItemQtyPicked(item.id, updated.qtyPicked, updated.qtyDue);
    await widget.dbService.updateUnit(updatedUnit);

    if (updated.qtyDue <= 0.0001) {
      await widget.dbService.clearPartFlag(unitId: _activeUnit!.id, partId: updated.partId);
      setState(() => _partFlags.remove(updated.partId));
    }
    LogService.picker('PICK: ${updated.partId} (Override: $newPickedQty) → Unit: ${_activeUnit?.name}, Line: ${updated.line}');

    if (_activeSession != null) {
      final pickedCount = _items.where((i) => i.qtyPicked > 0).length;
      await widget.dbService.updateSessionProgress(
        _activeSession!.id,
        pickedCount,
        endTime: nowMs,
      );
      _activeSession = _activeSession!.copyWith(
        totalItemsPicked: pickedCount,
        endTime: nowMs,
      );
    }
  }

  /// Build the sorted part summaries for the active department (optionally filtered to a line).
  /// [pendingOnly]: when true (for Pick Mode), excludes fully picked parts while keeping pending and missing parts.
  List<PartSummary> _buildPartSummaries({String? lineFilter, bool pendingOnly = false}) {
    final partsMap = <String, PartSummary>{};
    for (final item in _items) {
      if (_activeDepartment != null && item.department != _activeDepartment) continue;
      if (lineFilter != null && item.line != lineFilter) continue;
      if (partsMap.containsKey(item.partId)) {
        partsMap[item.partId] = partsMap[item.partId]!.add(item);
      } else {
        partsMap[item.partId] = PartSummary.fromItem(item);
      }
    }
    var list = partsMap.values.toList();
    if (pendingOnly) {
      // In Pick Mode, do not show fully picked parts!
      // Only show pending parts (qtyPicked < qtyRequired) or parts flagged as MISSING.
      list = list.where((p) {
        final isMissing = _partFlags[p.partId]?['flag_type']?.toString().toUpperCase() == 'MISSING';
        final isPending = p.qtyPicked < p.qtyRequired - 0.0001;
        return isPending || isMissing;
      }).toList();
    }
    return list
      ..sort((a, b) {
        final aDone = a.qtyPicked >= a.qtyRequired;
        final bDone = b.qtyPicked >= b.qtyRequired;
        if (aDone != bDone) return aDone ? 1 : -1;
        return a.minRowOrder.compareTo(b.minRowOrder);
      });
  }

  /// Navigate to PickModeScreen starting at the part index corresponding to [partId].
  void _openPickModeAtPart(String partId) {
    final matchingItem = _items.firstWhere(
      (i) => i.partId == partId && (_activeDepartment == null || i.department == _activeDepartment),
      orElse: () => _items.firstWhere(
        (i) => i.partId == partId,
        orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0),
      ),
    );
    final hasLineGrouping = _selectedPreset.levels.contains(GroupLevel.line);
    final lineLabel = (hasLineGrouping && matchingItem.line.isNotEmpty) ? matchingItem.line : null;

    final parts = _buildPartSummaries(lineFilter: lineLabel, pendingOnly: false);
    final deptItems = _items
        .where((i) => (_activeDepartment == null || i.department == _activeDepartment) &&
                      (lineLabel == null || i.line == lineLabel))
        .toList()
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));
    var startIndex = parts.indexWhere((p) => p.partId == partId);
    if (startIndex < 0) startIndex = 0;
    _navigateToPickMode(parts, deptItems, startIndex: startIndex, lineLabel: lineLabel);
  }

  /// Strictly scoped Pick Mode entry: restricts picking ONLY to the items in [node].
  /// Does not allow navigation across different Resource IDs, Lines, or Departments.
  void _openPickModeForNode(TreeNode node, {String? targetPartId}) {
    final groupItems = List<PicklistItem>.from(node.leafItems)
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));

    if (groupItems.isEmpty) return;

    final partsMap = <String, PartSummary>{};
    for (final item in groupItems) {
      if (partsMap.containsKey(item.partId)) {
        partsMap[item.partId] = partsMap[item.partId]!.add(item);
      } else {
        partsMap[item.partId] = PartSummary.fromItem(item);
      }
    }

    var list = partsMap.values.toList();
    if (targetPartId == null) {
      // Pick Mode button tapped -> only pending and missing parts
      list = list.where((p) {
        final isMissing = _partFlags[p.partId]?['flag_type']?.toString().toUpperCase() == 'MISSING';
        final isPending = p.qtyPicked < p.qtyRequired - 0.0001;
        return isPending || isMissing;
      }).toList();
    }

    list.sort((a, b) {
      final aDone = a.qtyPicked >= a.qtyRequired;
      final bDone = b.qtyPicked >= b.qtyRequired;
      if (aDone != bDone) return aDone ? 1 : -1;
      return a.minRowOrder.compareTo(b.minRowOrder);
    });

    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('All parts in ${node.label} are already picked!'),
          backgroundColor: AppTheme.statusComplete,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    int startIndex = 0;
    if (targetPartId != null) {
      startIndex = list.indexWhere((p) => p.partId == targetPartId);
      if (startIndex < 0) startIndex = 0;
    }

    final groupLabel = '${node.level.displayName}: ${node.label}';
    _navigateToPickMode(
      list,
      groupItems,
      startIndex: startIndex,
      lineLabel: groupLabel,
    );
  }

  /// Navigate to PickModeScreen starting at the first part of [lineLabel].
  void _openPickModeAtLine(String? lineLabel) {
    final parts = _buildPartSummaries(lineFilter: lineLabel, pendingOnly: true);
    final deptItems = _items
        .where((i) => ((_activeDepartment == null || i.department == _activeDepartment) &&
                       (lineLabel == null || i.line == lineLabel)))
        .toList()
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));
    _navigateToPickMode(parts, deptItems, startIndex: 0, lineLabel: lineLabel);
  }

  void _navigateToPickMode(
    List<PartSummary> parts,
    List<PicklistItem> deptItems, {
    int startIndex = 0,
    String? lineLabel,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PickModeScreen(
          unit: _activeUnit!,
          department: _activeDepartment ?? 'All Departments',
          lineLabel: lineLabel,
          partSummaries: parts,
          allDeptItems: deptItems,
          startIndex: startIndex,
          dbService: widget.dbService,
          activeSession: _activeSession,
          tabletId: _tabletId,
          onItemsUpdated: (updatedItems) async {
            if (mounted) {
              final freshFlags = await widget.dbService.getPartFlags(_activeUnit!.id);
              final freshMap = <String, Map<String, dynamic>>{};
              for (final f in freshFlags) {
                final pid = f['part_id']?.toString() ?? '';
                if (pid.isNotEmpty && !freshMap.containsKey(pid)) {
                  freshMap[pid] = f;
                }
              }
              setState(() {
                for (final updated in updatedItems) {
                  final idx = _items.indexWhere((i) => i.id == updated.id);
                  if (idx >= 0) _items[idx] = updated;
                }
                _partFlags = freshMap;
              });
            }
          },
        ),
      ),
    );
  }

  /// Calmly return back to PickerFlowScreen (Department / Unit selection) without requiring a PIN.
  Future<void> _handleBack() async {
    if (!mounted) return;
    LogService.picker('${_activeSession?.workerName ?? "Worker"} returned from picking to department selection');
    Navigator.of(context).pop();
  }

  /// Close Session: marks CLOSED, auto-exports immediately (prompting for export folder if first time).
  Future<void> _handleCloseSession() async {
    if (_activeSession == null || _activeUnit == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.borderDark),
        ),
        title: const Row(
          children: [
            Icon(Icons.lock_clock_rounded, color: Color(0xFFE07B00), size: 24),
            SizedBox(width: 10),
            Text('Close & Export Session?', style: TextStyle(color: AppTheme.textLight)),
          ],
        ),
        content: Text(
          'This will close the current session for ${_activeSession!.workerName} and automatically export the file to Excel. '
          'Status will update to EXPORTED.',
          style: const TextStyle(color: AppTheme.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE07B00)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close & Export'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final totalPicked = _activeUnit!.totalPicked;

    await widget.dbService.closeSession(_activeSession!.id, now, totalPicked);
    LogService.picker('Session "${_activeSession!.id}" closed by "${_activeSession!.workerName}" on unit "${_activeUnit!.name}" with $totalPicked items picked');

    // Auto-export: check export directory or prompt user on first export
    String? exportDir = await widget.dbService.getLastExportDir();
    if ((exportDir == null || exportDir.isEmpty) && mounted) {
      // First-time export prompt: ask picker/admin to choose destination directory
      final pickFolder = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          title: const Row(
            children: [
              Icon(Icons.folder_open_rounded, color: AppTheme.accentCyan),
              SizedBox(width: 10),
              Text('Select Export Folder', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
            ],
          ),
          content: const Text(
            'Export directory is not configured yet. Please select the folder where picklist files will be saved.',
            style: TextStyle(color: AppTheme.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Skip Export for Now'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryBlue),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Choose Folder'),
            ),
          ],
        ),
      );

      if (pickFolder == true) {
        final selected = await FilePicker.getDirectoryPath();
        if (selected != null && selected.isNotEmpty) {
          await widget.dbService.setLastExportDir(selected);
          exportDir = selected;
        }
      }
    }

    if (exportDir != null && exportDir.isNotEmpty && _activeUnit?.filePath != null) {
      try {
        final returnComments = await widget.dbService.getReturnCommentsForUnit(_activeUnit!.id);
        final closedSession = _activeSession!.copyWith(
          status: 'EXPORTED',
          endTime: now,
          totalItemsPicked: totalPicked,
        );

        final outputPath = p.join(
          exportDir,
          closedSession.buildExportFileName(_activeUnit!.name, customEndTime: now),
        );

        final finalPath = await widget.excelService.exportAndOverwrite(
          originalFilePath: _activeUnit!.filePath,
          items: _items,
          session: closedSession,
          unitName: _activeUnit!.name,
          returnComments: returnComments,
          outputPath: outputPath,
        );

        await widget.dbService.finishSession(
          _activeSession!.id,
          now,
          totalPicked,
          'Exported',
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Session EXPORTED successfully! Saved to: $finalPath'),
              backgroundColor: AppTheme.statusComplete,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Auto-export failed: $e. Session saved as CLOSED.'),
              backgroundColor: AppTheme.statusDanger,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session saved as CLOSED. You can export later from the Export Hub.'),
            backgroundColor: Color(0xFFE07B00),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }

    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_activeUnit == null) {
      return Scaffold(
        body: _buildEmptyState(),
      );
    }

    // List Mode (formerly "Accordion")
    Set<String> activeDepts;
    if (_activeDepartment != null) {
      activeDepts = {_activeDepartment!};
    } else {
      activeDepts = _departmentsMap.entries
          .where((e) => e.value == true)
          .map((e) => e.key)
          .toSet();
    }

    final treeNodes = GroupingEngine.buildTree(
      items: _items,
      preset: _selectedPreset,
      activeDepartments: activeDepts.isNotEmpty ? activeDepts : null,
      componentMapping: const {},
    );

    // Unit-wide unique Part ID progress
    final allPartIds = _items.map((i) => i.partId).toSet();
    final unitTotalParts = allPartIds.length;
    final unitCompletedParts = allPartIds.where((pid) {
      final itemsForPart = _items.where((i) => i.partId == pid);
      final totalDue = itemsForPart.fold<double>(0.0, (s, i) => s + i.qtyDue);
      return totalDue <= 0.0001;
    }).length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TabletHeader(
              activeUnit: _activeUnit,
              activeSession: _activeSession,
              tabletId: _tabletId,
              totalParts: unitTotalParts,
              completedParts: unitCompletedParts,
              onBack: _handleBack,
              onCloseSession: _handleCloseSession,
            ),
            if (_activeDepartment != null)
              Builder(
                builder: (context) {
                  final deptItems = _items.where((i) => i.department == _activeDepartment).toList();
                  final deptPartIds = deptItems.map((i) => i.partId).toSet();
                  final deptTotalParts = deptPartIds.length;
                  final deptCompletedParts = deptPartIds.where((pid) {
                    final itemsForPart = deptItems.where((i) => i.partId == pid);
                    final totalDue = itemsForPart.fold<double>(0.0, (s, i) => s + i.qtyDue);
                    return totalDue <= 0.0001;
                  }).length;
                  final deptPct = deptTotalParts > 0
                      ? (deptCompletedParts / deptTotalParts * 100).toStringAsFixed(1)
                      : '0.0';

                  // Detect dept_type from items (prefer explicit, fallback to name-based)
                  final deptTypeFromItems = deptItems.isNotEmpty
                      ? deptItems.first.deptType
                      : '';
                  final autoType = deptTypeFromItems.isNotEmpty
                      ? deptTypeFromItems
                      : ((_activeDepartment?.toUpperCase().contains('MAIN') ?? false) ||
                              (_activeDepartment?.toUpperCase().contains('MACG') ?? false)
                          ? 'MAIN LINE'
                          : 'SUBASSEMBLY');

                  final pickDateRaw = deptItems.firstWhere(
                    (i) => i.pickDate.isNotEmpty,
                    orElse: () => _items.firstWhere(
                      (i) => i.pickDate.isNotEmpty,
                      orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0),
                    ),
                  ).pickDate;
                  final prodDateRaw = deptItems.firstWhere(
                    (i) => i.prodDate.isNotEmpty,
                    orElse: () => _items.firstWhere(
                      (i) => i.prodDate.isNotEmpty,
                      orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0),
                    ),
                  ).prodDate;

                  final pickDate = UnitPickDateUrgency.formatShortDate(pickDateRaw);
                  final prodDate = UnitPickDateUrgency.formatShortDate(prodDateRaw);

                  // Dept strip: wrapped in scrollable row to prevent overflow
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const Icon(Icons.apartment_rounded, size: 16, color: AppTheme.accentCyan),
                          const SizedBox(width: 8),
                          // Dept type badge (MAIN LINE / SUBASSEMBLY)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: autoType == 'MAIN LINE'
                                  ? const Color(0xFF0EA5E9).withOpacity(0.15)
                                  : const Color(0xFFF97316).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: autoType == 'MAIN LINE'
                                    ? const Color(0xFF0EA5E9).withOpacity(0.5)
                                    : const Color(0xFFF97316).withOpacity(0.5),
                              ),
                            ),
                            child: Text(
                              autoType.isNotEmpty ? autoType : 'DEPT',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: autoType == 'MAIN LINE'
                                    ? const Color(0xFF0EA5E9)
                                    : const Color(0xFFF97316),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Department: $_activeDepartment',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.accentCyan,
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Department Part-ID Progress Badge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppTheme.cardDark,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: deptCompletedParts >= deptTotalParts && deptTotalParts > 0
                                    ? AppTheme.statusComplete
                                    : AppTheme.borderDark,
                              ),
                            ),
                            child: Text(
                              '$deptCompletedParts / $deptTotalParts parts ($deptPct%)',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: deptCompletedParts >= deptTotalParts && deptTotalParts > 0
                                    ? AppTheme.statusComplete
                                    : AppTheme.accentCyan,
                              ),
                            ),
                          ),
                          if (pickDate.isNotEmpty) ...[
                            const SizedBox(width: 16),
                            const Icon(Icons.event_available_rounded, size: 15, color: AppTheme.statusPartial),
                            const SizedBox(width: 5),
                            Text(
                              'Pick: $pickDate',
                              style: const TextStyle(fontSize: 11, color: AppTheme.textLight, fontWeight: FontWeight.w500),
                            ),
                          ],
                          if (prodDate.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            const Icon(Icons.precision_manufacturing_rounded, size: 15, color: AppTheme.textMuted),
                            const SizedBox(width: 5),
                            Text(
                              'Prod: $prodDate',
                              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            Expanded(
              child: GroupingTreeView(
                nodes: treeNodes,
                onPickQuantityChanged: _handlePartQuantityChange,
                onSingleItemOverride: _handleSingleItemOverride,
                // Tap on leaf part → open PickModeScreen scoped to its parent group node
                onLeafPartTapped: (partId, parentGroupNode) {
                  if (parentGroupNode != null) {
                    _openPickModeForNode(parentGroupNode, targetPartId: partId);
                  } else {
                    _openPickModeAtPart(partId);
                  }
                },
                // Pick Mode button on group nodes (Resource ID, Line, Dept)
                onPickModeFromNode: (node) => _openPickModeForNode(node),
                // (Fallback) Pick Mode button on Line/Department nodes
                onPickModeFromLine: (lineLabel) {
                  if (lineLabel != null) {
                    _openPickModeAtLine(lineLabel);
                  } else {
                    _navigateToPickMode(_buildPartSummaries(pendingOnly: true), _items);
                  }
                },
                partFlags: _partFlags,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: AppTheme.cardDark,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.inventory_2_outlined, size: 64, color: AppTheme.borderDark),
          ),
          const SizedBox(height: 24),
          const Text(
            'No Picklist Loaded',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textLight),
          ),
          const SizedBox(height: 8),
          const Text(
            'Go back to Home to start a new picking session.',
            style: TextStyle(fontSize: 14, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.home_rounded),
            label: const Text('Back to Home'),
            onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        ],
      ),
    );
  }
}
