import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentParts = List.from(widget.partSummaries);
    _currentIndex = widget.startIndex.clamp(
        0, _currentParts.isEmpty ? 0 : _currentParts.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    _items = List.from(widget.allDeptItems);
    _unit = widget.unit;
    _loadSettings();
    _loadMissingParts();
  }

  Future<void> _loadSettings() async {
    final autoAdv = await widget.dbService.getAutoAdvancePick();
    if (mounted) setState(() => _autoAdvance = autoAdv);
  }

  Future<void> _loadMissingParts() async {
    final flags = await widget.dbService.getPartFlags(_unit.id, department: widget.department);
    final missing = flags
        .where((f) => f['flag_type']?.toString().toUpperCase() == 'MISSING')
        .map((f) => f['part_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (mounted) {
      setState(() {
        _flaggedMissingParts.addAll(missing);
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

  Future<void> _flushSession() async {
    if (widget.activeSession == null) return;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final pickedCount = _items.where((i) => i.qtyPicked > 0).length;
      await widget.dbService.updateSessionProgress(
        widget.activeSession!.id,
        pickedCount,
        endTime: nowMs,
      );
    } catch (_) {}
  }

  double _getCurrentPicked(String partId) {
    return _items
        .where((i) => i.department == widget.department && i.partId == partId)
        .fold<double>(0.0, (sum, i) => sum + i.qtyPicked);
  }

  double _getRequiredQty(String partId) {
    return _items
        .where((i) => i.department == widget.department && i.partId == partId)
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

    final updatedList = FifoAllocationEngine.allocateByPartId(
      allItems: _items,
      department: widget.department,
      partId: part.partId,
      totalPickedToAllocate: newTotal,
    );

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
    if (widget.activeSession != null) {
      final pickedCount = updatedList.where((i) => i.qtyPicked > 0).length;
      await widget.dbService.updateSessionProgress(
        widget.activeSession!.id,
        pickedCount,
        endTime: nowMs,
      );
    }
    widget.onItemsUpdated?.call(updatedList);

    // If part was flagged MISSING and is now fully picked, clear the flag and badge
    if (isNowFullyPicked) {
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
          });
        }
      }
    }

    LogService.picker('PICK: ${part.partId} +${PartSummary.formatQty(delta)} pcs (${PartSummary.formatQty(newTotal)}/${PartSummary.formatQty(requiredQty)}) → Unit: ${_unit.name}, Dept: ${widget.department}, Line: ${widget.lineLabel ?? "Default"}');

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
          content: Text('Cannot pick more than remaining due (${PartSummary.formatQty(dueQty)} pcs).'),
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
    if (_currentIndex < _currentParts.length - 1) {
      LogService.info('USER_ACTION', 'PickMode: Next (idx $_currentIndex)');
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    } else {
      // Reached the end -> "Go Over":
      // Prune fully picked parts so they don't appear in the loop
      final remaining = _currentParts.where((p) {
        final isMissing = _flaggedMissingParts.contains(p.partId);
        final due = _getDueQty(p.partId);
        return due > 0.0001 || isMissing;
      }).toList();

      if (remaining.isEmpty) {
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
        return;
      }

      LogService.picker('PickMode: Go Over (${remaining.length} pending)');
      setState(() {
        _currentParts = remaining;
        _currentIndex = 0;
        _inputBuffer = '';
      });
      _pageController.jumpToPage(0);
    }
  }

  void _goToPrevPart() {
    if (_currentIndex > 0) {
      LogService.picker('PickMode: Previous (idx $_currentIndex)');
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _markPartMissing(PartSummary part) async {
    setState(() {
      _flaggedMissingParts.add(part.partId);
      _inputBuffer = '';
    });

    await widget.dbService.recordPartFlag(
      unitId: _unit.id,
      partId: part.partId,
      department: widget.department,
      flagType: 'MISSING',
      note: 'Marked missing by ${widget.activeSession?.workerName ?? 'Picker'} in Pick Mode',
    );

    LogService.picker('MISSING flagged: ${part.partId}');

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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: AppTheme.statusComplete.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.statusComplete.withOpacity(0.4), width: 2),
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
                    if (part.description.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        part.description,
                        style: const TextStyle(fontSize: 14, color: AppTheme.textMuted),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 14),
                    Builder(builder: (_) {
                      final item = _items.firstWhere(
                        (i) => i.partId == part.partId && i.department == widget.department,
                        orElse: () => _items.firstWhere((i) => i.partId == part.partId, orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0)),
                      );
                      final lineStr = item.line.isNotEmpty ? item.line : (widget.lineLabel ?? 'General');
                      final resStr = item.resourceId.isNotEmpty ? item.resourceId : (part.resourceId.isNotEmpty ? part.resourceId : '');
                      return Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _infoChip(Icons.inventory_2_rounded, 'Unit: ${_unit.name}'),
                          _infoChip(Icons.apartment_rounded, 'Dept: ${widget.department}'),
                          if (lineStr.isNotEmpty) _infoChip(Icons.view_week_rounded, 'Line: $lineStr'),
                          if (resStr.isNotEmpty) _infoChip(Icons.account_tree_rounded, 'Resource: $resStr'),
                        ],
                      );
                    }),
                    const SizedBox(height: 18),
                    const Divider(color: AppTheme.borderDark),
                    const SizedBox(height: 16),
                    // Summary table
                    _confirmRow('Picking (delta):', '+${PartSummary.formatQty(_pendingDelta)} pcs', AppTheme.statusComplete),
                    const SizedBox(height: 10),
                    _confirmRow('Picked after confirm:', '${PartSummary.formatQty(pickedAfterConfirm)} pcs', AppTheme.textLight),
                    const SizedBox(height: 10),
                    _confirmRow('Remaining Due:', '${PartSummary.formatQty(dueAfterPick)} pcs',
                        dueAfterPick <= 0.0001 ? AppTheme.statusComplete : AppTheme.statusPartial),
                    const SizedBox(height: 10),
                    _confirmRow('Total Required:', '${PartSummary.formatQty(requiredQty)} pcs', AppTheme.textMuted),
                  ],
                ),
              ),
              const SizedBox(height: 32),
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
                        'Save +${PartSummary.formatQty(_pendingDelta)} pcs',
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
    final session = widget.activeSession;
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.department,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (widget.lineLabel != null && widget.lineLabel!.isNotEmpty) ...[
                      const Text(' › ', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                      Flexible(
                        child: Text(
                          'Line: ${widget.lineLabel}',
                          style: const TextStyle(fontSize: 13, color: AppTheme.accentCyan, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    const Text(' — Pick Mode', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  ],
                ),
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
            Container(
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
                  SizedBox(width: 3),
                  Text('Auto', style: TextStyle(fontSize: 10, color: AppTheme.statusComplete, fontWeight: FontWeight.bold)),
                ],
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
    LogService.picker('RETURN: ${part.partId} -${PartSummary.formatQty(returnQty)} pcs (Reason: "$reason") → Unit: ${_unit.name}, Dept: ${widget.department}');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Returned ${PartSummary.formatQty(returnQty)} pcs of ${part.partId}.'),
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
                  'Picked: ${PartSummary.formatQty(currentPicked)} pcs',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Remaining after return: ${PartSummary.formatQty(remainingAfterReturn)} pcs',
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
              maxLines: 2,
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
    final progress = requiredQty > 0 ? (currentPicked / requiredQty).clamp(0.0, 1.0) : 0.0;

    final statusColor = isMissing
        ? AppTheme.statusDanger
        : isComplete
            ? AppTheme.statusComplete
            : currentPicked > 0
                ? AppTheme.statusPartial
                : AppTheme.statusUnpicked;

    // ON_HAND info
    String onHand = part.onHand;
    if (onHand.isEmpty) {
      final match = _items.firstWhere(
        (i) => i.partId == part.partId && i.onHand.isNotEmpty,
        orElse: () => PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0),
      );
      onHand = match.onHand;
    }

    // Work Orders info — list per WO with quantities
    final woItems = _items
        .where((i) => i.department == widget.department && i.partId == part.partId)
        .toList()
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));

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
                            ? const Color(0xFF0EA5E9).withOpacity(0.15)
                            : const Color(0xFFF97316).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: deptType == 'MAIN LINE'
                              ? const Color(0xFF0EA5E9).withOpacity(0.5)
                              : const Color(0xFFF97316).withOpacity(0.5),
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
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: AppTheme.textLight),
            ),
            if (part.description.isNotEmpty) ...[
              const SizedBox(height: 4),
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
                if (pickDate.isNotEmpty) _infoChip(Icons.event_available_rounded, 'Pick: $pickDate'),
                if (prodDate.isNotEmpty) _infoChip(Icons.precision_manufacturing_rounded, 'Prod: $prodDate'),
                if (part.resourceId.isNotEmpty) _infoChip(Icons.account_tree_rounded, 'Resource: ${part.resourceId}'),
                if (part.line.isNotEmpty) _infoChip(Icons.linear_scale_rounded, 'Line: ${part.line}'),
                if (part.subUnit.isNotEmpty) _infoChip(Icons.view_in_ar_rounded, 'Sub-Unit: ${part.subUnit}'),
              ],
            ),
            const SizedBox(height: 10),

            // Row 4: Work Orders with quantities (per WO)
            if (woItems.isNotEmpty) ...[
              const Text('Work Orders:', style: TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: woItems.map((wo) {
                  final woColor = wo.qtyDue <= 0.0001 ? AppTheme.statusComplete : AppTheme.statusPartial;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.bgDark,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: woColor.withOpacity(0.5)),
                    ),
                    child: Text(
                      '${wo.workOrder}: ${PicklistItem.formatQty(wo.qtyPicked)}/${PicklistItem.formatQty(wo.qtyRequired)}',
                      style: TextStyle(fontSize: 11, color: woColor, fontWeight: FontWeight.w600),
                    ),
                  );
                }).toList(),
              ),
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
                              '- ${_returnInputBuffer.isEmpty ? '0' : _returnInputBuffer} pcs',
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
                            '+ ${_inputBuffer.isEmpty ? '0' : _inputBuffer} pcs',
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
                          side: const BorderSide(color: AppTheme.statusDanger),
                          foregroundColor: AppTheme.statusDanger,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.warning_amber_rounded, size: 18),
                        label: const Text('Missing', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        onPressed: () => _markPartMissing(part),
                      ),
                    ),
                  ],
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
            label: const Text('Previous', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14), minimumSize: const Size(120, 52)),
            onPressed: _currentIndex > 0 ? _goToPrevPart : null,
          ),
          if (isAtEnd)
            const SizedBox.shrink()
          else
            OutlinedButton.icon(
              icon: const Icon(Icons.skip_next_rounded, size: 18),
              label: const Text('Skip', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
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
