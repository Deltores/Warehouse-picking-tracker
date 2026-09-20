import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../models/picklist_item.dart';
import '../../models/session_metadata.dart';
import '../../models/unit_record.dart';
import '../../services/database_service.dart';
import '../../services/excel_service.dart';
import '../../services/log_service.dart';
import '../theme/app_theme.dart';

/// Represents a consolidated batch of sessions exported together.
class SessionBatchGroup {
  final String batchKey;
  final String unitId;
  final String unitName;
  final String status;
  final List<SessionMetadata> sessions;

  SessionBatchGroup({
    required this.batchKey,
    required this.unitId,
    required this.unitName,
    required this.status,
    required this.sessions,
  });

  Set<String> get unitIds => sessions.map((s) => s.unitId).toSet();

  String get seqListStr {
    final seqNos = sessions.map((s) => s.sessionSeqNo).where((n) => n > 0).toSet().toList()..sort();
    return seqNos.isNotEmpty
        ? seqNos.map((n) => '#$n').join(', ')
        : '${sessions.length} sessions';
  }

  int get earliestStart => sessions.map((s) => s.startTime).reduce((a, b) => a < b ? a : b);
  int get latestEnd => sessions.map((s) => s.endTime ?? s.startTime).reduce((a, b) => a > b ? a : b);
  String get totalDurationStr => SessionMetadata.formatTotalDuration(sessions);
  int get totalItemsPicked => sessions.fold<int>(0, (sum, s) => sum + s.totalItemsPicked);
}

/// SessionExportScreen: Global export hub for finished/closed worker sessions.
///
/// Features:
///  - Tab 1: CLOSED sessions waiting for batch super export (strictly parts count, no pcs)
///  - Tab 2: EXPORTED super sessions (grouped by batchId, with enclosed sessions and bulk Mark as ISSUED)
///  - Tab 3: ISSUED super sessions (ERP acknowledged)
///  - Full batch delete support (trash icon) to purge old test sessions
///  - Calm tab transitions without forced jumping
class SessionExportScreen extends StatefulWidget {
  final DatabaseService dbService;
  final ExcelService excelService;

  const SessionExportScreen({
    super.key,
    required this.dbService,
    required this.excelService,
  });

  @override
  State<SessionExportScreen> createState() => _SessionExportScreenState();
}

class _SessionExportScreenState extends State<SessionExportScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<SessionMetadata> _sessions = [];
  Map<String, UnitRecord> _units = {};
  Map<String, Map<String, num>> _unitPickStats = {};
  Map<String, Set<String>> _sessionPartIdsMap = {};
  String? _customExportDir;
  bool _isLoading = true;

  List<SessionMetadata> get _closedSessions =>
      _sessions.where((s) => s.isClosed).toList();

  List<SessionMetadata> get _exportedSessions =>
      _sessions.where((s) => (s.isExported || s.isFinished) && !s.isIssued).toList();

  List<SessionMetadata> get _issuedSessions =>
      _sessions.where((s) => s.isIssued).toList();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadSessions();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    setState(() => _isLoading = true);

    final lastExportDir = await widget.dbService.getLastExportDir();
    if (lastExportDir != null && lastExportDir.isNotEmpty) {
      _customExportDir = lastExportDir;
    }

    final allUnits = await widget.dbService.getAllUnits(includeDeleted: true);
    _units = { for (var u in allUnits) u.id: u };

    final statsMap = <String, Map<String, num>>{};
    for (final u in allUnits) {
      statsMap[u.id] = await widget.dbService.getUnitPartPickStats(u.id);
    }

    // Auto-purge sessions according to lifecycle (CLOSED: 80d, EXPORTED: 70d, ISSUED: 60d) and 50MB cap
    await widget.dbService.purgeExpiredSessionsLifecycle();

    // Synchronize session picked counts from session_picks to heal legacy/corrupted counts
    await widget.dbService.syncSessionPicksCounts();

    final sessions = await widget.dbService.getAllExportableSessions();
    // LIFO sorting: newest sessions (by end time or start time) at top
    sessions.sort((a, b) => (b.endTime ?? b.startTime).compareTo(a.endTime ?? a.startTime));

    final sessionPartIdsMap = <String, Set<String>>{};
    for (final s in sessions) {
      sessionPartIdsMap[s.id] = await widget.dbService.getSessionPickedPartIds(s.id);
    }

    if (mounted) {
      setState(() {
        _sessions = sessions;
        _sessionPartIdsMap = sessionPartIdsMap;
        _unitPickStats = statsMap;
        _isLoading = false;
      });
    }
  }

  Future<void> _chooseExportFolder() async {
    final selected = await FilePicker.getDirectoryPath();
    if (selected != null && selected.isNotEmpty) {
      await widget.dbService.setLastExportDir(selected);
      setState(() => _customExportDir = selected);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export directory updated to: $selected'),
            backgroundColor: AppTheme.statusComplete,
          ),
        );
      }
    }
  }

  String _sessionBatchKey(SessionMetadata s) {
    if (s.batchId.isNotEmpty) {
      return s.batchId;
    }
    // Fallback for older unbatched sessions: maintain distinct session cards
    return 'SESSION_${s.id}';
  }

  List<SessionBatchGroup> _groupIntoBatches(List<SessionMetadata> sessions) {
    final map = <String, List<SessionMetadata>>{};
    for (final s in sessions) {
      final key = _sessionBatchKey(s);
      map.putIfAbsent(key, () => []).add(s);
    }
    final groups = map.entries.map((entry) {
      final list = entry.value;
      final unitIds = list.map((s) => s.unitId).toSet().toList();
      final unitNames = unitIds.map((uid) => _units[uid]?.name ?? 'Unit $uid').toSet().toList();
      return SessionBatchGroup(
        batchKey: entry.key,
        unitId: unitIds.join(', '),
        unitName: unitNames.join(', '),
        status: list.first.status,
        sessions: list,
      );
    }).toList();
    // Sort newest first (LIFO) so latest batches are at the top
    groups.sort((a, b) => b.latestEnd.compareTo(a.latestEnd));
    return groups;
  }

  // ─── Batch Super Export (All Unexported Sessions) ────────────

  Future<void> _handleBatchExport() async {
    if (_closedSessions.isEmpty) return;

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
            Icon(Icons.bolt_rounded, color: Color(0xFFE07B00), size: 24),
            SizedBox(width: 10),
            Text('Export Batch Super Session?', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
          ],
        ),
        content: Text(
          'Export ${_closedSessions.length} closed session(s) across all units into a consolidated Excel file and mark them as EXPORTED?\n\n'
          'All picked parts will be merged into a single Super Session workbook.',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.statusComplete,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Export Now', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    const issuedStatus = 'Pending Issue';
    setState(() => _isLoading = true);

    try {
      final sessionsToExport = List<SessionMetadata>.from(_closedSessions);
      final allUnitIds = sessionsToExport.map((s) => s.unitId).toSet().toList();

      final unitOriginalFiles = <String, String>{};
      final unitItems = <String, List<PicklistItem>>{};
      final unitNames = <String, String>{};
      final unitReturnComments = <String, Map<String, List<String>>>{};
      final unitRemoveComments = <String, Map<String, String>>{};
      final unitManualPicks = <String, List<Map<String, dynamic>>>{};
      final unitAutoIssueResourceIds = <String, List<String>>{};
      final unitPartNotes = <String, Map<String, String>>{};
      final unitPartFlags = <String, Map<String, Map<String, dynamic>>>{};
      final autoIssueResourceIds = await widget.dbService.getAutoIssueResourceIds();

      for (final uid in allUnitIds) {
        final u = _units[uid];
        if (u == null) continue;
        unitOriginalFiles[uid] = u.filePath;
        unitNames[uid] = u.name;
        unitItems[uid] = await widget.dbService.getPicklistItems(uid);
        unitReturnComments[uid] = await widget.dbService.getReturnCommentsForUnit(uid);
        unitRemoveComments[uid] = await widget.dbService.getRemovedPartCommentsForUnit(uid);
        unitManualPicks[uid] = await widget.dbService.getManualPicksForUnit(uid);
        unitPartNotes[uid] = await widget.dbService.getUserPartNotesForUnit(uid);
        final rawFlags = await widget.dbService.getPartFlags(uid);
        final flagsMap = <String, Map<String, dynamic>>{};
        for (final f in rawFlags) {
          final pid = f['part_id']?.toString() ?? '';
          if (pid.isNotEmpty && !flagsMap.containsKey(pid)) {
            flagsMap[pid] = f;
          }
        }
        unitPartFlags[uid] = flagsMap;
        final isAutoAlreadyExported = await widget.dbService.isUnitAutoIssueExported(uid);
        unitAutoIssueResourceIds[uid] = isAutoAlreadyExported ? <String>[] : autoIssueResourceIds;
      }

      if (unitOriginalFiles.isEmpty) {
        throw Exception('No unit files found for closed sessions.');
      }

      final unitBatchPickedPartIds = <String, Set<String>>{};
      final sessionIds = sessionsToExport.map((s) => s.id).toList();
      int totalPickedInBatch = 0;
      for (final uid in allUnitIds) {
        final pickedPartIds = await widget.dbService.getBatchPickedPartIdsForUnit(sessionIds, uid);
        unitBatchPickedPartIds[uid] = pickedPartIds;
        totalPickedInBatch += pickedPartIds.length;
      }

      // Check if there are any auto-issue items pending
      bool hasPendingAutoIssue = false;
      for (final uid in allUnitIds) {
        final autoRes = unitAutoIssueResourceIds[uid] ?? [];
        if (autoRes.isNotEmpty) {
          final items = unitItems[uid] ?? [];
          if (items.any((i) => i.resourceId.trim().isEmpty
              ? autoRes.any((r) => r.trim().isEmpty || r == '(Empty / Unassigned)')
              : autoRes.any((r) => r.trim().toLowerCase() == i.resourceId.trim().toLowerCase()))) {
            hasPendingAutoIssue = true;
            break;
          }
        }
      }

      int totalManualPicks = 0;
      for (final picks in unitManualPicks.values) {
        totalManualPicks += picks.length;
      }

      if (totalPickedInBatch == 0 && !hasPendingAutoIssue && totalManualPicks == 0) {
        setState(() => _isLoading = false);
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppTheme.cardDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppTheme.borderDark),
              ),
              title: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: AppTheme.statusPartial, size: 24),
                  SizedBox(width: 8),
                  Text('No Parts Picked', style: TextStyle(color: AppTheme.textLight, fontSize: 16)),
                ],
              ),
              content: const Text(
                'None of the selected closed sessions contain picked parts, and there are no auto-issue parts pending.\n\nCannot export an empty Super Session.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        return;
      }

      final seqNos = sessionsToExport.map((s) => s.sessionSeqNo).where((n) => n > 0).toList()..sort();
      final minSeq = seqNos.isNotEmpty ? seqNos.first : 1;
      final maxSeq = seqNos.isNotEmpty ? seqNos.last : 1;
      final earliestStart = sessionsToExport.map((s) => s.startTime).reduce((a, b) => a < b ? a : b);
      final latestEnd = sessionsToExport.map((s) => s.endTime ?? s.startTime).reduce((a, b) => a > b ? a : b);
      final tabletId = sessionsToExport.first.tabletId;
      final now = DateTime.now().millisecondsSinceEpoch;

      final combinedUnitName = unitNames.values.toSet().join('_');
      final firstFilePath = unitOriginalFiles.values.first;
      final dir = (_customExportDir != null && _customExportDir!.isNotEmpty)
          ? _customExportDir!
          : File(firstFilePath).parent.path;

      final fileName = SessionMetadata.buildBatchExportFileName(
        unitName: combinedUnitName,
        tabletId: tabletId,
        minSeq: minSeq,
        maxSeq: maxSeq,
        startTime: earliestStart,
        endTime: latestEnd,
      );
      final outputPath = p.join(dir, fileName);

      final writtenPath = await widget.excelService.exportMultiUnitBatchSuperSession(
        unitOriginalFiles: unitOriginalFiles,
        unitItems: unitItems,
        unitNames: unitNames,
        sessions: sessionsToExport,
        unitReturnComments: unitReturnComments,
        outputPath: outputPath,
        unitAutoIssueResourceIds: unitAutoIssueResourceIds,
        unitBatchPickedPartIds: unitBatchPickedPartIds,
        issuedStatus: issuedStatus,
        unitRemoveComments: unitRemoveComments,
        unitManualPicks: unitManualPicks,
        unitPartNotes: unitPartNotes,
        unitPartFlags: unitPartFlags,
      );

      // Single batchId grouping all sessions exported in this Super Session
      final batchId = 'BATCH_SUPER_${tabletId}_${minSeq}_to_${maxSeq}_$now';

      // Mark auto-issue items as exported for all participating units
      for (final uid in allUnitIds) {
        await widget.dbService.setUnitAutoIssueExported(uid, true);
      }

      // Mark all consolidated sessions as EXPORTED in DB with single batchId
      for (final s in sessionsToExport) {
        await widget.dbService.finishSession(
          s.id,
          s.endTime ?? now,
          s.totalItemsPicked,
          issuedStatus,
          batchId: batchId,
        );
      }

      await _loadSessions();
      if (!mounted) return;
      _tabController.animateTo(1); // Switch to Exported tab

      _showBatchSuccessDialog([writtenPath], sessionsToExport.length);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Batch Export failed: $e'), backgroundColor: AppTheme.statusDanger),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleReExportBatch(List<SessionMetadata> batchSessions) async {
    if (batchSessions.isEmpty) return;

    final issuedStatus = batchSessions.first.issuedStatus.isNotEmpty
        ? batchSessions.first.issuedStatus
        : 'Pending Issue';

    setState(() => _isLoading = true);
    try {
      final allUnitIds = batchSessions.map((s) => s.unitId).toSet().toList();
      final unitOriginalFiles = <String, String>{};
      final unitItems = <String, List<PicklistItem>>{};
      final unitNames = <String, String>{};
      final unitReturnComments = <String, Map<String, List<String>>>{};
      final unitRemoveComments = <String, Map<String, String>>{};
      final unitManualPicks = <String, List<Map<String, dynamic>>>{};
      final unitAutoIssueResourceIds = <String, List<String>>{};
      final unitPartNotes = <String, Map<String, String>>{};
      final unitPartFlags = <String, Map<String, Map<String, dynamic>>>{};
      final autoIssueResourceIds = await widget.dbService.getAutoIssueResourceIds();

      for (final uid in allUnitIds) {
        final u = _units[uid];
        if (u == null) continue;
        unitOriginalFiles[uid] = u.filePath;
        unitNames[uid] = u.name;
        unitItems[uid] = await widget.dbService.getPicklistItems(uid);
        unitReturnComments[uid] = await widget.dbService.getReturnCommentsForUnit(uid);
        unitRemoveComments[uid] = await widget.dbService.getRemovedPartCommentsForUnit(uid);
        unitManualPicks[uid] = await widget.dbService.getManualPicksForUnit(uid);
        unitPartNotes[uid] = await widget.dbService.getUserPartNotesForUnit(uid);
        final rawFlags = await widget.dbService.getPartFlags(uid);
        final flagsMap = <String, Map<String, dynamic>>{};
        for (final f in rawFlags) {
          final pid = f['part_id']?.toString() ?? '';
          if (pid.isNotEmpty && !flagsMap.containsKey(pid)) {
            flagsMap[pid] = f;
          }
        }
        unitPartFlags[uid] = flagsMap;
        final isFirstBatch = batchSessions.any((s) => s.sessionSeqNo <= 1);
        unitAutoIssueResourceIds[uid] = isFirstBatch ? autoIssueResourceIds : <String>[];
      }

      if (unitOriginalFiles.isEmpty) {
        throw Exception('No unit files found for this batch.');
      }

      final seqNos = batchSessions.map((s) => s.sessionSeqNo).where((n) => n > 0).toList()..sort();
      final minSeq = seqNos.isNotEmpty ? seqNos.first : 1;
      final maxSeq = seqNos.isNotEmpty ? seqNos.last : 1;
      final earliestStart = batchSessions.map((s) => s.startTime).reduce((a, b) => a < b ? a : b);
      final latestEnd = batchSessions.map((s) => s.endTime ?? s.startTime).reduce((a, b) => a > b ? a : b);
      final tabletId = batchSessions.first.tabletId;

      final combinedUnitName = unitNames.values.toSet().join('_');
      final firstFilePath = unitOriginalFiles.values.first;
      final dir = (_customExportDir != null && _customExportDir!.isNotEmpty)
          ? _customExportDir!
          : File(firstFilePath).parent.path;

      final fileName = SessionMetadata.buildBatchExportFileName(
        unitName: combinedUnitName,
        tabletId: tabletId,
        minSeq: minSeq,
        maxSeq: maxSeq,
        startTime: earliestStart,
        endTime: latestEnd,
      );
      final outputPath = p.join(dir, fileName);

      final writtenPath = await widget.excelService.exportMultiUnitBatchSuperSession(
        unitOriginalFiles: unitOriginalFiles,
        unitItems: unitItems,
        unitNames: unitNames,
        sessions: batchSessions,
        unitReturnComments: unitReturnComments,
        outputPath: outputPath,
        unitAutoIssueResourceIds: unitAutoIssueResourceIds,
        issuedStatus: issuedStatus,
        unitRemoveComments: unitRemoveComments,
        unitManualPicks: unitManualPicks,
        unitPartNotes: unitPartNotes,
        unitPartFlags: unitPartFlags,
      );

      await _loadSessions();
      if (!mounted) return;
      _showBatchSuccessDialog([writtenPath], batchSessions.length);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Re-Export Super Session failed: $e'), backgroundColor: AppTheme.statusDanger),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _markBatchAsIssued(List<SessionMetadata> unitSessions) async {
    if (unitSessions.isEmpty) return;

    final unitNames = unitSessions.map((s) => _units[s.unitId]?.name ?? 'Unit ${s.unitId}').toSet().join(', ');

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
            Icon(Icons.verified_rounded, color: AppTheme.accentCyan, size: 24),
            SizedBox(width: 10),
            Text('Mark as ISSUED?', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
          ],
        ),
        content: Text(
          'Are you sure you want to mark ${unitSessions.length} session(s) for "$unitNames" as ISSUED in ERP?\n\n'
          'Status will transition to ISSUED and move to the Issued tab.',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentCyan,
              foregroundColor: AppTheme.bgDark,
            ),
            icon: const Icon(Icons.verified_rounded, size: 18),
            label: const Text('Confirm ISSUED', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final s in unitSessions) {
        await widget.dbService.updateSessionIssuedStatus(s.id, 'ISSUED', issuedAt: now);
      }
      LogService.admin('Super Session (${unitSessions.length} sessions) marked as ISSUED');
      await _loadSessions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Super Session ($unitNames, ${unitSessions.length} sessions) marked as ISSUED.'),
            backgroundColor: AppTheme.accentCyan,
            action: SnackBarAction(
              label: 'View in Issued',
              textColor: Colors.white,
              onPressed: () => _tabController.animateTo(2),
            ),
          ),
        );
      }
    }
  }

  void _showBatchSuccessDialog(List<String> writtenFiles, int sessionCount) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.task_alt_rounded, color: AppTheme.statusComplete, size: 28),
          SizedBox(width: 10),
          Text('Batch Export Successful', style: TextStyle(color: AppTheme.textLight)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Successfully consolidated and exported $sessionCount sessions to Excel:',
              style: const TextStyle(color: AppTheme.textMuted),
            ),
            const SizedBox(height: 10),
            ...writtenFiles.map((path) => Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppTheme.bgDark, borderRadius: BorderRadius.circular(8)),
                  child: Text(path, style: const TextStyle(fontSize: 11, color: AppTheme.accentCyan, fontFamily: 'monospace')),
                )),
            const SizedBox(height: 10),
            const Text(
              'All sessions have been transitioned to EXPORTED status and are viewable in the "Exported" tab.',
              style: TextStyle(fontSize: 12, color: AppTheme.statusComplete),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Export Sessions'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.accentCyan,
          indicatorWeight: 3,
          labelColor: AppTheme.accentCyan,
          unselectedLabelColor: AppTheme.textMuted,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text('Closed (${_closedSessions.length})'),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.file_download_done_rounded, size: 16),
                  const SizedBox(width: 6),
                  Text('Exported (${_exportedSessions.length})'),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.verified_rounded, size: 16),
                  const SizedBox(width: 6),
                  Text('Issued (${_issuedSessions.length})'),
                ],
              ),
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildSessionListTab(
                  _closedSessions,
                  emptyMessage: 'No closed sessions waiting for export.',
                  emptyIcon: Icons.inbox_rounded,
                  isClosedTab: true,
                ),
                _buildSessionListTab(
                  _exportedSessions,
                  emptyMessage: 'No exported sessions found.',
                  emptyIcon: Icons.file_download_done_rounded,
                  isExportedTab: true,
                ),
                _buildSessionListTab(
                  _issuedSessions,
                  emptyMessage: 'No issued sessions found.',
                  emptyIcon: Icons.verified_outlined,
                  isIssuedTab: true,
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(String message, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: AppTheme.borderDark),
            const SizedBox(height: 14),
            Text(
              message,
              style: const TextStyle(fontSize: 16, color: AppTheme.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionListTab(
    List<SessionMetadata> list, {
    required String emptyMessage,
    required IconData emptyIcon,
    bool isClosedTab = false,
    bool isExportedTab = false,
    bool isIssuedTab = false,
  }) {
    if (isClosedTab) {
      return RefreshIndicator(
        onRefresh: _loadSessions,
        child: ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: list.isEmpty ? 2 : list.length + 1,
          itemBuilder: (ctx, i) {
            if (i == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildExportDestinationBar(),
                  if (list.isNotEmpty) _buildBatchExportHeader(),
                  _buildLegend(),
                ],
              );
            }
            if (list.isEmpty) {
              return _buildEmptyState(emptyMessage, emptyIcon);
            }
            return _buildSessionCard(
              list[i - 1],
              isClosedTab: true,
            );
          },
        ),
      );
    }

    // Exported and Issued tabs: Render cohesive batches with enclosed child cards
    final batches = _groupIntoBatches(list);
    return RefreshIndicator(
      onRefresh: _loadSessions,
      child: ListView.builder(
        padding: const EdgeInsets.all(20),
        itemCount: batches.isEmpty ? 2 : batches.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildExportDestinationBar(),
                _buildLegend(),
              ],
            );
          }
          if (batches.isEmpty) {
            return _buildEmptyState(emptyMessage, emptyIcon);
          }
          final batch = batches[i - 1];
          return _buildSuperSessionBatchCard(
            batch,
            isExportedTab: isExportedTab,
          );
        },
      ),
    );
  }

  Widget _buildBatchExportHeader() {
    final totalDurationStr = SessionMetadata.formatTotalDuration(_closedSessions);
    final earliestStart = _closedSessions.map((s) => s.startTime).reduce((a, b) => a < b ? a : b);
    final latestEnd = _closedSessions.map((s) => s.endTime ?? s.startTime).reduce((a, b) => a > b ? a : b);
    final startStr = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(earliestStart));
    final endStr = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(latestEnd));

    final closedUnitIds = _closedSessions.map((s) => s.unitId).toSet();
    int totalUnitParts = 0;
    for (final uid in closedUnitIds) {
      totalUnitParts += _unitPickStats[uid]?['total_parts']?.toInt() ?? 0;
    }

    final batchPartIds = _closedSessions.expand((s) => _sessionPartIdsMap[s.id] ?? <String>{}).toSet();
    final pickedCount = batchPartIds.isNotEmpty
        ? batchPartIds.length
        : _closedSessions.fold<int>(0, (sum, s) => sum + s.totalItemsPicked);

    final partsDisplay = totalUnitParts > 0
        ? '$pickedCount / $totalUnitParts parts'
        : '$pickedCount parts';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE07B00).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE07B00).withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFE07B00).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.bolt_rounded, color: Color(0xFFE07B00), size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Batch Super Export (${_closedSessions.length} Closed Sessions)',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Total Duration: $totalDurationStr • Parts Picked: $partsDisplay\nStart: $startStr • End: $endStr\nConsolidates all unexported sessions into 1 Excel file with unified audit columns.',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE07B00),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.bolt_rounded, size: 20),
            label: Text(
              '⚡ Export All Unexported (${_closedSessions.length} Sessions)',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            onPressed: _handleBatchExport,
          ),
        ],
      ),
    );
  }

  Widget _buildSuperSessionBatchCard(
    SessionBatchGroup batch, {
    required bool isExportedTab,
  }) {
    final accentColor = isExportedTab ? AppTheme.statusComplete : AppTheme.accentCyan;
    final startStr = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(batch.earliestStart));
    final endStr = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(batch.latestEnd));

    int totalUnitParts = 0;
    for (final uid in batch.unitIds) {
      final s = _unitPickStats[uid];
      if (s != null) {
        totalUnitParts += s['total_parts']?.toInt() ?? 0;
      }
    }

    final batchPartIds = batch.sessions.expand((s) => _sessionPartIdsMap[s.id] ?? <String>{}).toSet();
    final pickedCount = batchPartIds.isNotEmpty
        ? batchPartIds.length
        : batch.totalItemsPicked;

    final partsDisplay = totalUnitParts > 0
        ? '$pickedCount / $totalUnitParts parts'
        : '$pickedCount parts';

    int daysUntilPurge;
    final int retentionPeriodDays = isExportedTab ? 70 : 60;
    if (isExportedTab) {
      final expiryTime = batch.latestEnd + const Duration(days: 70).inMilliseconds;
      final msLeft = expiryTime - DateTime.now().millisecondsSinceEpoch;
      daysUntilPurge = (msLeft / (1000 * 60 * 60 * 24)).ceil().clamp(0, 70);
    } else {
      final issuedTimes = batch.sessions.map((s) => s.issuedAt).whereType<int>().toList();
      final latestIssuedAt = issuedTimes.isNotEmpty
          ? issuedTimes.reduce((a, b) => a > b ? a : b)
          : batch.latestEnd;
      final expiryTime = latestIssuedAt + const Duration(days: 60).inMilliseconds;
      final msLeft = expiryTime - DateTime.now().millisecondsSinceEpoch;
      daysUntilPurge = (msLeft / (1000 * 60 * 60 * 24)).ceil().clamp(0, 60);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isExportedTab ? Icons.inventory_2_rounded : Icons.verified_rounded,
                  color: accentColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isExportedTab
                          ? '⚡ Exported Super Session — ${batch.unitName}'
                          : '✓ Issued Super Session — ${batch.unitName}',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Sessions: ${batch.seqListStr} • Parts Picked: $partsDisplay • Duration: ${batch.totalDurationStr}',
                      style: TextStyle(fontSize: 11, color: accentColor, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Start: $startStr • End: $endStr',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.hourglass_bottom_rounded, size: 12, color: Colors.amber),
                              const SizedBox(width: 4),
                              Text(
                                '⏳ $daysUntilPurge days remaining until auto-purge (${retentionPeriodDays}d retention)',
                                style: const TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.borderDark),
                    foregroundColor: AppTheme.textLight,
                    minimumSize: const Size(0, 40),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Re-Export Super Session', style: TextStyle(fontSize: 12)),
                  onPressed: () => _handleReExportBatch(batch.sessions),
                ),
              ),
              if (isExportedTab) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentCyan,
                      foregroundColor: AppTheme.bgDark,
                      minimumSize: const Size(0, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.verified_rounded, size: 16),
                    label: const Text(
                      'Mark as ISSUED',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _markBatchAsIssued(batch.sessions),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              collapsedIconColor: AppTheme.textMuted,
              iconColor: accentColor,
              title: Text(
                'Enclosed Sessions (${batch.sessions.length})',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accentColor),
              ),
              children: batch.sessions
                  .map((session) => _buildChildSessionCard(session, isExportedTab: isExportedTab))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChildSessionCard(
    SessionMetadata session, {
    required bool isExportedTab,
  }) {
    final statusColor = isExportedTab ? AppTheme.statusComplete : AppTheme.accentCyan;
    final startTimeStr = DateFormat('yyyy-MM-dd HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(session.startTime),
    );
    final endTimeStr = session.endTime != null
        ? DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(session.endTime!))
        : 'In progress';

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgDark.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderDark.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  session.cardDisplayTitle,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _metaChip(Icons.person_rounded, session.workerName),
              _metaChip(Icons.play_circle_outline_rounded, 'Start: $startTimeStr'),
              _metaChip(Icons.stop_circle_outlined, 'End: $endTimeStr'),
              _metaChip(Icons.timer_outlined, session.formattedDuration),
              _metaChip(Icons.check_box_rounded, '${session.totalItemsPicked} parts'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExportDestinationBar() {
    final hasCustom = _customExportDir != null && _customExportDir!.isNotEmpty;
    return Card(
      color: AppTheme.bgDark,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.borderDark),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.folder_open_rounded, color: AppTheme.accentCyan, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Export Folder Destination:',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasCustom ? _customExportDir! : 'Default (Same folder as original Excel file)',
                    style: TextStyle(
                      fontSize: 13,
                      color: hasCustom ? AppTheme.textLight : AppTheme.textMuted,
                      fontWeight: hasCustom ? FontWeight.w600 : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.accentCyan),
                foregroundColor: AppTheme.accentCyan,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              icon: const Icon(Icons.drive_file_move_rounded, size: 16),
              label: Text(hasCustom ? 'Change' : 'Choose Folder', style: const TextStyle(fontSize: 12)),
              onPressed: _chooseExportFolder,
            ),
            if (hasCustom) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Reset to default folder',
                color: AppTheme.textMuted,
                onPressed: () async {
                  await widget.dbService.setLastExportDir('');
                  setState(() => _customExportDir = null);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLegend() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(spacing: 16, runSpacing: 6, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          _legendDot(const Color(0xFFE07B00)), const SizedBox(width: 6),
          const Text('CLOSED — Ready to export', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _legendDot(AppTheme.statusComplete), const SizedBox(width: 6),
          const Text('EXPORTED — Excel written', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _legendDot(AppTheme.accentCyan), const SizedBox(width: 6),
          const Text('ISSUED — Marked in ERP', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ]),
      ]),
    );
  }

  Widget _legendDot(Color color) => Container(
    width: 10, height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  Widget _buildSessionCard(
    SessionMetadata session, {
    bool isClosedTab = false,
  }) {
    const statusColor = Color(0xFFE07B00);
    const statusLabel = 'CLOSED';

    final unit = _units[session.unitId];
    final startTimeStr = DateFormat('yyyy-MM-dd HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(session.startTime),
    );
    final endTimeStr = session.endTime != null
        ? DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(session.endTime!))
        : 'In progress';

    final sessionEndTime = session.endTime ?? session.startTime;
    final expiryTime = sessionEndTime + const Duration(days: 80).inMilliseconds;
    final msLeft = expiryTime - DateTime.now().millisecondsSinceEpoch;
    final daysUntilPurge = (msLeft / (1000 * 60 * 60 * 24)).ceil().clamp(0, 80);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: statusColor.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(width: 10, height: 10, decoration: const BoxDecoration(color: statusColor, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.cardDisplayTitle,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.id.length > 24 ? '${session.id.substring(0, 24)}...' : session.id,
                      style: const TextStyle(fontSize: 10, color: AppTheme.textMuted, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                ),
                child: const Text(statusLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor)),
              ),
            ]),
            if (unit != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  _metaChip(Icons.folder_open_rounded, unit.name),
                  if (session.tabletId.isNotEmpty) ...[const SizedBox(width: 8), _metaChip(Icons.tablet_android_rounded, session.tabletId)],
                ]),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _metaChip(Icons.person_rounded, session.workerName),
                _metaChip(Icons.play_circle_outline_rounded, 'Start: $startTimeStr'),
                _metaChip(Icons.stop_circle_outlined, 'End: $endTimeStr'),
                _metaChip(Icons.timer_outlined, session.formattedDuration),
                _metaChip(Icons.check_box_rounded, '${session.totalItemsPicked} parts'),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hourglass_bottom_rounded, size: 12, color: Colors.amber),
                  const SizedBox(width: 4),
                  Text(
                    '⏳ $daysUntilPurge days remaining until auto-purge (80d retention)',
                    style: const TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFE07B00).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE07B00).withValues(alpha: 0.25)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bolt_rounded, size: 16, color: Color(0xFFE07B00)),
                  SizedBox(width: 6),
                  Text(
                    'Included in Batch Super Export above',
                    style: TextStyle(fontSize: 12, color: Color(0xFFE07B00), fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(IconData icon, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: AppTheme.textMuted),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
    ]);
  }
}
