import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../models/session_metadata.dart';
import '../../models/unit_record.dart';
import '../../services/database_service.dart';
import '../../services/excel_service.dart';
import '../../services/log_service.dart';
import '../theme/app_theme.dart';

/// SessionExportScreen: Shows all exportable sessions for the active unit.
///
/// Sessions are shown only when:
///  - status == 'CLOSED' or 'FINISHED'
///  - totalItemsPicked > 0
///
/// Badges:
///  - 🟡 CLOSED — ready to export
///  - 🟢 FINISHED — already exported (file may or may not exist)
///
/// Selecting a FINISHED session checks if the file exists:
///  - File exists → "Already Exported" info dialog
///  - File missing → allows re-export
///
/// Exported file name: {TabletID}_{sessionId}_{unitName}.xlsx
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
  String? _customExportDir;
  bool _isLoading = true;
  String? _processingId;

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

    _customExportDir = await widget.dbService.getLastExportDir();

    final allUnits = await widget.dbService.getAllUnits(includeDeleted: true);
    _units = { for (var u in allUnits) u.id: u };

    final sessions = await widget.dbService.getAllExportableSessions();
    // LIFO sorting: newest sessions (by end time or start time) at top
    sessions.sort((a, b) => (b.endTime ?? b.startTime).compareTo(a.endTime ?? a.startTime));

    setState(() {
      _sessions = sessions;
      _isLoading = false;
    });
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

  // ─── Export a single session ─────────────────────────────────

  Future<void> _handleExport(SessionMetadata session) async {
    final unit = _units[session.unitId];
    if (unit == null) return; // Unit was deleted

    // Determine the expected output file path for this session.
    final dir = (_customExportDir != null && _customExportDir!.isNotEmpty)
        ? _customExportDir!
        : File(unit.filePath).parent.path;
    final outputPath = p.join(dir, session.buildExportFileName(unit.name));

    // If already EXPORTED or ISSUED, check if a file with this session's base name exists.
    if (session.isExported || session.isFinished || session.isIssued) {
      // Check directory for a file with the session display name prefix.
      final existing = Directory(dir).existsSync()
          ? Directory(dir)
              .listSync()
              .whereType<File>()
              .where((f) => p.basename(f.path).startsWith(session.displayName(unit.name).replaceAll(RegExp(r'[^\w_\-]'), '_')))
              .toList()
          : <File>[];
      if (existing.isNotEmpty) {
        _showAlreadyExportedDialog(session, existing.first.path);
        return;
      }
      // File doesn't exist → fall through and re-export.
    }

    // Confirm ERP issued status before exporting.
    final issuedStatus = await _showIssuedStatusDialog(session);
    if (issuedStatus == null || !mounted) return;

    setState(() => _processingId = session.id);
    try {
      final items = await widget.dbService.getPicklistItems(unit.id);
      final returnComments = await widget.dbService.getReturnCommentsForUnit(unit.id);
      final now = DateTime.now().millisecondsSinceEpoch;

      final finalizedSession = session.copyWith(
        endTime: session.endTime ?? now,
        status: 'EXPORTED',
        issuedStatus: issuedStatus,
        totalItemsPicked: session.totalItemsPicked,
      );

      final autoIssueResourceIds = await widget.dbService.getAutoIssueResourceIds();
      final writtenPath = await widget.excelService.exportAndOverwrite(
        originalFilePath: unit.filePath,
        items: items,
        session: finalizedSession,
        unitName: unit.name,
        returnComments: returnComments,
        outputPath: outputPath,
        autoIssueResourceIds: autoIssueResourceIds,
      );

      await widget.dbService.finishSession(
        session.id,
        finalizedSession.endTime!,
        finalizedSession.totalItemsPicked,
        issuedStatus,
      );

      await _loadSessions();
      if (!mounted) return;
      _tabController.animateTo(1); // Move to Exported tab

      _showSuccessDialog(finalizedSession, writtenPath, expectedPath: outputPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: AppTheme.statusDanger),
        );
      }
    } finally {
      if (mounted) setState(() => _processingId = null);
    }
  }

  /// Admin action: mark an EXPORTED session as ISSUED with Admin PIN protection.
  Future<void> _markAsIssued(SessionMetadata session) async {
    final pinCtrl = TextEditingController();
    String? inlineError;

    final verified = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          title: const Row(
            children: [
              Icon(Icons.admin_panel_settings_rounded, color: AppTheme.accentCyan, size: 24),
              SizedBox(width: 10),
              Text('Admin Authorization', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter Admin PIN to mark this session as ISSUED in ERP:',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: pinCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                style: const TextStyle(color: AppTheme.textLight, fontSize: 22, letterSpacing: 4),
                decoration: InputDecoration(
                  hintText: 'PIN (default 1234)',
                  errorText: inlineError,
                  filled: true,
                  fillColor: AppTheme.bgDark,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppTheme.accentCyan, width: 2),
                  ),
                ),
                onSubmitted: (_) async {
                  final ok = await widget.dbService.verifyAdminPin(pinCtrl.text.trim());
                  if (!ctx.mounted) return;
                  if (ok) {
                    Navigator.pop(ctx, true);
                  } else {
                    setDialogState(() {
                      inlineError = 'Incorrect Admin PIN. Please try again.';
                    });
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null), // Cancel pressed — return null!
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
              onPressed: () async {
                final ok = await widget.dbService.verifyAdminPin(pinCtrl.text.trim());
                if (!ctx.mounted) return;
                if (ok) {
                  Navigator.pop(ctx, true);
                } else {
                  setDialogState(() {
                    inlineError = 'Incorrect Admin PIN. Please try again.';
                  });
                }
              },
              child: const Text('Confirm ISSUED', style: TextStyle(color: AppTheme.bgDark, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (verified == true) {
      await widget.dbService.updateSessionIssuedStatus(session.id, 'ISSUED');
      LogService.admin('Session ${session.id} marked as ISSUED by Admin');
      await _loadSessions();
      if (mounted) {
        _tabController.animateTo(2); // Move to Issued tab!
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session marked as ISSUED and moved to Issued tab.'),
            backgroundColor: AppTheme.accentCyan,
          ),
        );
      }
    }
    // If verified == null, worker cancelled — no error message!
  }

  // ─── Dialogs ─────────────────────────────────────────────────

  Future<String?> _showIssuedStatusDialog(SessionMetadata session) {
    String selectedStatus = 'Pending';
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.upload_file_rounded, color: AppTheme.statusComplete),
                SizedBox(width: 10),
                Text('Export Session', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
              ]),
              const SizedBox(height: 4),
              Text(
                session.id,
                style: const TextStyle(fontSize: 12, color: AppTheme.accentCyan, fontWeight: FontWeight.normal),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow('Worker', session.workerName),
              _infoRow('Date', session.pickDate),
              _infoRow('Items Picked', '${session.totalItemsPicked}'),
              const SizedBox(height: 16),
              const Text('ERP Issued Status:', style: TextStyle(fontSize: 14, color: AppTheme.textMuted)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: ChoiceChip(
                  label: const Center(child: Text('Pending')),
                  selected: selectedStatus == 'Pending',
                  onSelected: (s) { if (s) setLocal(() => selectedStatus = 'Pending'); },
                  selectedColor: AppTheme.statusPartial.withValues(alpha: 0.25),
                  labelStyle: TextStyle(color: selectedStatus == 'Pending' ? AppTheme.statusPartial : AppTheme.textMuted, fontWeight: FontWeight.bold),
                )),
                const SizedBox(width: 12),
                Expanded(child: ChoiceChip(
                  label: const Center(child: Text('Issued')),
                  selected: selectedStatus == 'Issued',
                  onSelected: (s) { if (s) setLocal(() => selectedStatus = 'Issued'); },
                  selectedColor: AppTheme.statusComplete.withValues(alpha: 0.25),
                  labelStyle: TextStyle(color: selectedStatus == 'Issued' ? AppTheme.statusComplete : AppTheme.textMuted, fontWeight: FontWeight.bold),
                )),
              ]),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: const Icon(Icons.file_download_done_rounded, size: 18),
              label: const Text('Export Now'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusComplete),
              onPressed: () => Navigator.of(ctx).pop(selectedStatus),
            ),
          ],
        ),
      ),
    );
  }

  void _showAlreadyExportedDialog(SessionMetadata session, String path) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Row(children: [
          Icon(Icons.check_circle_rounded, color: AppTheme.statusComplete),
          SizedBox(width: 10),
          Text('Already Exported', style: TextStyle(color: AppTheme.textLight)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Session ${session.id} has already been exported and the file still exists.', style: const TextStyle(color: AppTheme.textMuted, height: 1.5)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.bgDark, borderRadius: BorderRadius.circular(8)),
              child: Text(path, style: const TextStyle(fontSize: 11, color: AppTheme.accentCyan, fontFamily: 'monospace')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
          OutlinedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              // File exists but user wants to force re-export — delete file first then retry.
              try { await File(path).delete(); } catch (_) {}
              await _handleExport(session);
            },
            child: const Text('Force Re-Export', style: TextStyle(color: AppTheme.statusDanger)),
          ),
        ],
      ),
    );
  }

  void _showSuccessDialog(SessionMetadata session, String writtenPath, {String? expectedPath}) {
    final isFallback = expectedPath != null &&
        p.canonicalize(writtenPath) != p.canonicalize(expectedPath);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: Row(children: [
          Icon(
            isFallback ? Icons.warning_amber_rounded : Icons.task_alt_rounded,
            color: isFallback ? AppTheme.statusPartial : AppTheme.statusComplete,
            size: 28,
          ),
          const SizedBox(width: 10),
          Text(isFallback ? 'Export Saved (Fallback)' : 'Export Successful',
              style: const TextStyle(color: AppTheme.textLight)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isFallback) ...[
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppTheme.statusPartial.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.statusPartial.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'Notice: Target directory was not writable (storage permissions needed). '
                  'The file was safely saved to internal storage below.',
                  style: TextStyle(fontSize: 12, color: AppTheme.statusPartial),
                ),
              ),
            ],
            const Text('File written successfully:', style: TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.bgDark, borderRadius: BorderRadius.circular(8)),
              child: Text(writtenPath, style: const TextStyle(fontSize: 11, color: AppTheme.accentCyan, fontFamily: 'monospace')),
            ),
            const SizedBox(height: 12),
            _infoRow('Session', session.id),
            _infoRow('ERP Status', session.issuedStatus),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            child: const Text('Done — Back to Home'),
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
                ),
                _buildSessionListTab(
                  _exportedSessions,
                  emptyMessage: 'No exported sessions found.',
                  emptyIcon: Icons.file_download_done_rounded,
                ),
                _buildSessionListTab(
                  _issuedSessions,
                  emptyMessage: 'No issued sessions found.',
                  emptyIcon: Icons.verified_outlined,
                ),
              ],
            ),
    );
  }

  Widget _buildSessionListTab(
    List<SessionMetadata> list, {
    required String emptyMessage,
    required IconData emptyIcon,
  }) {
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
                _buildLegend(),
              ],
            );
          }
          if (list.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(emptyIcon, size: 64, color: AppTheme.borderDark),
                    const SizedBox(height: 14),
                    Text(
                      emptyMessage,
                      style: const TextStyle(fontSize: 16, color: AppTheme.textMuted),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return _buildSessionCard(list[i - 1]);
        },
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

  Widget _buildSessionCard(SessionMetadata session) {
    final isProcessing = _processingId == session.id;
    Color statusColor;
    String statusLabel;
    if (session.isIssued) {
      statusColor = AppTheme.accentCyan;
      statusLabel = 'ISSUED';
    } else if (session.isExported || session.isFinished) {
      statusColor = AppTheme.statusComplete;
      statusLabel = 'EXPORTED';
    } else if (session.isClosed) {
      statusColor = const Color(0xFFE07B00);
      statusLabel = 'CLOSED';
    } else {
      statusColor = AppTheme.primaryBlue;
      statusLabel = 'OPEN';
    }

    final unit = _units[session.unitId];
    final startTimeStr = DateFormat('yyyy-MM-dd HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(session.startTime),
    );
    final endTimeStr = session.endTime != null
        ? DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(session.endTime!))
        : 'In progress';

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
              Container(width: 10, height: 10, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (unit != null && session.sessionSeqNo > 0)
                      Text(
                        session.displayName(unit.name),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                      ),
                    Text(
                      session.id.length > 20 ? '${session.id.substring(0, 20)}...' : session.id,
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
                child: Text(statusLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor)),
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
            // Start and End Times prominently displayed
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _metaChip(Icons.person_rounded, session.workerName),
                _metaChip(Icons.play_circle_outline_rounded, 'Start: $startTimeStr'),
                _metaChip(Icons.stop_circle_outlined, 'End: $endTimeStr'),
                _metaChip(Icons.check_box_rounded, '${session.totalItemsPicked} pcs'),
              ],
            ),
            if ((session.isExported || session.isFinished || session.isIssued) && session.issuedStatus.isNotEmpty) ...[  
              const SizedBox(height: 8),
              Row(children: [
                _metaChip(Icons.tag_rounded, 'ERP: ${session.issuedStatus}'),
              ]),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: isProcessing
                  ? const Center(child: SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                  : Column(
                      children: [
                        ElevatedButton.icon(
                          icon: Icon(
                            (session.isExported || session.isFinished || session.isIssued)
                                ? Icons.refresh_rounded
                                : Icons.file_download_rounded,
                            size: 18,
                          ),
                          label: Text(
                            (session.isExported || session.isFinished || session.isIssued)
                                ? 'Re-Export'
                                : 'Export This Session',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: (session.isExported || session.isFinished || session.isIssued)
                                ? AppTheme.borderDark
                                : AppTheme.statusComplete,
                            minimumSize: const Size(double.infinity, 44),
                          ),
                          onPressed: () => _handleExport(session),
                        ),
                        // Mark as Issued — only for EXPORTED sessions (not yet ISSUED)
                        if (!session.isIssued && (session.isExported || session.isFinished)) ...[  
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: AppTheme.accentCyan),
                              foregroundColor: AppTheme.accentCyan,
                              minimumSize: const Size(double.infinity, 40),
                            ),
                            icon: const Icon(Icons.verified_rounded, size: 16),
                            label: const Text('Mark as ISSUED (Admin)', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: () => _markAsIssued(session),
                          ),
                        ],
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

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          Text(value, style: const TextStyle(color: AppTheme.textLight, fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
