import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../engine/column_mapper.dart';
import '../../engine/fifo_allocation_engine.dart';
import '../../models/part_summary.dart';
import '../../models/picklist_item.dart';
import '../../models/session_metadata.dart';
import '../../models/unit_pick_date_urgency.dart';
import '../../models/unit_record.dart';
import '../../services/database_service.dart';
import '../../services/log_service.dart';
import '../theme/app_theme.dart';

/// PickModeScreen: Unified full-screen split-view picking mode.
///
/// Used for BOTH the Pick Mode toggle AND tapping a Part ID in List mode.
/// Ensure consistent picking UX across both entry points.
///
/// Layout:
/// - Header: Part N of M, department, tablet/session info, back button.
/// - Upper section: Part ID (large), description, ON_HAND, Unit, dates,
///   Work Orders with quantities (parent part info), metadata chips, status badge, qty stats.
/// - Lower section: Touch console — keypad, delta input, Confirm (shows confirmation
///   screen before saving), Match Due, Return Picked (LIFO), Missing Part, navigation.
///
/// Anti-Clear & Delta Picking:
/// - Keypad inputs the delta to add to SQLite (currentPicked + delta).
/// - Clear resets only the pending input buffer — never zeroes DB data.
/// - Confirm Pick shows a preview screen (Part ID, picked, remaining due/required)
///   before committing to DB.
/// - Return Picked uses LIFO allocation (last WO first) and cannot exceed picked qty.
class PickModeScreen extends StatefulWidget {
  final UnitRecord unit;
  final String department;
  /// Optional: when entering Pick Mode from a specific Line node.
  final String? lineLabel;
  final List<PartSummary> partSummaries;
  final List<PicklistItem> allDeptItems;
  final int startIndex;
  final DatabaseService dbService;
  final SessionMetadata? activeSession;
  final String tabletId;
  final VoidCallback? onFinished;
  /// Called after DB updates so the parent can refresh its item list.
  final void Function(List<PicklistItem> updatedItems)? onItemsUpdated;

  const PickModeScreen({
    super.key,
    required this.unit,
    required this.department,
    this.lineLabel,
    required this.partSummaries,
    required this.allDeptItems,
    required this.startIndex,
    required this.dbService,
    this.activeSession,
    this.tabletId = '',
    this.onFinished,
    this.onItemsUpdated,
  });

  @override
  State<PickModeScreen> createState() => _PickModeScreenState();
}

class _PickModeScreenState extends State<PickModeScreen> with WidgetsBindingObserver {
  late PageController _pageController;
  late List<PartSummary> _currentParts;
  late List<PicklistItem> _items;
  late UnitRecord _unit;
  int _currentIndex = 0;
  final Set<String> _flaggedMissingParts = {};
  final Map<String, Map<String, dynamic>> _missingPartDetails = {};
  // Parts flagged as REMOVED FROM PICKING (greyed out, excluded from auto-advance)
  final Set<String> _removedFromPickingParts = {};
  final Map<String, String> _removedPartComments = {};
  // Map of current partId → original (replaced) partId for display
  final Map<String, String> _replacedPartIds = {};
  // Free-form picker notes map: partId → note
  final Map<String, String> _userPartNotes = {};
  // Expanded Work Orders per partId
  final Set<String> _expandedWoPartIds = {};
  String _inputBuffer = '';
  bool _autoAdvance = false;

  // In-screen Return Mode state
  bool _isReturnMode = false;
  String _returnInputBuffer = '';
  final _returnReasonController = TextEditingController();
  final _returnReasonFocusNode = FocusNode();

  // Confirmation overlay state
  bool _showConfirm = false;
  double _pendingDelta = 0.0;

  // Fully Picked banner state
  bool _showFullyPickedBanner = false;
  String _fullyPickedPartId = '';

  SessionMetadata? _session;
  String? _initialTargetPartId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = widget.activeSession;
    final initialPart = (widget.startIndex >= 0 && widget.startIndex < widget.partSummaries.length)
        ? widget.partSummaries[widget.startIndex]
        : null;
    _initialTargetPartId = initialPart?.partId;

    _currentParts = widget.partSummaries.where((p) {
      if (!p.isRemoved) return true;
      if (initialPart != null && p.partId.trim().toUpperCase() == initialPart.partId.trim().toUpperCase()) {
        return true;
      }
      return false;
    }).toList();

    _currentIndex = initialPart != null
        ? _currentParts.indexWhere((p) => p.partId.trim().toUpperCase() == initialPart.partId.trim().toUpperCase())
        : 0;
    if (_currentIndex < 0) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);
    _items = List.from(widget.allDeptItems);
    _unit = widget.unit;
    _loadSettings();
    _loadMissingParts();
    _loadRemovedParts();
    _loadReplacedPartIds();
    _loadUserPartNotes();
  }

  Future<void> _loadUserPartNotes() async {
    final notes = await widget.dbService.getUserPartNotesForUnit(_unit.id);
    if (mounted) {
      setState(() {
        _userPartNotes.addAll(notes);
      });
    }
  }

  Future<void> _loadSettings() async {
    final autoAdv = await widget.dbService.getAutoAdvancePick();
    if (mounted) setState(() => _autoAdvance = autoAdv);
  }

  Future<void> _loadMissingParts() async {
    final flags = _isResourceScope
        ? await widget.dbService.getPartFlags(_unit.id)
        : await widget.dbService.getPartFlags(_unit.id, department: widget.department);
    final missing = <String>{};
    final details = <String, Map<String, dynamic>>{};
    for (final f in flags) {
      if (f['flag_type']?.toString().toUpperCase() == 'MISSING') {
        final pid = f['part_id']?.toString() ?? '';
        if (pid.isNotEmpty) {
          missing.add(pid);
          details[pid] = f;
        }
      }
    }
    if (mounted) {
      setState(() {
        _flaggedMissingParts.addAll(missing);
        _missingPartDetails.addAll(details);
      });
    }
  }

  /// Loads all parts flagged as REMOVED FROM PICKING for the current scope.
  Future<void> _loadRemovedParts() async {
    final dept = _isResourceScope ? null : widget.department;
    final removed = await widget.dbService.getRemovedFromPickingParts(
      _unit.id,
      department: dept,
    );
    final comments = await widget.dbService.getRemovedPartCommentsForUnit(
      _unit.id,
      department: dept,
    );
    if (mounted) {
      setState(() {
        _removedFromPickingParts.addAll(removed);
        _removedPartComments.addAll(comments);
        // Exclude removed parts from Pick Mode carousel, except for the initially targeted part
        _currentParts.removeWhere((p) {
          final isRemoved = p.isRemoved || _removedFromPickingParts.contains(p.partId);
          if (!isRemoved) return false;
          if (_initialTargetPartId != null && p.partId.trim().toUpperCase() == _initialTargetPartId!.trim().toUpperCase()) {
            return false;
          }
          return true;
        });
        if (_currentIndex >= _currentParts.length) {
          _currentIndex = _currentParts.isEmpty ? 0 : _currentParts.length - 1;
        }
        if (_currentParts.isNotEmpty && _pageController.hasClients) {
          _pageController.jumpToPage(_currentIndex);
        }
      });
    }
  }

  /// Loads the replaced Part ID map (currentPartId → originalPartId) from loaded items.
  void _loadReplacedPartIds() {
    final map = <String, String>{};
    for (final item in _items) {
      if (item.replacedPartId.isNotEmpty) {
        map[item.partId] = item.replacedPartId;
      }
    }
    if (mounted) {
      setState(() {
        _replacedPartIds.addAll(map);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushSession();
    _pageController.dispose();
    _returnReasonController.dispose();
    _returnReasonFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _flushSession();
    }
  }

  /// Resolves the ON-HAND info for a part across all loaded items and raw columns.
  String _resolveOnHand(PartSummary part) {
    if (part.onHand.trim().isNotEmpty && part.onHand.trim().toLowerCase() != 'null') {
      return part.onHand.trim();
    }
    final matching = _items.where(
      (i) => i.partId.toLowerCase().trim() == part.partId.toLowerCase().trim(),
    ).toList();
    for (final it in matching) {
      if (it.onHand.trim().isNotEmpty && it.onHand.trim().toLowerCase() != 'null') {
        return it.onHand.trim();
      }
    }
    // Dynamic fallback to rawColumns
    for (final it in matching) {
      if (it.rawColumns.isNotEmpty) {
        for (final entry in it.rawColumns.entries) {
          final norm = ColumnMapper.normalize(entry.key);
          if (norm == 'ON HAND' ||
              norm.contains('ON HAND') ||
              norm.contains('ONHAND') ||
              norm.contains('LOCATION') ||
              norm.contains('BIN') ||
              norm.contains('STOCK') ||
              norm.contains('INVENTORY') ||
              norm == 'LOC' ||
              norm == 'OH') {
            final val = entry.value?.toString().trim() ?? '';
            if (val.isNotEmpty && val.toLowerCase() != 'null') {
              return val;
            }
          }
        }
      }
    }
    return '';
  }

  /// Ensure session is persisted to SQLite ONLY upon first pick.
  Future<void> _ensureSessionPersisted() async {
    if (_session == null) return;
    if (_session!.sessionSeqNo == 0) {
      final seqNo = await widget.dbService.nextSessionSeqNo(_unit.id);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final persisted = _session!.copyWith(
        sessionSeqNo: seqNo,
        startTime: nowMs,
      );
      await widget.dbService.saveSession(persisted);
      if (mounted) {
        setState(() {
          _session = persisted;
        });
      } else {
        _session = persisted;
      }
      LogService.picker('Session #$seqNo started upon first pick for ${_session!.workerName} on unit "${_unit.name}"');
    }
  }

  Future<void> _flushSession() async {
    if (_session == null || _session!.sessionSeqNo == 0) return;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final pickedCount = await widget.dbService.getSessionPickedPartCount(_session!.id);
      await widget.dbService.updateSessionProgress(
        _session!.id,
        pickedCount,
        endTime: nowMs,
      );
    } catch (_) {}
  }

  bool get _isResourceScope =>
      widget.department.startsWith('Resource: ') &&
      widget.department.endsWith(' (MAIN LINE)');

  String get _targetResourceName => _isResourceScope
      ? widget.department
          .substring('Resource: '.length, widget.department.length - ' (MAIN LINE)'.length)
          .trim()
      : '';

  bool _itemMatchesScope(PicklistItem i) {
    if (widget.department.isEmpty || widget.department == 'All Departments') return true;
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
    return i.department.toLowerCase().trim() == widget.department.toLowerCase().trim();
  }

  double _getCurrentPicked(String partId) {
    final cleanPartId = partId.toLowerCase().trim();
    return _items
        .where((i) => _itemMatchesScope(i) && i.partId.toLowerCase().trim() == cleanPartId)
        .fold<double>(0.0, (sum, i) => sum + i.qtyPicked);
  }

  double _getRequiredQty(String partId) {
    final cleanPartId = partId.toLowerCase().trim();
    return _items
        .where((i) => _itemMatchesScope(i) && i.partId.toLowerCase().trim() == cleanPartId)
        .fold<double>(0.0, (sum, i) => sum + i.qtyRequired);
  }

  double _getDueQty(String partId) {
    final req = _getRequiredQty(partId);
    final picked = _getCurrentPicked(partId);
    final due = req - picked;
    return due > 0.0001 ? due : 0.0;
  }

  Future<void> _commitPick(PartSummary part, double delta) async {
    final currentPicked = _getCurrentPicked(part.partId);
    final newTotal = currentPicked + delta;
    final requiredQty = _getRequiredQty(part.partId);
    final isNowFullyPicked = newTotal >= requiredQty - 0.0001 && requiredQty > 0;

    final previousItems = List<PicklistItem>.from(_items);

    final wasRemoved = part.isRemoved || _removedFromPickingParts.contains(part.partId);

    var updatedList = FifoAllocationEngine.allocateByPartId(
      allItems: _items,
      department: widget.department,
      partId: part.partId,
      totalPickedToAllocate: newTotal,
    );
    if (wasRemoved) {
      updatedList = updatedList.map<PicklistItem>((i) {
        if (i.partId.toLowerCase().trim() == part.partId.toLowerCase().trim()) {
          return i.copyWith(isRemoved: false);
        }
        return i;
      }).toList();
    }

    final newTotalPicked = updatedList.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final updatedUnit = _unit.copyWith(
      totalPicked: newTotalPicked,
      status: newTotalPicked >= _unit.totalRequired && _unit.totalRequired > 0
          ? 'COMPLETED'
          : 'IN_PROGRESS',
      completedAt: newTotalPicked >= _unit.totalRequired && _unit.totalRequired > 0
          ? nowMs
          : null,
      lastAccessedAt: nowMs,
    );

    if (mounted) {
      setState(() {
        _items = updatedList;
        _unit = updatedUnit;
        _inputBuffer = '';
        _showConfirm = false;
        _pendingDelta = 0.0;
      });
    }

    await widget.dbService.batchUpdateItems(updatedList);
    await widget.dbService.updateUnit(updatedUnit);
    if (_session != null) {
      if (_session!.sessionSeqNo == 0) {
        await _ensureSessionPersisted();
      }
      if (delta > 0.0001) {
        final affected = updatedList.where((i) => _itemMatchesScope(i) && i.partId.toLowerCase().trim() == part.partId.toLowerCase().trim());
        for (final item in affected) {
          final old = previousItems.firstWhere((o) => o.id == item.id, orElse: () => item);
          final itemDelta = item.qtyPicked - old.qtyPicked;
          if (itemDelta > 0.0001) {
            await widget.dbService.recordSessionPick(
              sessionId: _session!.id,
              unitId: _unit.id,
              itemId: item.id,
              partId: part.partId,
              qtyPickedDelta: itemDelta,
            );
          }
          if (item.isManualAdd) {
            await widget.dbService.updateManualPickQuantity(
              unitId: _unit.id,
              partId: item.partId,
              newQty: item.qtyPicked,
            );
          }
        }
      }
      final pickedCount = await widget.dbService.getSessionPickedPartCount(_session!.id);
      await widget.dbService.updateSessionProgress(
        _session!.id,
        pickedCount,
        endTime: nowMs,
      );
      if (mounted) {
        setState(() {
          _session = _session!.copyWith(
            totalItemsPicked: pickedCount,
            endTime: nowMs,
          );
        });
      }
    }
    widget.onItemsUpdated?.call(updatedList);

    // If part was marked REMOVED and is now picked, unmark REMOVED status
    if (wasRemoved) {
      await widget.dbService.unmarkPartRemoval(
        unitId: _unit.id,
        partId: part.partId,
        department: widget.department,
        resourceId: _isResourceScope ? _targetResourceName : null,
      );
      if (mounted) {
        setState(() {
          _removedFromPickingParts.remove(part.partId);
          _removedPartComments.remove(part.partId);
          if (_initialTargetPartId?.toUpperCase() == part.partId.toUpperCase()) {
            _initialTargetPartId = null;
          }
          for (int i = 0; i < _currentParts.length; i++) {
            if (_currentParts[i].partId.toUpperCase() == part.partId.toUpperCase()) {
              _currentParts[i] = _currentParts[i].copyWith(isRemoved: false);
            }
          }
        });
      }
    }

    // If part was flagged MISSING and is now picked, clear the flag and badge immediately
    if (_flaggedMissingParts.contains(part.partId)) {
      await widget.dbService.clearPartFlag(
        unitId: _unit.id,
        partId: part.partId,
        department: widget.department,
        flagType: 'MISSING',
      );
      if (mounted) {
        setState(() {
          _flaggedMissingParts.remove(part.partId);
          _missingPartDetails.remove(part.partId);
        });
      }
    }

    LogService.picker('PICK: ${part.partId} +${PartSummary.formatQty(delta)} ${part.uomLabel} (${PartSummary.formatQty(newTotal)}/${PartSummary.formatQty(requiredQty)}) → Unit: ${_unit.name}, Dept: ${widget.department}, Line: ${widget.lineLabel ?? "Default"}');

    // Show banner + optional auto-advance
    if (isNowFullyPicked && mounted) {
      setState(() {
        _showFullyPickedBanner = true;
        _fullyPickedPartId = part.partId;
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() => _showFullyPickedBanner = false);
        if (_autoAdvance) _goToNextPart();
      }
    } else if (_autoAdvance && mounted) {
      _goToNextPart();
    }
  }

  void _onKeypadTap(String value) {
    if (_showConfirm) return; // lock keypad during confirmation
    setState(() {
      if (_isReturnMode) {
        if (value == '.') {
          if (!_returnInputBuffer.contains('.')) {
            _returnInputBuffer = _returnInputBuffer.isEmpty ? '0.' : '$_returnInputBuffer.';
          }
        } else if (value == '⌫') {
          if (_returnInputBuffer.isNotEmpty) {
            _returnInputBuffer = _returnInputBuffer.substring(0, _returnInputBuffer.length - 1);
          }
        } else if (value == 'C') {
          _returnInputBuffer = '';
        } else {
          // Cap fractional input to at most 2 decimal digits
          if (_returnInputBuffer.contains('.')) {
            final parts = _returnInputBuffer.split('.');
            if (parts.length > 1 && parts[1].length >= 2) return;
          }
          if (_returnInputBuffer == '0') {
            _returnInputBuffer = value;
          } else {
            _returnInputBuffer += value;
          }
        }
        return;
      }

      if (value == '.') {
        if (!_inputBuffer.contains('.')) {
          _inputBuffer = _inputBuffer.isEmpty ? '0.' : '$_inputBuffer.';
        }
      } else if (value == '⌫') {
        if (_inputBuffer.isNotEmpty) {
          _inputBuffer = _inputBuffer.substring(0, _inputBuffer.length - 1);
        }
      } else if (value == 'C') {
        // Anti-Clear: only clears keypad input buffer, never DB data!
        _inputBuffer = '';
      } else {
        // Cap fractional input to at most 2 decimal digits
        if (_inputBuffer.contains('.')) {
          final parts = _inputBuffer.split('.');
          if (parts.length > 1 && parts[1].length >= 2) return;
        }
        if (_inputBuffer == '0') {
          _inputBuffer = value;
        } else {
          _inputBuffer += value;
        }
      }
    });
  }

  /// Show confirmation overlay before committing to DB.
  void _requestConfirmDeltaPick(PartSummary part) {
    final delta = double.tryParse(_inputBuffer);
    if (delta == null || delta <= 0) return;

    final dueQty = _getDueQty(part.partId);
    if (delta > dueQty + 0.0001) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot pick more than remaining due (${PartSummary.formatQty(dueQty)} ${part.uomLabel}).'),
          backgroundColor: AppTheme.statusDanger,
        ),
      );
      return;
    }

    setState(() {
      _pendingDelta = delta;
      _showConfirm = true;
    });
  }

  void _pickMatchDue(PartSummary part) {
    final dueQty = _getDueQty(part.partId);
    if (dueQty <= 0.0001) return;

    setState(() {
      _pendingDelta = dueQty;
      _showConfirm = true;
    });
  }

  void _goToNextPart() {
    final currentPart = _currentParts.isNotEmpty ? _currentParts[_currentIndex] : null;
    final isCurrentPartRemoved = currentPart != null &&
        (currentPart.isRemoved || _removedFromPickingParts.contains(currentPart.partId));

    if (isCurrentPartRemoved) {
      if (_initialTargetPartId != null &&
          _initialTargetPartId!.trim().toUpperCase() == currentPart.partId.trim().toUpperCase()) {
        _initialTargetPartId = null;
      }
      final targetIdx = _currentIndex < _currentParts.length - 1 ? _currentIndex : 0;
      setState(() {
        _currentParts.removeAt(_currentIndex);
        _inputBuffer = '';
        _currentIndex = _currentParts.isEmpty ? 0 : targetIdx.clamp(0, _currentParts.length - 1);
      });
      if (_currentParts.isEmpty) {
        _handleAllPartsFinished();
        return;
      }
      _pageController.jumpToPage(_currentIndex);
      return;
    }

    if (_currentIndex < _currentParts.length - 1) {
      LogService.info('USER_ACTION', 'PickMode: Next (idx $_currentIndex)');
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    } else {
      // Reached the end -> Smoothly animate back to the first incomplete part!
      final targetIdx = _currentParts.indexWhere((p) {
        final isRemoved = p.isRemoved || _removedFromPickingParts.contains(p.partId);
        if (isRemoved) return false;
        final isMissing = _flaggedMissingParts.contains(p.partId);
        final due = _getDueQty(p.partId);
        return due > 0.0001 || isMissing;
      });

      if (targetIdx == -1) {
        _handleAllPartsFinished();
        return;
      }

      LogService.picker('PickMode: Animate loop to first incomplete part (idx $targetIdx)');
      setState(() {
        _inputBuffer = '';
      });
      if (targetIdx != _currentIndex) {
        _pageController.animateToPage(
          targetIdx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void _goToPrevPart() {
    final currentPart = _currentParts.isNotEmpty ? _currentParts[_currentIndex] : null;
    final isCurrentPartRemoved = currentPart != null &&
        (currentPart.isRemoved || _removedFromPickingParts.contains(currentPart.partId));

    if (isCurrentPartRemoved) {
      if (_initialTargetPartId != null &&
          _initialTargetPartId!.trim().toUpperCase() == currentPart.partId.trim().toUpperCase()) {
        _initialTargetPartId = null;
      }
      final targetIdx = (_currentIndex - 1).clamp(0, _currentParts.length - 2);
      setState(() {
        _currentParts.removeAt(_currentIndex);
        _inputBuffer = '';
        _currentIndex = targetIdx < 0 ? 0 : targetIdx;
      });
      if (_currentParts.isEmpty) {
        _handleAllPartsFinished();
        return;
      }
      _pageController.jumpToPage(_currentIndex);
      return;
    }

    if (_currentIndex > 0) {
      LogService.picker('PickMode: Previous (idx $_currentIndex)');
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  void _handleAllPartsFinished() {
    LogService.picker('PickMode: all parts complete in ${widget.department}');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All parts for this department have been picked!'),
        backgroundColor: AppTheme.statusComplete,
        duration: Duration(seconds: 3),
      ),
    );
    if (widget.onFinished != null) {
      widget.onFinished!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _markPartMissing(PartSummary part) async {
    if (part.isManualAdd) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Manually added parts cannot be marked as missing.'),
            backgroundColor: AppTheme.statusDanger,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final worker = widget.activeSession?.workerName ?? _session?.workerName ?? 'Picker';
    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _flaggedMissingParts.add(part.partId);
      _missingPartDetails[part.partId] = {
        'worker_name': worker,
        'note': 'Marked missing by $worker in Pick Mode',
        'created_at': now,
      };
      _inputBuffer = '';
    });

    await widget.dbService.recordPartFlag(
      unitId: _unit.id,
      partId: part.partId,
      department: widget.department,
      flagType: 'MISSING',
      note: 'Marked missing by $worker in Pick Mode',
    );

    LogService.picker('MISSING flagged: ${part.partId}');
    widget.onItemsUpdated?.call(_items);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Part ${part.partId} flagged as MISSING'),
          backgroundColor: AppTheme.statusDanger,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    _goToNextPart();
  }

  // ---------------------------------------------------------------------------
  // MANUAL ADD PART (Pick Mode only)
  // ---------------------------------------------------------------------------

  /// Shows the manual part addition dialog. Only available in Pick Mode.
  /// Worker enters Part ID (any), quantity, and a mandatory description ≥10 chars.
  Future<void> _showManualAddPartDialog() async {
    if (_session == null) return;
    final partIdController = TextEditingController();
    final noteController = TextEditingController();
    String qtyBuffer = '1';

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlgState) {
          final scopePartIds = _items
              .where((i) => _itemMatchesScope(i))
              .map((i) => i.partId.trim().toUpperCase())
              .toSet();
          final noteLen = noteController.text.trim().length;
          final isNoteOk = noteLen >= 10;
          final rawPartId = partIdController.text.trim().toUpperCase();
          final isLengthOk = rawPartId.length >= 8;
          final isValidPartId = RegExp(r'^[A-Z0-9]+$').hasMatch(rawPartId);
          final isDuplicate = rawPartId.isNotEmpty && scopePartIds.contains(rawPartId);
          final isPartIdOk = isValidPartId && isLengthOk && !isDuplicate;
          final parsedQty = double.tryParse(qtyBuffer) ?? 0.0;
          final isQtyOk = parsedQty > 0.0001;
          final canConfirm = isPartIdOk && isQtyOk && isNoteOk;

          void tapKey(String k) {
            setDlgState(() {
              if (k == '⌫') {
                if (qtyBuffer.isNotEmpty) qtyBuffer = qtyBuffer.substring(0, qtyBuffer.length - 1);
              } else if (k == 'C') {
                qtyBuffer = '';
              } else if (k == '.') {
                if (!qtyBuffer.contains('.')) qtyBuffer = qtyBuffer.isEmpty ? '0.' : '$qtyBuffer.';
              } else {
                if (qtyBuffer.contains('.')) {
                  final parts = qtyBuffer.split('.');
                  if (parts.length > 1 && parts[1].length >= 2) return;
                }
                qtyBuffer = qtyBuffer == '0' ? k : '$qtyBuffer$k';
              }
            });
          }

          Widget keyBtn(String label) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.bgDark,
                      foregroundColor: AppTheme.textLight,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    onPressed: () => tapKey(label),
                    child: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
              );

          return AlertDialog(
            backgroundColor: AppTheme.cardDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(children: [
              Icon(Icons.add_circle_outline_rounded, color: AppTheme.accentCyan, size: 22),
              SizedBox(width: 8),
              Text('Add Part Manually', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
            ]),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Part ID input
                    TextField(
                      controller: partIdController,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [_UpperAlphanumericInputFormatter()],
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 16, letterSpacing: 1.2),
                      decoration: InputDecoration(
                        labelText: 'Part ID (min 8 chars) *',
                        labelStyle: const TextStyle(color: AppTheme.textMuted),
                        hintText: 'UPPERCASE, digits only',
                        hintStyle: const TextStyle(color: AppTheme.textMuted),
                        filled: true,
                        fillColor: AppTheme.bgDark,
                        errorText: isDuplicate
                            ? 'Part ID already exists in this ${_isResourceScope ? "Resource" : "Department"}'
                            : (rawPartId.isNotEmpty && !isValidPartId
                                ? 'Only uppercase letters (A-Z) and digits (0-9) allowed'
                                : (rawPartId.isNotEmpty && !isLengthOk
                                    ? '${rawPartId.length}/8 min characters required'
                                    : null)),
                        helperText: rawPartId.isNotEmpty && isValidPartId && isLengthOk
                            ? '${rawPartId.length} chars — OK'
                            : null,
                      ),
                      onChanged: (_) => setDlgState(() {}),
                    ),
                    const SizedBox(height: 12),
                    // Quantity display
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.bgDark,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('QTY PICKED:', style: TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold)),
                          Text(
                            qtyBuffer.isEmpty ? '0' : qtyBuffer,
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Mini keypad
                    for (final row in [
                      ['1', '2', '3'],
                      ['4', '5', '6'],
                      ['7', '8', '9'],
                      ['.', '0', '⌫'],
                    ])
                      Row(children: row.map(keyBtn).toList()),
                    const SizedBox(height: 12),
                    // Description/note
                    TextField(
                      controller: noteController,
                      keyboardType: TextInputType.multiline,
                      minLines: 2,
                      maxLines: 5,
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 14),
                      decoration: const InputDecoration(
                        labelText: 'Description / Note (min 10 characters) *',
                        labelStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                        hintText: 'Why was this part added manually?',
                        hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        filled: true,
                        fillColor: AppTheme.bgDark,
                      ),
                      onChanged: (_) => setDlgState(() {}),
                    ),
                    const SizedBox(height: 4),
                  Row(children: [
                    Icon(
                      isNoteOk ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                      size: 14,
                      color: isNoteOk ? AppTheme.statusComplete : AppTheme.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isNoteOk ? '$noteLen/10 chars — OK' : '$noteLen/10 min chars required',
                      style: TextStyle(fontSize: 11, color: isNoteOk ? AppTheme.statusComplete : AppTheme.textMuted),
                    ),
                  ]),
                ],
              ),
            ),
            ),
            actions: [
              TextButton(
                child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: canConfirm ? AppTheme.accentCyan : AppTheme.bgDark,
                  foregroundColor: canConfirm ? Colors.black : AppTheme.textMuted,
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text('Add ${qtyBuffer.isEmpty ? '' : qtyBuffer} PCS', style: const TextStyle(fontWeight: FontWeight.bold)),
                onPressed: canConfirm
                    ? () async {
                        Navigator.of(ctx).pop();
                        await _commitManualAdd(
                          partId: partIdController.text.trim().toUpperCase(),
                          qty: parsedQty,
                          note: noteController.text.trim(),
                        );
                      }
                    : null,
              ),
            ],
          );
        });
      },
    );
  }

  /// Commits a manually added part: ensures session is active, records in DB, updates local state.
  Future<void> _commitManualAdd({required String partId, required double qty, required String note}) async {
    await _ensureSessionPersisted();
    final sessionId = _session?.id ?? '';
    final workerName = _session?.workerName ?? widget.activeSession?.workerName ?? 'Picker';

    // Find the best reference item from the active picking context
    final currentPart = _currentParts.isNotEmpty
        ? _currentParts[_currentIndex.clamp(0, _currentParts.length - 1)]
        : null;

    PicklistItem? sampleItem;
    if (currentPart != null) {
      for (final it in widget.allDeptItems) {
        if (it.partId.trim().toUpperCase() == currentPart.partId.trim().toUpperCase()) {
          sampleItem = it;
          break;
        }
      }
    }
    if (sampleItem == null && widget.allDeptItems.isNotEmpty) {
      sampleItem = widget.allDeptItems.first;
    }
    sampleItem ??= _items.where((i) => _itemMatchesScope(i)).firstOrNull;
    sampleItem ??= _items.firstOrNull;

    final workOrder = sampleItem?.workOrder.isNotEmpty == true && sampleItem!.workOrder != 'WO-0'
        ? sampleItem.workOrder
        : 'MANUAL';

    final deptFromLabel = (widget.lineLabel != null && widget.lineLabel!.startsWith('Department: '))
        ? widget.lineLabel!.substring('Department: '.length).trim()
        : '';
    final dept = deptFromLabel.isNotEmpty
        ? deptFromLabel
        : (_isResourceScope
            ? (sampleItem?.department.isNotEmpty == true ? sampleItem!.department : 'MAIN LINE')
            : widget.department);

    String line = '';
    if (sampleItem != null && sampleItem.line.isNotEmpty) {
      line = sampleItem.line;
    } else if (widget.lineLabel != null && widget.lineLabel!.isNotEmpty) {
      if (widget.lineLabel!.startsWith('Line: ')) {
        line = widget.lineLabel!.substring('Line: '.length).trim();
      } else if (!widget.lineLabel!.startsWith('Department: ') && !widget.lineLabel!.startsWith('Resource')) {
        line = widget.lineLabel!.trim();
      }
    }

    final resId = _isResourceScope ? _targetResourceName : (sampleItem?.resourceId ?? '');
    final compResId = sampleItem?.componentResourceId.isNotEmpty == true
        ? sampleItem!.componentResourceId
        : resId;
    final subUnit = sampleItem?.subUnit.isNotEmpty == true
        ? sampleItem!.subUnit
        : (_unit.name.isNotEmpty ? _unit.name : _unit.id);
    final deptType = sampleItem?.deptType.isNotEmpty == true
        ? sampleItem!.deptType
        : (_isResourceScope ? 'MAIN LINE' : '');
    final pickDate = sampleItem?.pickDate ?? '';
    final prodDate = sampleItem?.prodDate ?? '';
    final uom = sampleItem != null && sampleItem.uom != 'NA' ? sampleItem.uom : 'EA';

    final newItem = await widget.dbService.recordManualPick(
      unitId: _unit.id,
      sessionId: sessionId,
      workerName: workerName,
      department: dept,
      workOrder: workOrder,
      partId: partId,
      qtyPicked: qty,
      note: note,
      line: line,
      resourceId: resId,
      componentResourceId: compResId,
      subUnit: subUnit,
      deptType: deptType,
      pickDate: pickDate,
      prodDate: prodDate,
      uom: uom,
    );

    // Also record in session_picks so it appears in session metrics
    if (sessionId.isNotEmpty) {
      await widget.dbService.recordSessionPick(
        sessionId: sessionId,
        unitId: _unit.id,
        itemId: newItem.id,
        partId: partId,
        qtyPickedDelta: qty,
      );
      final pickedCount = await widget.dbService.getSessionPickedPartCount(sessionId);
      await widget.dbService.updateSessionProgress(sessionId, pickedCount);
      if (mounted) {
        setState(() {
          _session = _session?.copyWith(totalItemsPicked: pickedCount);
        });
      }
    }

    final updatedItems = await widget.dbService.getPicklistItems(_unit.id);
    final updatedUnit = (await widget.dbService.getUnit(_unit.id)) ?? _unit;
    final newSummary = PartSummary.fromItem(newItem);

    if (mounted) {
      setState(() {
        _items = updatedItems;
        _unit = updatedUnit;
        _currentParts = [..._currentParts, newSummary];
        _currentIndex = _currentParts.length - 1;
      });
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Manually added: $partId × ${PicklistItem.formatQty(qty)} PCS'),
          backgroundColor: const Color(0xFFBB86FC),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    widget.onItemsUpdated?.call(updatedItems);
  }

  // ---------------------------------------------------------------------------
  // REMOVE FROM PICKING
  // ---------------------------------------------------------------------------

  /// Shows the Remove from Picking dialog with a mandatory comment.
  Future<void> _showRemoveFromPickingDialog(PartSummary part) async {
    final commentController = TextEditingController();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlgState) {
          final commentLen = commentController.text.trim().length;
          final isCommentOk = commentLen >= 10;

          return AlertDialog(
            backgroundColor: AppTheme.cardDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(children: [
              Icon(Icons.block_rounded, color: Colors.grey, size: 22),
              SizedBox(width: 8),
              Flexible(
                child: Text('Remove from Picking', style: TextStyle(color: AppTheme.textLight, fontSize: 17)),
              ),
            ]),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Part info
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.bgDark,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade700),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(part.partId, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textLight, letterSpacing: 1.1)),
                          if (part.description.isNotEmpty)
                            Text(part.description, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'This part will be greyed out across all views. The picking remains visible but excluded from active progress.',
                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: commentController,
                      autofocus: true,
                      keyboardType: TextInputType.multiline,
                      minLines: 2,
                      maxLines: 5,
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 14),
                      decoration: const InputDecoration(
                        labelText: 'Reason for removal (min 10 characters) *',
                        labelStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        hintText: 'Why is this part removed from picking?',
                        hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        filled: true,
                        fillColor: AppTheme.bgDark,
                      ),
                      onChanged: (_) => setDlgState(() {}),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(
                        isCommentOk ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                        size: 14,
                        color: isCommentOk ? AppTheme.statusComplete : AppTheme.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isCommentOk ? '$commentLen/10 chars — OK' : '$commentLen/10 min chars required',
                        style: TextStyle(fontSize: 11, color: isCommentOk ? AppTheme.statusComplete : AppTheme.textMuted),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isCommentOk ? Colors.grey.shade700 : AppTheme.bgDark,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.block_rounded, size: 18),
                label: const Text('Remove from Picking', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: isCommentOk
                    ? () async {
                        Navigator.of(ctx).pop();
                        await _commitRemoveFromPicking(part, commentController.text.trim());
                      }
                    : null,
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _commitRemoveFromPicking(PartSummary part, String comment) async {
    final workerName = _session?.workerName ?? widget.activeSession?.workerName ?? 'Picker';
    final dept = _isResourceScope ? null : widget.department;
    final resId = _isResourceScope ? _targetResourceName : null;

    await widget.dbService.recordPartRemoval(
      unitId: _unit.id,
      partId: part.partId,
      workerName: workerName,
      reason: comment,
      department: dept,
      resourceId: resId,
    );
    if (mounted) {
      setState(() {
        _removedFromPickingParts.add(part.partId);
        _removedPartComments[part.partId] = comment;
        _inputBuffer = '';
        // If part is removed from picking, it is immediately removed from Pick Mode
        _currentParts.removeWhere((p) => p.partId.toUpperCase() == part.partId.toUpperCase());
        if (_currentIndex >= _currentParts.length) {
          _currentIndex = _currentParts.isEmpty ? 0 : _currentParts.length - 1;
        }
        if (_currentParts.isNotEmpty && _pageController.hasClients) {
          _pageController.jumpToPage(_currentIndex);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${part.partId} marked as Removed from Picking'),
          backgroundColor: const Color(0xFF757575),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    final updatedItems = await widget.dbService.getPicklistItems(_unit.id);
    if (mounted) {
      setState(() {
        _items = updatedItems;
      });
    }
    widget.onItemsUpdated?.call(updatedItems);
    LogService.picker('REMOVED FROM PICKING: ${part.partId} in ${dept ?? resId ?? "all"} — "$comment" by $workerName');
  }

  // ---------------------------------------------------------------------------
  // REPLACE PART ID
  // ---------------------------------------------------------------------------

  /// Shows the Replace Part ID dialog.
  /// New Part ID: uppercase only, A-Z and 0-9, no spaces or special characters.
  Future<void> _showReplacePartIdDialog(PartSummary part) async {
    if (part.isManualAdd) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Manually added parts cannot be replaced. They can only be removed or returned.'),
            backgroundColor: AppTheme.statusDanger,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final newIdController = TextEditingController();
    final noteController = TextEditingController();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlgState) {
          final scopePartIds = _items
              .where((i) => _itemMatchesScope(i))
              .map((i) => i.partId.trim().toUpperCase())
              .toSet();
          final rawNew = newIdController.text.trim().toUpperCase();
          final isLengthOk = rawNew.length >= 8;
          // Only A-Z and 0-9 allowed, no spaces or special chars
          final isValidPartId = RegExp(r'^[A-Z0-9]+$').hasMatch(rawNew);
          final noteLen = noteController.text.trim().length;
          final isNoteOk = noteLen >= 10;
          final isDifferent = rawNew.isNotEmpty && rawNew.toUpperCase() != part.partId.toUpperCase();
          final isDuplicate = rawNew.isNotEmpty && scopePartIds.contains(rawNew);
          final canConfirm = isValidPartId && isLengthOk && isDifferent && !isDuplicate && isNoteOk;

          return AlertDialog(
            backgroundColor: AppTheme.cardDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(children: [
              Icon(Icons.find_replace_rounded, color: Color(0xFFAB47BC), size: 22),
              SizedBox(width: 8),
              Text('Replace Part ID', style: TextStyle(color: AppTheme.textLight, fontSize: 17)),
            ]),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Current Part ID (read-only)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.bgDark,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderDark),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.label_off_rounded, size: 16, color: AppTheme.textMuted),
                          const SizedBox(width: 6),
                          const Text('Current: ', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                          Expanded(
                            child: Text(
                              part.partId,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textLight, letterSpacing: 1.1),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // New Part ID input
                    TextField(
                      controller: newIdController,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      style: const TextStyle(
                        color: Color(0xFFCE93D8),
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.3,
                      ),
                      decoration: InputDecoration(
                        labelText: 'New Part ID (min 8 chars) *',
                        labelStyle: const TextStyle(color: AppTheme.textMuted),
                        hintText: 'UPPERCASE, digits only',
                        hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                        filled: true,
                        fillColor: AppTheme.bgDark,
                        errorText: isDuplicate
                            ? 'Part ID already exists in this ${_isResourceScope ? "Resource" : "Department"}'
                            : (rawNew.isNotEmpty && !isValidPartId
                                ? 'Only A-Z and 0-9 allowed, no spaces or special chars'
                                : (rawNew.isNotEmpty && !isLengthOk
                                    ? '${rawNew.length}/8 min characters required'
                                    : null)),
                        helperText: rawNew.isNotEmpty && isValidPartId && isLengthOk
                            ? '${rawNew.length} chars — OK'
                            : null,
                        errorStyle: const TextStyle(color: AppTheme.statusDanger, fontSize: 11),
                      ),
                      inputFormatters: [
                        // Filter non-alphanumeric characters in real-time
                        _UpperAlphanumericInputFormatter(),
                      ],
                      onChanged: (_) => setDlgState(() {}),
                    ),
                    if (isValidPartId && isDifferent) ...[
                      const SizedBox(height: 6),
                      Row(children: [
                        const Icon(Icons.arrow_forward_rounded, size: 14, color: Color(0xFFCE93D8)),
                        const SizedBox(width: 4),
                        Text('Will replace: ${part.partId} → $rawNew',
                            style: const TextStyle(fontSize: 11, color: Color(0xFFCE93D8))),
                      ]),
                    ],
                    const SizedBox(height: 8),
                    const Text(
                      'The original Part ID will be preserved in the export file.',
                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 12),
                    // Mandatory note
                    TextField(
                      controller: noteController,
                      keyboardType: TextInputType.multiline,
                      minLines: 2,
                      maxLines: 5,
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 14),
                      decoration: const InputDecoration(
                        labelText: 'Reason for replacement (min 10 characters) *',
                        labelStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        hintText: 'Why is this Part ID being replaced?',
                        hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        filled: true,
                        fillColor: AppTheme.bgDark,
                      ),
                      onChanged: (_) => setDlgState(() {}),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(
                        isNoteOk ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                        size: 14,
                        color: isNoteOk ? AppTheme.statusComplete : AppTheme.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isNoteOk ? '$noteLen/10 chars — OK' : '$noteLen/10 min chars required',
                        style: TextStyle(fontSize: 11, color: isNoteOk ? AppTheme.statusComplete : AppTheme.textMuted),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: canConfirm ? const Color(0xFFAB47BC) : AppTheme.bgDark,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.find_replace_rounded, size: 18),
                label: const Text('Replace Part ID', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: canConfirm
                    ? () async {
                        Navigator.of(ctx).pop();
                        await _commitReplacePartId(
                          oldPartId: part.partId,
                          newPartId: newIdController.text.trim().toUpperCase(),
                          note: noteController.text.trim(),
                        );
                      }
                    : null,
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _commitReplacePartId({
    required String oldPartId,
    required String newPartId,
    required String note,
  }) async {
    final sessionId = _session?.id ?? '';
    final workerName = _session?.workerName ?? widget.activeSession?.workerName ?? 'Picker';
    final dept = _isResourceScope ? null : widget.department;
    final resId = _isResourceScope ? _targetResourceName : null;

    final matchingItemIds = _items
        .where((i) => i.partId.toLowerCase().trim() == oldPartId.toLowerCase().trim() && _itemMatchesScope(i))
        .map((i) => i.id)
        .toList();

    await widget.dbService.recordPartIdReplacement(
      unitId: _unit.id,
      sessionId: sessionId,
      workerName: workerName,
      oldPartId: oldPartId,
      newPartId: newPartId,
      note: note,
      department: dept,
      resourceId: resId,
      targetItemIds: matchingItemIds.isNotEmpty ? matchingItemIds : null,
    );

    // Reload items from DB to get updated Part IDs
    final updatedItems = await widget.dbService.getPicklistItems(_unit.id);
    if (mounted) {
      setState(() {
        _items = updatedItems;
        _inputBuffer = '';
        // Rebuild replaced map
        _replacedPartIds.clear();
        for (final item in updatedItems) {
          if (item.replacedPartId.isNotEmpty) {
            _replacedPartIds[item.partId] = item.replacedPartId;
          }
        }
        // Update part summaries to show the new Part ID with refreshed data
        final newMatchingItems = updatedItems
            .where((i) => i.partId.toUpperCase() == newPartId.toUpperCase() && _itemMatchesScope(i))
            .toList();
        if (newMatchingItems.isNotEmpty) {
          var refreshedSummary = PartSummary.fromItem(newMatchingItems.first);
          for (int j = 1; j < newMatchingItems.length; j++) {
            refreshedSummary = refreshedSummary.add(newMatchingItems[j]);
          }
          for (int i = 0; i < _currentParts.length; i++) {
            if (_currentParts[i].partId.toUpperCase() == oldPartId.toUpperCase()) {
              _currentParts[i] = refreshedSummary;
            }
          }
        } else {
          for (int i = 0; i < _currentParts.length; i++) {
            if (_currentParts[i].partId.toUpperCase() == oldPartId.toUpperCase()) {
              _currentParts[i] = _currentParts[i].copyWith(
                partId: newPartId,
                replacedPartId: oldPartId,
                replacementNote: note,
              );
            }
          }
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Part ID replaced: $oldPartId → $newPartId'),
          backgroundColor: const Color(0xFF00E5FF),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    widget.onItemsUpdated?.call(updatedItems);
  }

  // ---------------------------------------------------------------------------
  // PICKER NOTE (Free-form note on any part)
  // ---------------------------------------------------------------------------

  /// Shows the free-form Picker Note dialog for any part.
  Future<void> _showPickerNoteDialog(PartSummary part) async {
    final existingNote = _userPartNotes[part.partId] ?? '';
    final controller = TextEditingController(text: existingNote);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlgState) {
          final noteText = controller.text.trim();
          final hasChanged = noteText != existingNote;

          return AlertDialog(
            backgroundColor: AppTheme.cardDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.comment_rounded, color: Color(0xFF00E5FF), size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Picker Note: ${part.partId}',
                    style: const TextStyle(color: AppTheme.textLight, fontSize: 17, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (part.description.isNotEmpty) ...[
                      Text(part.description, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                      const SizedBox(height: 10),
                    ],
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.multiline,
                      minLines: 3,
                      maxLines: 6,
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 15),
                      decoration: const InputDecoration(
                        labelText: 'Add Note / Comment',
                        labelStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                        hintText: 'Type any note or observation for this part...',
                        hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        filled: true,
                        fillColor: AppTheme.bgDark,
                      ),
                      onChanged: (_) => setDlgState(() {}),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (existingNote.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded, size: 16, color: AppTheme.statusDanger),
                  label: const Text('Clear Note', style: TextStyle(color: AppTheme.statusDanger)),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await widget.dbService.setUserPartNote(
                      unitId: _unit.id,
                      partId: part.partId,
                      note: '',
                      department: _isResourceScope ? '' : widget.department,
                    );
                    if (mounted) {
                      setState(() {
                        _userPartNotes.remove(part.partId);
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Cleared note for ${part.partId}'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              TextButton(
                child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                ),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Save Note', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: hasChanged
                    ? () async {
                        Navigator.of(ctx).pop();
                        await widget.dbService.setUserPartNote(
                          unitId: _unit.id,
                          partId: part.partId,
                          note: noteText,
                          department: _isResourceScope ? '' : widget.department,
                        );
                        if (mounted) {
                          setState(() {
                            if (noteText.isEmpty) {
                              _userPartNotes.remove(part.partId);
                            } else {
                              _userPartNotes[part.partId] = noteText;
                            }
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Note saved for ${part.partId}'),
                              backgroundColor: const Color(0xFF00E5FF),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      }
                    : null,
              ),
            ],
          );
        });
      },
    );
  }

  @override

  Widget build(BuildContext context) {
    if (_currentParts.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            iconSize: 26,
            onPressed: () {
              if (widget.onFinished != null) {
                widget.onFinished!();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          title: const Text('Pick Mode'),
        ),
        body: const Center(
          child: Text('No parts available to pick for this department.',
              style: TextStyle(color: AppTheme.textMuted)),
        ),
      );
    }

    final totalCount = _currentParts.length;
    final currentSummary = _currentParts[_currentIndex.clamp(0, totalCount - 1)];

    // If confirmation overlay is shown, display it instead of normal content
    if (_showConfirm) {
      return _buildConfirmationOverlay(currentSummary);
    }

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // Header bar with back button, session/tablet info
                _buildHeader(totalCount),

                // Upper Section: Part Card (Page View with swipe gestures disabled)
                Expanded(
                  flex: 5,
                  child: PageView.builder(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (idx) {
                      if (mounted) {
                        setState(() {
                          _currentIndex = idx;
                          _inputBuffer = '';
                        });
                      }
                    },
                    itemCount: totalCount,
                    itemBuilder: (context, index) {
                      return _buildUpperPartCard(_currentParts[index]);
                    },
                  ),
                ),

                // Lower Section: Touch Console
                Expanded(
                  flex: 5,
                  child: _buildLowerPickingConsole(currentSummary),
                ),

                // Bottom Navigation Strip
                _buildBottomNavigation(currentSummary),
              ],
            ),

            // Fully Picked Banner overlay
            if (_showFullyPickedBanner)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildFullyPickedBanner(),
              ),
          ],
        ),
      ),
    );
  }

  /// Confirmation overlay — shown after tapping "Confirm Pick" button.
  Widget _buildConfirmationOverlay(PartSummary part) {
    final currentPicked = _getCurrentPicked(part.partId);
    final requiredQty = _getRequiredQty(part.partId);
    final dueAfterPick = (_getDueQty(part.partId) - _pendingDelta).clamp(0.0, requiredQty);
    final pickedAfterConfirm = currentPicked + _pendingDelta;

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  decoration: BoxDecoration(
                    color: AppTheme.statusComplete.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.statusComplete.withValues(alpha: 0.4), width: 2),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.check_circle_outline_rounded, size: 64, color: AppTheme.statusComplete),
                      const SizedBox(height: 16),
                      const Text(
                        'Confirm Pick',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                      ),
                      const SizedBox(height: 24),
                      // Part ID
                      Text(
                        part.partId,
                        style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: AppTheme.accentCyan, letterSpacing: 1.2),
                        textAlign: TextAlign.center,
                      ),
                      Builder(builder: (_) {
                        final onHandStr = _resolveOnHand(part);
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              if (part.description.isNotEmpty)
                                Text(
                                  part.description,
                                  style: const TextStyle(fontSize: 14, color: AppTheme.textMuted),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: onHandStr.isNotEmpty
                                      ? AppTheme.accentCyan.withValues(alpha: 0.15)
                                      : AppTheme.cardDark.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: onHandStr.isNotEmpty
                                        ? AppTheme.accentCyan.withValues(alpha: 0.4)
                                        : AppTheme.borderDark,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.location_on_rounded,
                                      size: 12,
                                      color: onHandStr.isNotEmpty ? AppTheme.accentCyan : AppTheme.textMuted,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      onHandStr.isNotEmpty ? 'ON-HAND: $onHandStr' : 'ON-HAND: —',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: onHandStr.isNotEmpty ? AppTheme.accentCyan : AppTheme.textMuted,
                                        fontWeight: onHandStr.isNotEmpty ? FontWeight.bold : FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 14),
                      Builder(builder: (_) {
                        final matchingItems = _items
                            .where((i) => _itemMatchesScope(i) && i.partId.toLowerCase().trim() == part.partId.toLowerCase().trim())
                            .toList()
                          ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));
                        final item = matchingItems.isNotEmpty
                            ? matchingItems.first
                            : _items.firstWhere(
                                (i) => i.partId.toLowerCase().trim() == part.partId.toLowerCase().trim(),
                                orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0),
                              );
                        final allDepts = matchingItems
                            .map((i) => i.department.trim())
                            .where((d) => d.isNotEmpty)
                            .toSet()
                            .toList();
                        final allLines = matchingItems
                            .map((i) => i.line.trim())
                            .where((l) => l.isNotEmpty)
                            .toSet()
                            .toList();
                        final lineStr = item.line.isNotEmpty ? item.line : (widget.lineLabel ?? 'General');
                        final resStr = item.resourceId.isNotEmpty ? item.resourceId : (part.resourceId.isNotEmpty ? part.resourceId : '');
                        final showMultipleDepts = _isResourceScope || allDepts.length > 1;

                        // Simulate FIFO allocation with _pendingDelta to preview post-confirm quantities per department/WO
                        final currentPicked = _getCurrentPicked(part.partId);
                        final simulatedList = _pendingDelta > 0
                            ? FifoAllocationEngine.allocateByPartId(
                                allItems: _items,
                                department: widget.department,
                                partId: part.partId,
                                totalPickedToAllocate: currentPicked + _pendingDelta,
                              )
                            : _items;

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _infoChip(Icons.inventory_2_rounded, 'Unit: ${_unit.name}'),
                                _infoChip(Icons.straighten_rounded, 'UOM: ${part.uom}'),
                                _infoChip(Icons.apartment_rounded, _isResourceScope ? 'Scope: ${widget.department}' : 'Dept: ${widget.department}'),
                                if (showMultipleDepts && allDepts.isNotEmpty)
                                  for (final d in allDepts)
                                    _infoChip(Icons.domain_rounded, 'Dept: $d')
                                else if (!showMultipleDepts && item.department.isNotEmpty && item.department != widget.department)
                                  _infoChip(Icons.domain_rounded, 'Dept: ${item.department}'),
                                if (!_isResourceScope) ...[
                                  if (allLines.isNotEmpty)
                                    for (final l in allLines)
                                      _infoChip(Icons.view_week_rounded, 'Line: $l')
                                  else if (lineStr.isNotEmpty && lineStr != 'General')
                                    _infoChip(Icons.view_week_rounded, 'Line: $lineStr'),
                                ],
                                if (resStr.isNotEmpty) _infoChip(Icons.account_tree_rounded, 'Resource: $resStr'),
                              ],
                            ),
                            if (matchingItems.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              Text(
                                showMultipleDepts ? 'Work Orders & Departments:' : 'Work Orders:',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 6,
                                runSpacing: 4,
                                children: matchingItems.map((wo) {
                                  final simWo = simulatedList.firstWhere((i) => i.id == wo.id, orElse: () => wo);
                                  final isAllocated = _pendingDelta > 0 && simWo.qtyPicked > wo.qtyPicked;
                                  final isCompleteAfterConfirm = simWo.qtyDue <= 0.0001;
                                  final woColor = isCompleteAfterConfirm ? AppTheme.statusComplete : AppTheme.statusPartial;

                                  final qtyText = isAllocated
                                      ? '${PicklistItem.formatQty(wo.qtyPicked)} → ${PicklistItem.formatQty(simWo.qtyPicked)}/${PicklistItem.formatQty(wo.qtyRequired)}'
                                      : '${PicklistItem.formatQty(wo.qtyPicked)}/${PicklistItem.formatQty(wo.qtyRequired)}';

                                  final label = showMultipleDepts
                                      ? '${wo.workOrder} (${wo.department}): $qtyText'
                                      : '${wo.workOrder}: $qtyText';
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: AppTheme.bgDark,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: woColor.withValues(alpha: 0.5)),
                                    ),
                                    child: Text(
                                      label,
                                      style: TextStyle(fontSize: 11, color: woColor, fontWeight: FontWeight.w600),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ],
                        );
                      }),
                      const SizedBox(height: 18),
                      const Divider(color: AppTheme.borderDark),
                      const SizedBox(height: 16),
                      // Summary table
                      _confirmRow('Picking (delta):', '+${PartSummary.formatQty(_pendingDelta)} ${part.uomLabel}', AppTheme.statusComplete),
                      const SizedBox(height: 10),
                      _confirmRow('Picked after confirm:', '${PartSummary.formatQty(pickedAfterConfirm)} ${part.uomLabel}', AppTheme.textLight),
                      const SizedBox(height: 10),
                      _confirmRow('Remaining Due:', '${PartSummary.formatQty(dueAfterPick)} ${part.uomLabel}',
                          dueAfterPick <= 0.0001 ? AppTheme.statusComplete : AppTheme.statusPartial),
                      const SizedBox(height: 10),
                      _confirmRow('Total Required:', '${PartSummary.formatQty(requiredQty)} ${part.uomLabel}', AppTheme.textMuted),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: const BorderSide(color: AppTheme.borderDark),
                        foregroundColor: AppTheme.textMuted,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      label: const Text('Cancel', style: TextStyle(fontSize: 15)),
                      onPressed: () => setState(() {
                        _showConfirm = false;
                        _pendingDelta = 0.0;
                      }),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.statusComplete,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.check_rounded, size: 22),
                      label: Text(
                        'Save +${PartSummary.formatQty(_pendingDelta)} ${part.uomLabel}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      onPressed: () async {
                        final part = _currentParts[_currentIndex.clamp(0, _currentParts.length - 1)];
                        await _commitPick(part, _pendingDelta);
                        // Auto-advance and banner are handled inside _commitPick
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

  Widget _confirmRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textMuted)),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: valueColor)),
      ],
    );
  }

  Widget _buildHeader(int totalCount) {
    final session = _session ?? widget.activeSession;
    final isAtEnd = _currentIndex == _currentParts.length - 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: AppTheme.cardDark,
        border: Border(bottom: BorderSide(color: AppTheme.borderDark)),
      ),
      child: Row(
        children: [
          // Large back button — consistent with other screens
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton.filledTonal(
              icon: const Icon(Icons.arrow_back_rounded, size: 22),
              tooltip: 'Back to List',
              style: IconButton.styleFrom(
                backgroundColor: AppTheme.bgDark,
                foregroundColor: AppTheme.textLight,
              ),
              onPressed: () {
                if (widget.onFinished != null) {
                  widget.onFinished!();
                } else {
                  Navigator.of(context).maybePop();
                }
              },
            ),
          ),
          const SizedBox(width: 12),
          // Department + Line + Part counter
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Builder(builder: (_) {
                  String? subLabel;
                  if (widget.lineLabel != null && widget.lineLabel!.isNotEmpty) {
                    final raw = widget.lineLabel!.trim();
                    if (_isResourceScope) {
                      // In Whole Resource mode, no lines exist.
                      // If picking a specific department within the resource (By-Dept mode), show Dept: ...
                      if (raw.toLowerCase().startsWith('department:')) {
                        subLabel = raw;
                      } else if (raw.toLowerCase().startsWith('dept:')) {
                        subLabel = raw;
                      } else if (!raw.toLowerCase().contains('resource')) {
                        subLabel = 'Dept: $raw';
                      }
                      // Omits 'Resource ID: ...' or 'Resource: ...' since widget.department already displays the resource!
                    } else {
                      // In department mode, show Line: ...
                      if (raw.toLowerCase().startsWith('line:')) {
                        subLabel = raw;
                      } else {
                        subLabel = 'Line: $raw';
                      }
                    }
                  }

                  return Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.department,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (subLabel != null && subLabel.isNotEmpty) ...[
                        const Text(' › ', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                        Flexible(
                          child: Text(
                            subLabel,
                            style: const TextStyle(fontSize: 13, color: AppTheme.accentCyan, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      const Text(' — Pick Mode', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                    ],
                  );
                }),
                if (session != null)
                  Text(
                    'Picker: ${session.workerName}${session.sessionSeqNo > 0 ? ' | Session #${session.sessionSeqNo}' : ''}${widget.tabletId.isNotEmpty ? ' | ${widget.tabletId}' : ''}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  ),
              ],
            ),
          ),
          // Part N of M (red tint at end)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isAtEnd ? AppTheme.statusDanger.withValues(alpha: 0.15) : AppTheme.cardDark,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isAtEnd ? AppTheme.statusDanger.withValues(alpha: 0.5) : AppTheme.borderDark),
            ),
            child: Text(
              isAtEnd ? 'End of list' : 'Part ${_currentIndex + 1} of $totalCount',
              style: TextStyle(
                fontSize: 12,
                color: isAtEnd ? AppTheme.statusDanger : AppTheme.accentCyan,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (_autoAdvance) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'Auto-Advance: automatically advances to next part on pick',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.statusComplete.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppTheme.statusComplete.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt_rounded, size: 13, color: AppTheme.statusComplete),
                    SizedBox(width: 4),
                    Text('Auto-Advance', style: TextStyle(fontSize: 10, color: AppTheme.statusComplete, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _commitReturnInScreen(PartSummary part) async {
    final returnQty = double.tryParse(_returnInputBuffer.trim()) ?? 0.0;
    final currentPicked = _getCurrentPicked(part.partId);
    if (returnQty <= 0.0001 || returnQty > currentPicked + 0.0001) return;
    final reason = _returnReasonController.text.trim();
    if (reason.length < 10) return;

    final pickerName = widget.activeSession?.workerName ?? 'Picker';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final newAllocated = (currentPicked - returnQty).clamp(0.0, double.infinity);
    final updatedList = FifoAllocationEngine.allocateByPartId(
      allItems: _items,
      department: widget.department,
      partId: part.partId,
      totalPickedToAllocate: newAllocated,
    );

    await widget.dbService.insertPickReturn(
      sessionId: widget.activeSession?.id ?? '',
      unitId: _unit.id,
      workerName: pickerName,
      partId: part.partId,
      department: widget.department,
      qtyReturned: returnQty,
      comment: reason,
    );

    await widget.dbService.batchUpdateItems(updatedList);
    final newTotalPicked = updatedList.fold<double>(0.0, (sum, i) => sum + i.qtyPicked).round();
    final updatedUnit = _unit.copyWith(totalPicked: newTotalPicked, lastAccessedAt: nowMs);
    await widget.dbService.updateUnit(updatedUnit);

    setState(() {
      _items = updatedList;
      _unit = updatedUnit;
      _isReturnMode = false;
      _returnInputBuffer = '';
      _returnReasonController.clear();
    });

    widget.onItemsUpdated?.call(updatedList);
    LogService.picker('RETURN: ${part.partId} -${PartSummary.formatQty(returnQty)} ${part.uomLabel} (Reason: "$reason") → Unit: ${_unit.name}, Dept: ${widget.department}');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Returned ${PartSummary.formatQty(returnQty)} ${part.uomLabel} of ${part.partId}.'),
          backgroundColor: const Color(0xFFE07B00),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Widget _buildUpperReturnCard(PartSummary part) {
    final currentPicked = _getCurrentPicked(part.partId);
    final returnDelta = double.tryParse(_returnInputBuffer.trim()) ?? 0.0;
    final remainingAfterReturn = (currentPicked - returnDelta).clamp(0.0, currentPicked);
    final pickerName = widget.activeSession?.workerName ?? 'Picker';
    final len = _returnReasonController.text.trim().length;
    final isReasonOk = len >= 10;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFE07B00).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFFE07B00),
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE07B00).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE07B00)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.replay_rounded, size: 16, color: Color(0xFFE07B00)),
                      SizedBox(width: 6),
                      Text('RETURN MODE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFE07B00))),
                    ],
                  ),
                ),
                const Spacer(),
                Text('Picker: $pickerName', style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    part.partId,
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: AppTheme.textLight),
                  ),
                ),
                Text(
                  'Picked: ${PartSummary.formatQty(currentPicked)} ${part.uomLabel}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Remaining after return: ${PartSummary.formatQty(remainingAfterReturn)} ${part.uomLabel}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: returnDelta > 0.0001 ? const Color(0xFFE07B00) : AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _returnReasonController,
              focusNode: _returnReasonFocusNode,
              autofocus: true,
              keyboardType: TextInputType.multiline,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(color: AppTheme.textLight, fontSize: 15),
              decoration: InputDecoration(
                labelText: 'Reason for Return (min 10 characters)*',
                labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                hintText: 'Explain why parts are being returned...',
                hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                filled: true,
                fillColor: AppTheme.bgDark,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.borderDark)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE07B00), width: 1.8)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  isReasonOk ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                  size: 16,
                  color: isReasonOk ? AppTheme.statusComplete : AppTheme.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  isReasonOk ? '$len/10 characters — OK' : '$len/10 min characters required',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isReasonOk ? FontWeight.bold : FontWeight.normal,
                    color: isReasonOk ? AppTheme.statusComplete : AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpperPartCard(PartSummary part) {
    if (_isReturnMode) {
      return _buildUpperReturnCard(part);
    }
    final currentPicked = _getCurrentPicked(part.partId);
    final requiredQty = _getRequiredQty(part.partId);
    final dueQty = _getDueQty(part.partId);

    final isComplete = dueQty <= 0.0001 && requiredQty > 0;
    final isMissing = _flaggedMissingParts.contains(part.partId);
    final isRemoved = _removedFromPickingParts.contains(part.partId);
    final originalPartId = _replacedPartIds[part.partId];

    final progress = requiredQty > 0 ? (currentPicked / requiredQty).clamp(0.0, 1.0) : 0.0;

    final statusColor = isMissing
        ? AppTheme.statusDanger
        : isComplete
            ? AppTheme.statusComplete
            : currentPicked > 0
                ? AppTheme.statusPartial
                : AppTheme.statusUnpicked;

    // ON_HAND info
    final onHand = _resolveOnHand(part);

    // Work Orders info — list per WO with quantities
    final woItems = _items
        .where((i) => _itemMatchesScope(i) && i.partId.toLowerCase().trim() == part.partId.toLowerCase().trim())
        .toList()
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));
    final allLines = woItems
        .map((i) => i.line.trim())
        .where((l) => l.isNotEmpty)
        .toSet()
        .toList();

    // Pick/Prod dates from items (formatted without seconds/ISO)
    final pickDateRaw = woItems.firstWhere((i) => i.pickDate.isNotEmpty,
        orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0)).pickDate;
    final prodDateRaw = woItems.firstWhere((i) => i.prodDate.isNotEmpty,
        orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0)).prodDate;
    final pickDate = UnitPickDateUrgency.formatShortDate(pickDateRaw);
    final prodDate = UnitPickDateUrgency.formatShortDate(prodDateRaw);

    // dept_type from item
    final deptType = woItems.isNotEmpty ? woItems.first.deptType : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: isMissing ? AppTheme.statusDanger.withValues(alpha: 0.1) : AppTheme.cardDark,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isMissing ? AppTheme.statusDanger : AppTheme.borderDark,
            width: isMissing ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: Status badge + ON-HAND + dept type
            Row(
              children: [
                _statusChip(isMissing, isComplete, currentPicked, statusColor),
                const Spacer(),
                if (deptType.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: deptType == 'MAIN LINE'
                            ? const Color(0xFF0EA5E9).withValues(alpha: 0.15)
                            : const Color(0xFFF97316).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: deptType == 'MAIN LINE'
                              ? const Color(0xFF0EA5E9).withValues(alpha: 0.5)
                              : const Color(0xFFF97316).withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        deptType,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: deptType == 'MAIN LINE'
                              ? const Color(0xFF0EA5E9)
                              : const Color(0xFFF97316),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Row 2: Part ID + Description
            SelectableText(
              part.partId,
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: isRemoved ? Colors.grey.shade500 : AppTheme.textLight,
              ),
            ),
            // MANUAL ADD badge
            if (part.isManualAdd) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFBB86FC).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFBB86FC).withValues(alpha: 0.6)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add_circle_outline_rounded, size: 12, color: Color(0xFFBB86FC)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '➕ MANUAL ADD${part.manualWorker.isNotEmpty ? ' • by ${part.manualWorker}' : ''}${part.manualNote.isNotEmpty ? ': "${part.manualNote}"' : ''}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFFBB86FC), fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Replaced Part ID badge
            if ((originalPartId != null && originalPartId.isNotEmpty) || part.replacedPartId.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.find_replace_rounded, size: 12, color: Color(0xFF00E5FF)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '🔄 REPLACED • was: ${part.replacedPartId.isNotEmpty ? part.replacedPartId : originalPartId}${part.replacementNote.isNotEmpty ? ' (${part.replacementNote})' : ''}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF00E5FF), fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // REMOVED FROM PICKING badge
            if (isRemoved || part.isRemoved) ...[
              const SizedBox(height: 4),
              Builder(builder: (_) {
                final reason = part.removeNote.isNotEmpty
                    ? part.removeNote
                    : (_removedPartComments[part.partId] ?? '');
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF757575).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF757575).withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.block_rounded, size: 12, color: Color(0xFF757575)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '⛔ REMOVED FROM PICKING${reason.isNotEmpty ? ' • $reason' : ''}',
                          style: const TextStyle(fontSize: 11, color: Color(0xFF757575), fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
            // MISSING badge
            if (isMissing) ...[
              const SizedBox(height: 4),
              Builder(builder: (_) {
                final flag = _missingPartDetails[part.partId];
                final ts = flag?['created_at'] as int?;
                final dateStr = ts != null
                    ? DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(ts))
                    : '';
                final note = flag?['note']?.toString() ?? '';
                String pickerName = flag?['worker_name']?.toString() ?? '';
                if (pickerName.isEmpty) {
                  if (note.contains('Marked missing by ')) {
                    pickerName = note.replaceAll('Marked missing by ', '').replaceAll(' in Pick Mode', '').trim();
                  } else if (note.isNotEmpty) {
                    pickerName = note;
                  } else {
                    pickerName = 'Picker';
                  }
                }
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFFF3B30).withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.warning_amber_rounded, size: 12, color: Color(0xFFFF3B30)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '⚠️ MISSING • $pickerName${dateStr.isNotEmpty ? ' • $dateStr' : ''}',
                          style: const TextStyle(fontSize: 11, color: Color(0xFFFF3B30), fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
            // Picker Note badge
            Builder(builder: (_) {
              final userNote = _userPartNotes[part.partId] ?? '';
              if (userNote.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.comment_rounded, size: 13, color: Color(0xFF00E5FF)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Picker Note: $userNote',
                          style: const TextStyle(fontSize: 11, color: Color(0xFF00E5FF), fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => _showPickerNoteDialog(part),
                        child: const Icon(Icons.edit_rounded, size: 13, color: Color(0xFF00E5FF)),
                      ),
                    ],
                  ),
                ),
              );
            }),
            if (part.description.isNotEmpty &&
                !(part.isManualAdd &&
                    (part.description == part.manualNote ||
                        part.manualNote.isNotEmpty ||
                        part.description.isEmpty))) ...[
              const SizedBox(height: 6),
              Text(
                part.description,
                style: const TextStyle(fontSize: 15, color: AppTheme.textMuted, height: 1.2),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],

            // Dedicated ON-HAND Locations & Stock with Legal Disclaimer
            if (onHand.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warehouse_rounded, size: 16, color: AppTheme.accentCyan),
                        const SizedBox(width: 6),
                        const Text(
                          'ON-HAND LOCATIONS & INVENTORY',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.6,
                            color: AppTheme.accentCyan,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.cardDark,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppTheme.borderDark),
                          ),
                          child: const Text(
                            'Informational Only',
                            style: TextStyle(fontSize: 9, color: AppTheme.textMuted, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      onHand,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textLight,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),

            // Row 3: Unit + dates
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                _infoChip(Icons.inventory_2_rounded, 'Unit: ${widget.unit.name}'),
                _infoChip(Icons.straighten_rounded, 'UOM: ${part.uom}'),
                if (pickDate.isNotEmpty) _infoChip(Icons.event_available_rounded, 'Pick: $pickDate'),
                if (prodDate.isNotEmpty) _infoChip(Icons.precision_manufacturing_rounded, 'Prod: $prodDate'),
                if (part.resourceId.isNotEmpty) _infoChip(Icons.account_tree_rounded, 'Resource: ${part.resourceId}'),
                if (!_isResourceScope) ...[
                  if (allLines.isNotEmpty)
                    for (final l in allLines)
                      _infoChip(Icons.linear_scale_rounded, 'Line: $l')
                  else if (part.line.isNotEmpty)
                    _infoChip(Icons.linear_scale_rounded, 'Line: ${part.line}'),
                ],
                if (part.subUnit.isNotEmpty) _infoChip(Icons.view_in_ar_rounded, 'Sub-Unit: ${part.subUnit}'),
              ],
            ),
            const SizedBox(height: 10),

            // Row 4: Work Orders with quantities (per WO) — Collapsible when > 6
            if (woItems.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    _isResourceScope ? 'Work Orders & Departments:' : 'Work Orders:',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold),
                  ),
                  if (woItems.length > 6) ...[
                    const SizedBox(width: 8),
                    Text(
                      '(${woItems.length} total)',
                      style: const TextStyle(fontSize: 11, color: AppTheme.accentCyan, fontWeight: FontWeight.bold),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Builder(builder: (_) {
                final isExpanded = _expandedWoPartIds.contains(part.partId);
                final visibleWos = (woItems.length > 6 && !isExpanded) ? woItems.take(6).toList() : woItems;
                return Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ...visibleWos.map((wo) {
                      final woColor = wo.qtyDue <= 0.0001 ? AppTheme.statusComplete : AppTheme.statusPartial;
                      final label = _isResourceScope
                          ? '${wo.workOrder} (${wo.department}): ${PicklistItem.formatQty(wo.qtyPicked)}/${PicklistItem.formatQty(wo.qtyRequired)}'
                          : '${wo.workOrder}: ${PicklistItem.formatQty(wo.qtyPicked)}/${PicklistItem.formatQty(wo.qtyRequired)}';
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.bgDark,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: woColor.withValues(alpha: 0.5)),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(fontSize: 11, color: woColor, fontWeight: FontWeight.w600),
                        ),
                      );
                    }),
                    if (woItems.length > 6)
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          setState(() {
                            if (isExpanded) {
                              _expandedWoPartIds.remove(part.partId);
                            } else {
                              _expandedWoPartIds.add(part.partId);
                            }
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.cardDark,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.6)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isExpanded ? 'Show less ▴' : '+${woItems.length - 6} more ▾',
                                style: const TextStyle(fontSize: 11, color: AppTheme.accentCyan, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              }),
              const SizedBox(height: 10),
            ],

            // Row 5: Qty Stats + Progress bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _qtyColumn('PICKED', PartSummary.formatQty(currentPicked), statusColor),
                Container(width: 1, height: 40, color: AppTheme.borderDark),
                _qtyColumn('DUE', PartSummary.formatQty(dueQty), dueQty > 0.0001 ? AppTheme.statusPartial : AppTheme.textMuted),
                Container(width: 1, height: 40, color: AppTheme.borderDark),
                _qtyColumn('REQUIRED', PartSummary.formatQty(requiredQty), AppTheme.textLight),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: AppTheme.bgDark,
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(bool isMissing, bool isComplete, double currentPicked, Color statusColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isMissing
                ? Icons.warning_amber_rounded
                : isComplete
                    ? Icons.check_circle_rounded
                    : Icons.inventory_2_rounded,
            size: 15,
            color: statusColor,
          ),
          const SizedBox(width: 5),
          Text(
            isMissing
                ? 'FLAGGED MISSING'
                : isComplete
                    ? 'COMPLETED'
                    : currentPicked > 0
                        ? 'PARTIALLY PICKED'
                        : 'UNPICKED',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.0, color: statusColor),
          ),
        ],
      ),
    );
  }

  Widget _buildLowerPickingConsole(PartSummary part) {
    final currentPicked = _getCurrentPicked(part.partId);
    final dueQty = _getDueQty(part.partId);

    final delta = double.tryParse(_inputBuffer) ?? 0.0;
    final canConfirmPick = delta > 0.0001 && delta <= dueQty + 0.0001;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderDark),
      ),
      child: Row(
        children: [
          // Left side: Touch Keypad
          Expanded(
            flex: 5,
            child: Column(
              children: [
                Expanded(
                  child: Row(children: [
                    _buildKeypadKey('1'), _buildKeypadKey('2'), _buildKeypadKey('3'),
                  ]),
                ),
                Expanded(
                  child: Row(children: [
                    _buildKeypadKey('4'), _buildKeypadKey('5'), _buildKeypadKey('6'),
                  ]),
                ),
                Expanded(
                  child: Row(children: [
                    _buildKeypadKey('7'), _buildKeypadKey('8'), _buildKeypadKey('9'),
                  ]),
                ),
                Expanded(
                  child: Row(children: [
                    _buildKeypadKey('.', label: '.'),
                    _buildKeypadKey('0'),
                    _buildKeypadKey('⌫', label: '⌫', isAction: true),
                  ]),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Right side: Delta display + action buttons
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Delta input display / Return input display
                if (_isReturnMode) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.bgDark,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE07B00), width: 1.5),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('RETURN QUANTITY (DELTA):',
                                style: TextStyle(fontSize: 9, color: Color(0xFFE07B00), fontWeight: FontWeight.bold)),
                            Text(
                              '- ${_returnInputBuffer.isEmpty ? '0' : _returnInputBuffer} ${part.uomLabel}',
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFFE07B00)),
                            ),
                          ],
                        ),
                        if (_returnInputBuffer.isNotEmpty)
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: AppTheme.textMuted,
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            ),
                            icon: const Icon(Icons.clear_rounded, size: 14),
                            label: const Text('Clear', style: TextStyle(fontSize: 11)),
                            onPressed: () => _onKeypadTap('C'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.replay_rounded, size: 14, color: Color(0xFFE07B00)),
                        label: Text('All (${PartSummary.formatQty(currentPicked)})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFE07B00))),
                        backgroundColor: const Color(0xFFE07B00).withValues(alpha: 0.15),
                        side: const BorderSide(color: Color(0xFFE07B00)),
                        onPressed: () => setState(() => _returnInputBuffer = PartSummary.formatQty(currentPicked)),
                      ),
                      ActionChip(
                        label: const Text('+1', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentCyan)),
                        backgroundColor: AppTheme.bgDark,
                        side: const BorderSide(color: AppTheme.borderDark),
                        onPressed: () {
                          final cur = double.tryParse(_returnInputBuffer) ?? 0.0;
                          final next = (cur + 1.0).clamp(1.0, currentPicked);
                          setState(() => _returnInputBuffer = PartSummary.formatQty(next));
                        },
                      ),
                      if (currentPicked >= 5)
                        ActionChip(
                          label: const Text('+5', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentCyan)),
                          backgroundColor: AppTheme.bgDark,
                          side: const BorderSide(color: AppTheme.borderDark),
                          onPressed: () {
                            final cur = double.tryParse(_returnInputBuffer) ?? 0.0;
                            final next = (cur + 5.0).clamp(1.0, currentPicked);
                            setState(() => _returnInputBuffer = PartSummary.formatQty(next));
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 48),
                            side: const BorderSide(color: AppTheme.borderDark),
                            foregroundColor: AppTheme.textMuted,
                          ),
                          onPressed: () => setState(() {
                            _isReturnMode = false;
                            _returnInputBuffer = '';
                          }),
                          child: const Text('Cancel', style: TextStyle(fontSize: 14)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE07B00),
                            minimumSize: const Size(0, 48),
                          ),
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: Text(
                            'Confirm Return (-${PartSummary.formatQty(double.tryParse(_returnInputBuffer) ?? 0.0)})',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          onPressed: (double.tryParse(_returnInputBuffer) ?? 0.0) > 0.0001 &&
                                  (double.tryParse(_returnInputBuffer) ?? 0.0) <= currentPicked + 0.0001 &&
                                  _returnReasonController.text.trim().length >= 10
                              ? () => _commitReturnInScreen(part)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.bgDark,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: delta > dueQty + 0.0001 ? AppTheme.statusDanger : AppTheme.accentCyan.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('PICK QUANTITY (DELTA):',
                              style: TextStyle(fontSize: 9, color: AppTheme.textMuted, fontWeight: FontWeight.bold)),
                          Text(
                            '+ ${_inputBuffer.isEmpty ? '0' : _inputBuffer} ${part.uomLabel}',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: delta > dueQty + 0.0001 ? AppTheme.statusDanger : AppTheme.accentCyan,
                            ),
                          ),
                          Text(
                            'Currently: ${PartSummary.formatQty(currentPicked)} picked',
                            style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                          ),
                        ],
                      ),
                      if (_inputBuffer.isNotEmpty)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: AppTheme.textMuted,
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          ),
                          icon: const Icon(Icons.clear_rounded, size: 14),
                          label: const Text('Clear', style: TextStyle(fontSize: 11)),
                          onPressed: () => _onKeypadTap('C'),
                        ),
                    ],
                  ),
                ),

                // Confirm Delta Pick (shows confirmation screen)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: canConfirmPick ? AppTheme.statusComplete : AppTheme.bgDark,
                    foregroundColor: canConfirmPick ? Colors.white : AppTheme.textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 14), minimumSize: const Size(0, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded, size: 20),
                  label: Text(
                    canConfirmPick
                        ? 'Confirm Pick (+${PartSummary.formatQty(delta)})'
                        : delta > dueQty + 0.0001
                            ? 'Exceeds Due (${PartSummary.formatQty(dueQty)} max)'
                            : 'Enter Qty to Pick',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  onPressed: canConfirmPick ? () => _requestConfirmDeltaPick(part) : null,
                ),

                // Match Due
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: dueQty > 0.0001 ? AppTheme.primaryBlue : AppTheme.bgDark,
                    foregroundColor: dueQty > 0.0001 ? Colors.white : AppTheme.textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 14), minimumSize: const Size(0, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.done_all_rounded, size: 18),
                  label: Text(
                    dueQty > 0.0001 ? 'Match Due (+${PartSummary.formatQty(dueQty)})' : 'All Due Picked',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  onPressed: dueQty > 0.0001 ? () => _pickMatchDue(part) : null,
                ),

                // Return Picked + Missing Part
                Row(
                  children: [
                    if (currentPicked > 0.0001) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFE07B00)),
                            foregroundColor: const Color(0xFFE07B00),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.replay_rounded, size: 18),
                          label: const Text('Return Qty (Unpick)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          onPressed: () {
                            setState(() {
                              _isReturnMode = true;
                              _returnInputBuffer = '';
                              _returnReasonController.clear();
                            });
                            _returnReasonFocusNode.requestFocus();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: part.isManualAdd ? Colors.grey.shade700 : AppTheme.statusDanger,
                          ),
                          foregroundColor: part.isManualAdd ? Colors.grey.shade600 : AppTheme.statusDanger,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: Icon(
                          part.isManualAdd ? Icons.block_rounded : Icons.warning_amber_rounded,
                          size: 18,
                          color: part.isManualAdd ? Colors.grey.shade600 : AppTheme.statusDanger,
                        ),
                        label: Text(
                          'Missing',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: part.isManualAdd ? Colors.grey.shade600 : AppTheme.statusDanger,
                          ),
                        ),
                        onPressed: () => _markPartMissing(part),
                      ),
                    ),
                  ],
                ),
                // ──────────────────────────────────────────────────────────────
                // Partial Picker row: Note | Remove from Picking | Replace Part ID
                // ──────────────────────────────────────────────────────────────
                Row(
                  children: [
                    // Picker Note
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: (_userPartNotes[part.partId]?.isNotEmpty ?? false)
                                ? const Color(0xFF00E5FF)
                                : const Color(0xFF00E5FF).withValues(alpha: 0.5),
                          ),
                          foregroundColor: const Color(0xFF00E5FF),
                          backgroundColor: (_userPartNotes[part.partId]?.isNotEmpty ?? false)
                              ? const Color(0xFF00E5FF).withValues(alpha: 0.12)
                              : Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.comment_rounded, size: 16),
                        label: Text(
                          (_userPartNotes[part.partId]?.isNotEmpty ?? false) ? 'Note ✓' : 'Note',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        onPressed: () => _showPickerNoteDialog(part),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Remove from Picking
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: _removedFromPickingParts.contains(part.partId)
                                ? Colors.grey.shade600
                                : Colors.grey.shade500,
                          ),
                          foregroundColor: _removedFromPickingParts.contains(part.partId)
                              ? Colors.grey.shade500
                              : Colors.grey.shade300,
                          backgroundColor: _removedFromPickingParts.contains(part.partId)
                              ? Colors.grey.shade900
                              : Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.block_rounded, size: 16),
                        label: Text(
                          _removedFromPickingParts.contains(part.partId)
                              ? '⛔ Removed'
                              : 'Remove',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        onPressed: _removedFromPickingParts.contains(part.partId)
                            ? null
                            : () => _showRemoveFromPickingDialog(part),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Replace Part ID
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: part.isManualAdd ? Colors.grey.shade700 : const Color(0xFFAB47BC),
                          ),
                          foregroundColor: part.isManualAdd ? Colors.grey.shade600 : const Color(0xFFCE93D8),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: Icon(
                          part.isManualAdd ? Icons.block_rounded : Icons.find_replace_rounded,
                          size: 16,
                          color: part.isManualAdd ? Colors.grey.shade600 : const Color(0xFFCE93D8),
                        ),
                        label: Text(
                          'Replace',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: part.isManualAdd ? Colors.grey.shade600 : const Color(0xFFCE93D8),
                          ),
                        ),
                        onPressed: () => _showReplacePartIdDialog(part),
                      ),
                    ),
                  ],
                ),
                // ──────────────────────────────────────────────────────────────
                // Add Part Manually (Pick Mode exclusive)
                // ──────────────────────────────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFBB86FC)),
                      foregroundColor: const Color(0xFFBB86FC),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                    label: const Text('＋ Add Part Manually', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    onPressed: _showManualAddPartDialog,
                  ),
                ),
                ], // end of pick vs return else
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeypadKey(String key, {String? label, bool isAction = false}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: isAction ? AppTheme.bgDark : AppTheme.cardDark,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _onKeypadTap(key),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderDark),
              ),
              alignment: Alignment.center,
              child: Text(
                label ?? key,
                style: TextStyle(
                  fontSize: isAction ? 20 : 24,
                  fontWeight: FontWeight.bold,
                  color: isAction ? AppTheme.accentCyan : AppTheme.textLight,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.bgDark,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderDark),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppTheme.accentCyan),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11, color: AppTheme.textLight, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _qtyColumn(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 10, letterSpacing: 1.0, color: AppTheme.textMuted, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Widget _buildBottomNavigation(PartSummary currentPart) {
    final isAtEnd = _currentIndex >= _currentParts.length - 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.cardDark,
        border: Border(top: BorderSide(color: AppTheme.borderDark, width: 1.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.arrow_back_rounded, size: 16),
            label: const Text('Previous', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14), minimumSize: const Size(120, 52)),
            onPressed: _currentIndex > 0 ? _goToPrevPart : null,
          ),
          if (isAtEnd)
            const SizedBox.shrink()
          else
            OutlinedButton.icon(
              icon: const Icon(Icons.skip_next_rounded, size: 18),
              label: const Text('Skip', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14), minimumSize: const Size(120, 52)),
              onPressed: _goToNextPart,
            ),
          ElevatedButton.icon(
            icon: Icon(isAtEnd ? Icons.loop_rounded : Icons.arrow_forward_rounded, size: 16),
            label: Text(isAtEnd ? 'Go Over' : 'Next', style: const TextStyle(fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isAtEnd ? AppTheme.statusDanger : AppTheme.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14), minimumSize: const Size(130, 52),
            ),
            onPressed: _goToNextPart,
          ),
        ],
      ),
    );
  }

  /// Green animated banner shown when a part is fully picked.
  Widget _buildFullyPickedBanner() {
    return AnimatedOpacity(
      opacity: _showFullyPickedBanner ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.statusComplete,
          boxShadow: [
            BoxShadow(
              color: AppTheme.statusComplete.withValues(alpha: 0.5),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 24),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '✓  $_fullyPickedPartId — Fully Picked!',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Input formatter that enforces uppercase A-Z / 0-9 only for Part ID replacement.
/// Strips spaces, special characters and auto-converts lowercase to uppercase.
class _UpperAlphanumericInputFormatter extends TextInputFormatter {
  static final _pattern = RegExp(r'[^A-Z0-9]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final filtered = newValue.text.toUpperCase().replaceAll(_pattern, '');
    // Adjust cursor offset if characters were removed
    final newOffset = filtered.length < newValue.selection.baseOffset
        ? filtered.length
        : newValue.selection.baseOffset;
    return newValue.copyWith(
      text: filtered,
      selection: TextSelection.collapsed(offset: newOffset.clamp(0, filtered.length)),
    );
  }
}
