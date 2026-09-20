import 'package:flutter/material.dart';

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
  bool _combineDepartments = true;

  bool _groupByLine = true;

  String? _activeDepartment;
  String _tabletId = '';
  Map<String, Map<String, dynamic>> _partFlags = {};
  Map<String, String> _userPartNotes = {};
  List<String> _mainLineResourcePicks = [];

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _presets = GroupingPreset.defaultPresets;
    _activeDepartment = widget.initialDepartment;
    _selectedPreset = GroupingEngine.getPresetForDepartment(
      _activeDepartment ?? '',
      customPresets: _presets,
      includeLine: !_isResourceScope && _groupByLine,
      bypassDepartmentLevel: _isResourceScope && _combineDepartments,
      isResourceScope: _isResourceScope,
    );

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

  /// Ensure session is persisted to SQLite ONLY upon first pick.
  Future<void> _ensureSessionPersisted() async {
    if (_activeSession == null || _activeUnit == null) return;
    if (_activeSession!.sessionSeqNo == 0) {
      final seqNo = await widget.dbService.nextSessionSeqNo(_activeUnit!.id);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final persisted = _activeSession!.copyWith(
        sessionSeqNo: seqNo,
        startTime: nowMs,
      );
      await widget.dbService.saveSession(persisted);
      if (mounted) {
        setState(() {
          _activeSession = persisted;
        });
      } else {
        _activeSession = persisted;
      }
      LogService.picker('Session #$seqNo started upon first pick for ${_activeSession!.workerName} on unit "${_activeUnit!.name}"');
    }
  }

  Future<void> _flushActiveSessionState() async {
    if (_activeSession == null || _activeUnit == null) return;
    if (_activeSession!.sessionSeqNo == 0) return;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sessionPicks = await widget.dbService.getSessionPickedPartCount(_activeSession!.id);
      await widget.dbService.updateSessionProgress(
        _activeSession!.id,
        sessionPicks,
        endTime: nowMs,
      );
      _activeSession = _activeSession!.copyWith(
        totalItemsPicked: sessionPicks,
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
    session ??= await widget.dbService.getActiveSession(unit.id);

    if (_isResourceScope) {
      _groupByLine = false;
      final viewMode = await widget.dbService.getMainLineResourceView(_targetResourceName);
      _combineDepartments = (viewMode != 'split_by_dept');
    } else {
      _groupByLine = await widget.dbService.shouldGroupByLineForDept(_activeDepartment ?? '');
      final defCombine = (await widget.dbService.getConfig('mainline_resource_default_view')) != 'split_by_dept';
      _combineDepartments = defCombine;
    }
    final autoPreset = GroupingEngine.getPresetForDepartment(
      _activeDepartment ?? '',
      customPresets: _presets,
      includeLine: !_isResourceScope && _groupByLine,
      bypassDepartmentLevel: _isResourceScope && _combineDepartments,
      isResourceScope: _isResourceScope,
    );
    _selectedPreset = autoPreset;

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
    final userNotes = await widget.dbService.getUserPartNotesForUnit(unit.id);

    final blockedDepts = await widget.dbService.getBlockedDepartmentSet();
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
      if (i.isManualAdd) return true;
      if (blockedDepts.contains(i.department.trim())) return false;
      final r = i.componentResourceId.trim().toLowerCase();
      final isEmpty = r.isEmpty;
      if (isEmpty) {
        if (isBlockedEmpty || isAutoEmpty) return false;
      } else {
        if (blockedSet.contains(r) || autoIssueResSet.contains(r)) return false;
      }
      return true;
    }).toList();

    final mainLinePicks = await widget.dbService.getMainLineResourcePicks();

    setState(() {
      _activeUnit = unit;
      _items = visibleItems;
      _departmentsMap = depts;
      _activeSession = session;
      _selectedPreset = autoPreset;
      _tabletId = tabletId;
      _partFlags = flagMap;
      _userPartNotes = userNotes;
      _mainLineResourcePicks = mainLinePicks;
      _isLoading = false;
    });
  }

  Future<void> _handlePartQuantityChange(String department, String partId, double newPickedTotal) async {
    if (_activeUnit == null) return;

    final oldItems = _items.where((i) => i.partId == partId).toList();
    final oldPickedSum = oldItems.fold<double>(0.0, (s, i) => s + i.qtyPicked);
    final deltaPicked = newPickedTotal - oldPickedSum;

    if (deltaPicked > 0.0001 && _activeSession != null && _activeSession!.sessionSeqNo == 0) {
      await _ensureSessionPersisted();
    }

    final previousItems = List<PicklistItem>.from(_items);

    final updatedList = FifoAllocationEngine.allocateByPartId(
      allItems: _items,
      department: department,
      partId: partId,
      totalPickedToAllocate: newPickedTotal,
    );

    final newTotalPicked = updatedList.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final allPartIds = updatedList.map((i) => i.partId).toSet();
    final allPartsDone = allPartIds.isNotEmpty && allPartIds.every((pid) {
      final itemsForPart = updatedList.where((i) => i.partId == pid);
      final totalDue = itemsForPart.fold<double>(0.0, (s, i) => s + i.qtyDue);
      return totalDue <= 0.0001;
    });
    final isUnitComplete = allPartsDone || (newTotalPicked >= _activeUnit!.totalRequired && _activeUnit!.totalRequired > 0);

    final updatedUnit = _activeUnit!.copyWith(
      totalPicked: newTotalPicked,
      status: isUnitComplete ? 'FULLY_PICKED' : 'IN_PROGRESS',
      completedAt: isUnitComplete ? nowMs : null,
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
    if (deltaPicked > 0.0001) {
      final flag = _partFlags[partId];
      final flagType = flag?['flag_type']?.toString().toUpperCase() ?? '';
      if (flagType == 'MISSING' || totalDue <= 0.0001) {
        await widget.dbService.clearPartFlag(unitId: _activeUnit!.id, partId: partId, flagType: 'MISSING');
        setState(() => _partFlags.remove(partId));
      }
      if (flagType == 'REMOVED' || updatedList.any((i) => i.partId == partId && i.isRemoved)) {
        await widget.dbService.unmarkPartRemoval(
          unitId: _activeUnit!.id,
          partId: partId,
          department: department,
        );
        setState(() {
          _partFlags.remove(partId);
          for (int i = 0; i < _items.length; i++) {
            if (_items[i].partId == partId) {
              _items[i] = _items[i].copyWith(isRemoved: false);
            }
          }
        });
      }
    } else if (totalDue <= 0.0001) {
      await widget.dbService.clearPartFlag(unitId: _activeUnit!.id, partId: partId);
      setState(() => _partFlags.remove(partId));
    }
    LogService.picker('PICK: $partId (Allocated: $newPickedTotal) → Unit: ${_activeUnit?.name}, Dept: $department');

    if (_activeSession != null) {
      if (deltaPicked > 0.0001) {
        for (final item in updatedList.where((i) => i.partId == partId)) {
          final old = previousItems.firstWhere((o) => o.id == item.id, orElse: () => item);
          final delta = item.qtyPicked - old.qtyPicked;
          if (delta > 0.0001) {
            await widget.dbService.recordSessionPick(
              sessionId: _activeSession!.id,
              unitId: _activeUnit!.id,
              itemId: item.id,
              partId: partId,
              qtyPickedDelta: delta,
            );
          }
        }
      }
      final pickedCount = await widget.dbService.getSessionPickedPartCount(_activeSession!.id);
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

    final oldPicked = item.qtyPicked;
    final delta = newPickedQty - oldPicked;
    if (delta > 0.0001 && _activeSession != null && _activeSession!.sessionSeqNo == 0) {
      await _ensureSessionPersisted();
    }

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

    if (delta > 0.0001) {
      final flag = _partFlags[updated.partId];
      final flagType = flag?['flag_type']?.toString().toUpperCase() ?? '';
      if (flagType == 'MISSING' || updated.qtyDue <= 0.0001) {
        await widget.dbService.clearPartFlag(unitId: _activeUnit!.id, partId: updated.partId, flagType: 'MISSING');
        setState(() => _partFlags.remove(updated.partId));
      }
      if (flagType == 'REMOVED' || updated.isRemoved) {
        await widget.dbService.unmarkPartRemoval(
          unitId: _activeUnit!.id,
          partId: updated.partId,
          department: updated.department,
        );
        setState(() {
          _partFlags.remove(updated.partId);
          _items[idx] = _items[idx].copyWith(isRemoved: false);
        });
      }
    } else if (updated.qtyDue <= 0.0001) {
      await widget.dbService.clearPartFlag(unitId: _activeUnit!.id, partId: updated.partId);
      setState(() => _partFlags.remove(updated.partId));
    }
    LogService.picker('PICK: ${updated.partId} (Override: $newPickedQty) → Unit: ${_activeUnit?.name}, Line: ${updated.line}');

    if (_activeSession != null) {
      if (delta > 0.0001) {
        await widget.dbService.recordSessionPick(
          sessionId: _activeSession!.id,
          unitId: _activeUnit!.id,
          itemId: item.id,
          partId: updated.partId,
          qtyPickedDelta: delta,
        );
      }
      final pickedCount = await widget.dbService.getSessionPickedPartCount(_activeSession!.id);
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

  bool get _isResourceScope =>
      _activeDepartment != null &&
      _activeDepartment!.startsWith('Resource: ') &&
      _activeDepartment!.endsWith(' (MAIN LINE)');

  String get _targetResourceName => _isResourceScope
      ? _activeDepartment!
          .substring('Resource: '.length, _activeDepartment!.length - ' (MAIN LINE)'.length)
          .trim()
      : '';

  static DateTime? _toggleUnlockExpiresAt;

  Future<bool> _ensureAdminUnlocked({required String reason}) async {
    final now = DateTime.now();
    final isUnlocked = _toggleUnlockExpiresAt != null && now.isBefore(_toggleUnlockExpiresAt!);
    if (isUnlocked) return true;

    final pinController = TextEditingController();
    String? errorText;

    final success = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          title: const Row(
            children: [
              Icon(Icons.lock_rounded, color: AppTheme.accentCyan, size: 22),
              SizedBox(width: 8),
              Text('Admin Authorization', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enter Admin PIN to switch $reason.\nIt will remain unlocked for 2 minutes.',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
              TextField(
                controller: pinController,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                style: const TextStyle(color: AppTheme.textLight, fontSize: 20),
                decoration: InputDecoration(
                  hintText: 'Enter Admin PIN',
                  hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  errorText: errorText,
                  prefixIcon: const Icon(Icons.password_rounded, color: AppTheme.accentCyan, size: 18),
                  border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                ),
              ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
              onPressed: () async {
                final entered = pinController.text.trim();
                final currentPin = await widget.dbService.getConfig('admin_pin') ?? '1234';
                if (entered == currentPin) {
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } else {
                  setDialogState(() => errorText = 'Invalid PIN. Try again.');
                }
              },
              child: const Text('Unlock', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (success == true) {
      setState(() {
        _toggleUnlockExpiresAt = DateTime.now().add(const Duration(minutes: 2));
      });
      return true;
    }
    return false;
  }

  Future<void> _handleToggleCombineDepartments(bool combine) async {
    if (_combineDepartments == combine) return;
    final ok = await _ensureAdminUnlocked(reason: 'Whole Resource view mode');
    if (!ok) return;

    setState(() {
      _combineDepartments = combine;
      _selectedPreset = GroupingEngine.getPresetForDepartment(
        _activeDepartment ?? '',
        customPresets: _presets,
        includeLine: false,
        bypassDepartmentLevel: _combineDepartments,
        isResourceScope: true,
      );
    });

    if (_isResourceScope) {
      await widget.dbService.setMainLineResourceView(_targetResourceName, combine ? 'combined' : 'split_by_dept');
    }
  }

  Future<void> _handleToggleGroupByLine(bool groupByLine) async {
    if (_groupByLine == groupByLine) return;
    final ok = await _ensureAdminUnlocked(reason: 'Department line grouping mode');
    if (!ok) return;

    setState(() {
      _groupByLine = groupByLine;
      _selectedPreset = GroupingEngine.getPresetForDepartment(
        _activeDepartment ?? '',
        customPresets: _presets,
        includeLine: _groupByLine,
        bypassDepartmentLevel: false,
        isResourceScope: false,
      );
    });

    if (_activeDepartment != null && _activeDepartment!.isNotEmpty) {
      await widget.dbService.setLineGroupingDeptOverride(_activeDepartment!, groupByLine);
    }
  }

  void _handleLockViewMode() {
    setState(() {
      _toggleUnlockExpiresAt = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('View Mode saved and locked.'),
        duration: Duration(seconds: 2),
        backgroundColor: AppTheme.statusComplete,
      ),
    );
  }

  bool _itemMatchesActiveScope(PicklistItem i) {
    if (_activeDepartment == null) return true;
    if (_isResourceScope) {
      final isMainLine = i.deptType.toUpperCase() == 'MAIN LINE' ||
          i.department.toUpperCase().contains('MAIN') ||
          i.department.toUpperCase().contains('MACG');
      if (!isMainLine) return false;
      final res = i.resourceId.trim();
      final target = _targetResourceName;
      if (target == '(Empty / Unassigned)') {
        return res.isEmpty || res == '(Empty / Unassigned)';
      }
      return res.toLowerCase() == target.toLowerCase();
    }

    // Standard department picking
    if (i.department != _activeDepartment) return false;

    // If active department is a MAIN LINE department and item belongs to a resource picked separately, exclude it!
    final isMainLineDept = _activeDepartment!.toUpperCase().contains('MAIN') ||
        _activeDepartment!.toUpperCase().contains('MACG');
    if (isMainLineDept && _mainLineResourcePicks.isNotEmpty) {
      final res = i.resourceId.trim();
      for (final wholeRes in _mainLineResourcePicks) {
        if (wholeRes == '(Empty / Unassigned)') {
          if (res.isEmpty || res == '(Empty / Unassigned)') return false;
        } else {
          if (res.toLowerCase() == wholeRes.trim().toLowerCase()) return false;
        }
      }
    }

    return true;
  }

  bool _isPartRemoved(String partId) {
    final norm = partId.trim().toUpperCase();
    for (final entry in _partFlags.entries) {
      if (entry.key.trim().toUpperCase() == norm &&
          entry.value['flag_type']?.toString().toUpperCase() == 'REMOVED') {
        return true;
      }
    }
    return false;
  }

  bool _isPartMissing(String partId) {
    final norm = partId.trim().toUpperCase();
    for (final entry in _partFlags.entries) {
      if (entry.key.trim().toUpperCase() == norm &&
          entry.value['flag_type']?.toString().toUpperCase() == 'MISSING') {
        return true;
      }
    }
    return false;
  }

  /// Build the sorted part summaries for the active department or resource (optionally filtered to a line).
  /// [pendingOnly]: when true (for Pick Mode), excludes fully picked parts while keeping pending and missing parts.
  List<PartSummary> _buildPartSummaries({String? lineFilter, bool pendingOnly = false, String? targetPartId}) {
    final targetNorm = targetPartId?.trim().toUpperCase();
    final partsMap = <String, PartSummary>{};
    for (final item in _items) {
      if (!_itemMatchesActiveScope(item)) continue;
      if (lineFilter != null && item.line != lineFilter) continue;
      final pid = item.partId.trim();
      if (partsMap.containsKey(pid)) {
        partsMap[pid] = partsMap[pid]!.add(item);
      } else {
        partsMap[pid] = PartSummary.fromItem(item);
      }
    }
    var list = partsMap.values.toList();
    // In Pick Mode, do not show removed parts, unless specifically targeted
    list = list.where((p) {
      final isTarget = targetNorm != null && p.partId.trim().toUpperCase() == targetNorm;
      if (isTarget) return true;
      final isRemoved = p.isRemoved || _isPartRemoved(p.partId);
      return !isRemoved;
    }).toList();

    if (pendingOnly) {
      // In Pick Mode, do not show fully picked parts!
      // Only show pending parts (qtyPicked < qtyRequired) or parts flagged as MISSING.
      list = list.where((p) {
        if (targetNorm != null && p.partId.trim().toUpperCase() == targetNorm) return true;
        final isMissing = _isPartMissing(p.partId);
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
    final targetNorm = partId.trim().toUpperCase();
    final matchingItem = _items.firstWhere(
      (i) => i.partId.trim().toUpperCase() == targetNorm && _itemMatchesActiveScope(i),
      orElse: () => _items.firstWhere(
        (i) => i.partId.trim().toUpperCase() == targetNorm,
        orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0),
      ),
    );
    final hasLineGrouping = _selectedPreset.levels.contains(GroupLevel.line);
    final lineLabel = (hasLineGrouping && matchingItem.line.isNotEmpty) ? matchingItem.line : null;

    final parts = _buildPartSummaries(lineFilter: lineLabel, pendingOnly: false, targetPartId: partId);
    final deptItems = _items
        .where((i) => _itemMatchesActiveScope(i) &&
                      (lineLabel == null || i.line == lineLabel))
        .toList()
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));
    var startIndex = parts.indexWhere((p) => p.partId.trim().toUpperCase() == targetNorm);
    if (startIndex < 0) startIndex = 0;
    _navigateToPickMode(parts, deptItems, startIndex: startIndex, lineLabel: lineLabel);
  }

  /// Strictly scoped Pick Mode entry: restricts picking ONLY to the items in [node].
  /// Does not allow navigation across different Resource IDs, Lines, or Departments.
  void _openPickModeForNode(TreeNode node, {String? targetPartId}) {
    final groupItems = List<PicklistItem>.from(node.leafItems)
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));

    if (groupItems.isEmpty) {
      if (targetPartId != null) {
        _openPickModeAtPart(targetPartId);
      }
      return;
    }

    final partsMap = <String, PartSummary>{};
    for (final item in groupItems) {
      final pid = item.partId.trim();
      if (partsMap.containsKey(pid)) {
        partsMap[pid] = partsMap[pid]!.add(item);
      } else {
        partsMap[pid] = PartSummary.fromItem(item);
      }
    }

    final targetNorm = targetPartId?.trim().toUpperCase();

    // 1. If a specific part was targeted (e.g. user tapped on a leaf part in the tree):
    if (targetNorm != null) {
      final targetedPart = partsMap.values.where((p) => p.partId.trim().toUpperCase() == targetNorm).firstOrNull;

      if (targetedPart != null) {
        // Build the list of parts for this node:
        // Include all active (non-removed) parts + the specifically targeted part (even if removed or completed)
        var list = partsMap.values.where((p) {
          if (p.partId.trim().toUpperCase() == targetNorm) return true;
          final isRemoved = p.isRemoved || _isPartRemoved(p.partId);
          return !isRemoved;
        }).toList();

        list.sort((a, b) {
          final aDone = a.qtyPicked >= a.qtyRequired;
          final bDone = b.qtyPicked >= b.qtyRequired;
          if (aDone != bDone) return aDone ? 1 : -1;
          return a.minRowOrder.compareTo(b.minRowOrder);
        });

        int startIndex = list.indexWhere((p) => p.partId.trim().toUpperCase() == targetNorm);
        if (startIndex < 0) startIndex = 0;

        final groupLabel = '${node.level.displayName}: ${node.label}';
        _navigateToPickMode(
          list,
          groupItems,
          startIndex: startIndex,
          lineLabel: groupLabel,
        );
        return;
      } else {
        // If not found in this node's leafItems for some reason, fallback to global scope part opener!
        _openPickModeAtPart(targetPartId!);
        return;
      }
    }

    // 2. targetPartId == null: User tapped the [⚡ Pick Mode] button on a group node (Line, Dept, Resource)
    var list = partsMap.values.where((p) {
      final isRemoved = p.isRemoved || _isPartRemoved(p.partId);
      if (isRemoved) return false;
      final isMissing = _isPartMissing(p.partId);
      final isPending = p.qtyPicked < p.qtyRequired - 0.0001;
      return isPending || isMissing;
    }).toList();

    // If all non-removed parts are picked, BUT there are incomplete removed parts in this node,
    // and the user tapped [⚡ Pick Mode], include the removed parts so the picker can enter and pick them!
    if (list.isEmpty) {
      final removedIncomplete = partsMap.values.where((p) {
        final isRemoved = p.isRemoved || _isPartRemoved(p.partId);
        return isRemoved && (p.qtyPicked < p.qtyRequired - 0.0001);
      }).toList();

      if (removedIncomplete.isNotEmpty) {
        list = removedIncomplete;
      }
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

    final groupLabel = '${node.level.displayName}: ${node.label}';
    _navigateToPickMode(
      list,
      groupItems,
      startIndex: 0,
      lineLabel: groupLabel,
    );
  }

  /// Navigate to PickModeScreen starting at the first part of [lineLabel].
  void _openPickModeAtLine(String? lineLabel) {
    final parts = _buildPartSummaries(lineFilter: lineLabel, pendingOnly: true);
    final deptItems = _items
        .where((i) => _itemMatchesActiveScope(i) &&
                       (lineLabel == null || i.line == lineLabel))
        .toList()
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));
    _navigateToPickMode(parts, deptItems, startIndex: 0, lineLabel: lineLabel);
  }

  Future<void> _navigateToPickMode(
    List<PartSummary> parts,
    List<PicklistItem> deptItems, {
    int startIndex = 0,
    String? lineLabel,
  }) async {
    await Navigator.of(context).push(
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
              final freshNotes = await widget.dbService.getUserPartNotesForUnit(_activeUnit!.id);
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
                  if (idx >= 0) {
                    _items[idx] = updated;
                  } else {
                    _items.add(updated);
                  }
                }
                _partFlags = freshMap;
                _userPartNotes = freshNotes;
                final newTotalPicked = _items.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();
                final allPartIds = _items.map((i) => i.partId).toSet();
                final allPartsDone = allPartIds.isNotEmpty && allPartIds.every((pid) {
                  final itemsForPart = _items.where((i) => i.partId == pid);
                  final totalDue = itemsForPart.fold<double>(0.0, (s, i) => s + i.qtyDue);
                  return totalDue <= 0.0001;
                });
                final totalVisibleReq = _items.fold<double>(0.0, (sum, i) => sum + i.qtyRequired).round();
                final isUnitComplete = allPartsDone || (newTotalPicked >= totalVisibleReq && totalVisibleReq > 0);
                _activeUnit = _activeUnit!.copyWith(
                  totalPicked: newTotalPicked,
                  status: isUnitComplete ? 'FULLY_PICKED' : 'IN_PROGRESS',
                );
                if (_activeSession != null) {
                  widget.dbService.getSessionPickedPartCount(_activeSession!.id).then((count) {
                    if (mounted) {
                      setState(() {
                        _activeSession = _activeSession!.copyWith(totalItemsPicked: count);
                      });
                    }
                  });
                }
              });
            }
          },
        ),
      ),
    );

    // Immediately refresh flags and items from DB upon returning to PickingScreen
    if (mounted && _activeUnit != null) {
      final freshFlags = await widget.dbService.getPartFlags(_activeUnit!.id);
      final freshNotes = await widget.dbService.getUserPartNotesForUnit(_activeUnit!.id);
      final freshMap = <String, Map<String, dynamic>>{};
      for (final f in freshFlags) {
        final pid = f['part_id']?.toString() ?? '';
        if (pid.isNotEmpty && !freshMap.containsKey(pid)) {
          freshMap[pid] = f;
        }
      }
      final freshItems = await widget.dbService.getPicklistItems(_activeUnit!.id);
      final blockedDepts = await widget.dbService.getBlockedDepartmentSet();
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

      final visibleItems = freshItems.where((i) {
        if (i.isManualAdd) return true;
        if (blockedDepts.contains(i.department.trim())) return false;
        final r = i.componentResourceId.trim().toLowerCase();
        final isEmpty = r.isEmpty;
        if (isEmpty) {
          if (isBlockedEmpty || isAutoEmpty) return false;
        } else {
          if (blockedSet.contains(r) || autoIssueResSet.contains(r)) return false;
        }
        return true;
      }).toList();

      final newTotalPicked = visibleItems.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();
      final allPartIds = visibleItems.map((i) => i.partId).toSet();
      final allPartsDone = allPartIds.isNotEmpty && allPartIds.every((pid) {
        final itemsForPart = visibleItems.where((i) => i.partId == pid);
        final totalDue = itemsForPart.fold<double>(0.0, (s, i) => s + i.qtyDue);
        return totalDue <= 0.0001;
      });
      final totalVisibleReq = visibleItems.fold<double>(0.0, (sum, i) => sum + i.qtyRequired).round();
      final isUnitComplete = allPartsDone || (newTotalPicked >= totalVisibleReq && totalVisibleReq > 0);
      final sessionPickCount = _activeSession != null
          ? await widget.dbService.getSessionPickedPartCount(_activeSession!.id)
          : 0;

      setState(() {
        _items = visibleItems;
        _partFlags = freshMap;
        _userPartNotes = freshNotes;
        _activeUnit = _activeUnit!.copyWith(
          totalPicked: newTotalPicked,
          status: isUnitComplete ? 'FULLY_PICKED' : 'IN_PROGRESS',
        );
        if (_activeSession != null) {
          _activeSession = _activeSession!.copyWith(
            totalItemsPicked: sessionPickCount,
          );
        }
      });
    }
  }

  /// Calmly return back to PickerFlowScreen (Department / Unit selection) without requiring a PIN.
  Future<void> _handleBack() async {
    if (!mounted) return;
    if (_activeSession != null && _activeSession!.sessionSeqNo != 0) {
      final sessionPickCount = await widget.dbService.getSessionPickedPartCount(_activeSession!.id);
      if (sessionPickCount == 0) {
        await widget.dbService.deleteEmptySession(_activeSession!.id);
      }
    }
    LogService.picker('${_activeSession?.workerName ?? "Worker"} returned from picking to department selection');
    if (!mounted) return;
    Navigator.of(context).pop(_activeDepartment);
  }

  /// Close Session: marks session as CLOSED in SQLite (ready for Batch Super Export in Export Hub).
  /// If 0 picks were made, the session is not saved at all!
  Future<void> _handleCloseSession() async {
    if (_activeSession == null || _activeUnit == null) return;

    final sessionPickCount = _activeSession!.sessionSeqNo == 0
        ? 0
        : await widget.dbService.getSessionPickedPartCount(_activeSession!.id);

    if (_activeSession!.sessionSeqNo == 0 || sessionPickCount == 0) {
      if (_activeSession!.sessionSeqNo != 0) {
        await widget.dbService.deleteEmptySession(_activeSession!.id);
      }
      LogService.picker('Session discarded for "${_activeSession!.workerName}" because 0 items were picked');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No parts were picked. Session not saved.'),
            backgroundColor: AppTheme.cardDark,
            duration: Duration(seconds: 3),
          ),
        );
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return;
    }

    if (!mounted) return;
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
            Text('Close Picking Session?', style: TextStyle(color: AppTheme.textLight)),
          ],
        ),
        content: Text(
          'Are you sure you want to close this picking session for ${_activeSession!.workerName}?\n\n'
          'All progress will be saved in SQLite and the session will be marked as CLOSED, '
          'ready for consolidated Batch Super Export in the Export Hub.',
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
            child: const Text('Close Session'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final effectivePicks = sessionPickCount;
    final unitTotalQty = _items.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();

    final allPartIds = _items.map((i) => i.partId).toSet();
    final allPartsDone = allPartIds.isNotEmpty && allPartIds.every((pid) {
      final itemsForPart = _items.where((i) => i.partId == pid);
      final totalDue = itemsForPart.fold<double>(0.0, (s, i) => s + i.qtyDue);
      return totalDue <= 0.0001;
    });
    final isUnitComplete = allPartsDone || (unitTotalQty >= _activeUnit!.totalRequired && _activeUnit!.totalRequired > 0);

    final updatedUnit = _activeUnit!.copyWith(
      totalPicked: unitTotalQty,
      status: isUnitComplete ? 'FULLY_PICKED' : 'IN_PROGRESS',
      completedAt: isUnitComplete ? now : null,
      lastAccessedAt: now,
    );
    await widget.dbService.updateUnit(updatedUnit);

    await widget.dbService.closeSession(_activeSession!.id, now, effectivePicks);
    LogService.picker('Session "${_activeSession!.id}" closed by "${_activeSession!.workerName}" on unit "${_activeUnit!.name}" with $effectivePicks items picked');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session CLOSED and saved! Ready for batch export in Export Hub.'),
          backgroundColor: AppTheme.statusComplete,
          duration: Duration(seconds: 3),
        ),
      );
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
    List<PicklistItem> itemsForTree;
    Set<String>? activeDepts;
    if (_isResourceScope) {
      itemsForTree = _items.where(_itemMatchesActiveScope).toList();
      activeDepts = null;
    } else if (_activeDepartment != null) {
      itemsForTree = _items.where(_itemMatchesActiveScope).toList();
      activeDepts = {_activeDepartment!};
    } else {
      itemsForTree = _items;
      activeDepts = _departmentsMap.entries
          .where((e) => e.value == true)
          .map((e) => e.key)
          .toSet();
    }

    final treeNodes = GroupingEngine.buildTree(
      items: itemsForTree,
      preset: _selectedPreset,
      activeDepartments: activeDepts,
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
                  final deptItems = _items.where(_itemMatchesActiveScope).toList();
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
                  final autoType = _isResourceScope
                      ? 'MAIN LINE RESOURCE'
                      : (deptTypeFromItems.isNotEmpty
                          ? deptTypeFromItems
                          : ((_activeDepartment?.toUpperCase().contains('MAIN') ?? false) ||
                                  (_activeDepartment?.toUpperCase().contains('MACG') ?? false)
                              ? 'MAIN LINE'
                              : 'SUBASSEMBLY'));

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

                  final isUnlocked = _toggleUnlockExpiresAt != null && DateTime.now().isBefore(_toggleUnlockExpiresAt!);

                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.10),
                      border: const Border(
                        bottom: BorderSide(color: AppTheme.borderDark, width: 1),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Row 1: Icon, Type Badge, Title, Progress Badge, Pick Date, Prod Date
                        Row(
                          children: [
                            Icon(
                              _isResourceScope ? Icons.precision_manufacturing_rounded : Icons.apartment_rounded,
                              size: 16,
                              color: AppTheme.accentCyan,
                            ),
                            const SizedBox(width: 8),
                            // Dept type badge (MAIN LINE / SUBASSEMBLY)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: (_isResourceScope || autoType == 'MAIN LINE')
                                    ? const Color(0xFF0EA5E9).withValues(alpha: 0.15)
                                    : const Color(0xFFF97316).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: (_isResourceScope || autoType == 'MAIN LINE')
                                      ? const Color(0xFF0EA5E9).withValues(alpha: 0.5)
                                      : const Color(0xFFF97316).withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                autoType.isNotEmpty ? autoType : 'DEPT',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: (_isResourceScope || autoType == 'MAIN LINE')
                                      ? const Color(0xFF0EA5E9)
                                      : const Color(0xFFF97316),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _isResourceScope
                                    ? 'Resource: $_targetResourceName (MAIN LINE)'
                                    : 'Department: $_activeDepartment',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.accentCyan,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 10),
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
                                '${_isResourceScope ? "Resource" : "Dept"}: $deptCompletedParts / $deptTotalParts parts ($deptPct%)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: deptCompletedParts >= deptTotalParts && deptTotalParts > 0
                                      ? AppTheme.statusComplete
                                      : AppTheme.accentCyan,
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (pickDate.isNotEmpty) ...[
                              const Icon(Icons.event_available_rounded, size: 14, color: AppTheme.statusPartial),
                              const SizedBox(width: 4),
                              Text(
                                'Pick: $pickDate',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textLight, fontWeight: FontWeight.w500),
                              ),
                            ],
                            if (prodDate.isNotEmpty) ...[
                              const SizedBox(width: 12),
                              const Icon(Icons.precision_manufacturing_rounded, size: 14, color: AppTheme.textMuted),
                              const SizedBox(width: 4),
                              Text(
                                'Prod: $prodDate',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Row 2: View Mode Label + Toggle (Whole Resource or Department Line)
                        Row(
                          children: [
                            const Text(
                              'View Mode:',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textMuted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (_isResourceScope)
                              _buildResourceToggle(isUnlocked)
                            else
                              _buildDepartmentLineToggle(isUnlocked),
                            if (isUnlocked) ...[
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.statusComplete.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppTheme.statusComplete.withValues(alpha: 0.4)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.timer_outlined, size: 11, color: AppTheme.statusComplete),
                                    SizedBox(width: 3),
                                    Text(
                                      '2m Admin PIN active',
                                      style: TextStyle(fontSize: 10, color: AppTheme.statusComplete, fontWeight: FontWeight.w500),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: _handleLockViewMode,
                                borderRadius: BorderRadius.circular(5),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppTheme.statusComplete,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.check_rounded, size: 12, color: Colors.black),
                                      SizedBox(width: 3),
                                      Text(
                                        'Save & Lock',
                                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.black),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
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
                userPartNotes: _userPartNotes,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResourceToggle(bool isUnlocked) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isUnlocked ? AppTheme.statusComplete.withValues(alpha: 0.6) : AppTheme.borderDark,
        ),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Tooltip(
              message: isUnlocked ? 'Unlocked (Admin)' : 'Admin PIN required to toggle',
              child: Icon(
                isUnlocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                size: 13,
                color: isUnlocked ? AppTheme.statusComplete : AppTheme.textMuted,
              ),
            ),
          ),
          InkWell(
            onTap: () => _handleToggleCombineDepartments(true),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _combineDepartments ? AppTheme.primaryBlue : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.merge_type_rounded,
                    size: 13,
                    color: _combineDepartments ? AppTheme.textLight : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Combined (All Depts)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: _combineDepartments ? FontWeight.bold : FontWeight.normal,
                      color: _combineDepartments ? AppTheme.textLight : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          InkWell(
            onTap: () => _handleToggleCombineDepartments(false),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: !_combineDepartments ? AppTheme.primaryBlue : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.account_tree_rounded,
                    size: 13,
                    color: !_combineDepartments ? AppTheme.textLight : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'By Department',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: !_combineDepartments ? FontWeight.bold : FontWeight.normal,
                      color: !_combineDepartments ? AppTheme.textLight : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDepartmentLineToggle(bool isUnlocked) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isUnlocked ? AppTheme.statusComplete.withValues(alpha: 0.6) : AppTheme.borderDark,
        ),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Tooltip(
              message: isUnlocked ? 'Unlocked (Admin)' : 'Admin PIN required to toggle',
              child: Icon(
                isUnlocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                size: 13,
                color: isUnlocked ? AppTheme.statusComplete : AppTheme.textMuted,
              ),
            ),
          ),
          InkWell(
            onTap: () => _handleToggleGroupByLine(false),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: !_groupByLine ? AppTheme.primaryBlue : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.view_headline_rounded,
                    size: 13,
                    color: !_groupByLine ? AppTheme.textLight : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Combined (No Line)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: !_groupByLine ? FontWeight.bold : FontWeight.normal,
                      color: !_groupByLine ? AppTheme.textLight : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          InkWell(
            onTap: () => _handleToggleGroupByLine(true),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _groupByLine ? AppTheme.primaryBlue : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.format_line_spacing_rounded,
                    size: 13,
                    color: _groupByLine ? AppTheme.textLight : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'By Line',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: _groupByLine ? FontWeight.bold : FontWeight.normal,
                      color: _groupByLine ? AppTheme.textLight : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
