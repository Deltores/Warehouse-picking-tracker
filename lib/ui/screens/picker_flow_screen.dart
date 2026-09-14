import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../engine/column_mapper.dart';
import '../../models/picklist_item.dart';
import '../../models/session_metadata.dart';
import '../../models/unit_pick_date_urgency.dart';
import '../../models/unit_record.dart';
import '../../services/database_service.dart';
import '../../services/excel_service.dart';
import '../../services/log_service.dart';
import '../../services/storage_manager.dart';
import '../theme/app_theme.dart';
import 'picking_screen.dart';

/// PickerFlowScreen: A guided 3-step onboarding for pickers.
///
/// Step 1 — Enter Worker Name.
/// Step 2 — Select a Unit (file already imported in DB) or import a new one.
/// Step 3 — Select Department (active departments for the chosen unit).
///
/// On completion, navigates to PickingScreen with a pre-created session.
class PickerFlowScreen extends StatefulWidget {
  final DatabaseService dbService;
  final StorageManager storageManager;
  final ExcelService excelService;
  final ColumnMapper columnMapper;

  const PickerFlowScreen({
    super.key,
    required this.dbService,
    required this.storageManager,
    required this.excelService,
    required this.columnMapper,
  });

  @override
  State<PickerFlowScreen> createState() => _PickerFlowScreenState();
}

class _PickerFlowScreenState extends State<PickerFlowScreen> {
  int _currentStep = 0;

  // Step 1 state
  final _nameController = TextEditingController();
  final _nameFormKey = GlobalKey<FormState>();
  String _workerName = '';
  List<String> _standardPickers = [];

  // Step 2 state
  List<UnitRecord> _availableUnits = [];
  Map<String, Map<String, int>> _unitPartProgress = {};
  Map<String, UnitPickDateUrgency> _unitUrgencies = {};
  UnitRecord? _selectedUnit;
  bool _isImporting = false;

  // Step 3 state
  Map<String, bool> _departments = {};
  Map<String, UnitPickDateUrgency> _departmentUrgencies = {};
  Map<String, Map<String, int>> _departmentPartProgress = {};
  String? _selectedDepartment;

  @override
  void initState() {
    super.initState();
    _loadStandardPickers();
    _nameController.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkActiveSessionOnEntry();
    });
  }

  Future<void> _checkActiveSessionOnEntry() async {
    final activeSessions = await widget.dbService.getAllActiveSessions();
    if (activeSessions.isEmpty || !mounted) return;

    final session = activeSessions.first;
    final unit = await widget.dbService.getUnit(session.unitId);
    final unitName = unit?.name ?? session.unitId;

    if (!mounted) return;

    final startDateTime = DateTime.fromMillisecondsSinceEpoch(session.startTime);
    final formattedStartTime = DateFormat('yyyy-MM-dd HH:mm').format(startDateTime);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.accentCyan, width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.bolt_rounded, color: AppTheme.accentCyan, size: 24),
            SizedBox(width: 8),
            Text('Active Session In Progress', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Worker "${session.workerName}" currently has an active picking session on unit "$unitName".',
              style: const TextStyle(color: AppTheme.textLight, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.bgDark,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.borderDark),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.access_time_rounded, size: 16, color: AppTheme.accentCyan),
                  const SizedBox(width: 6),
                  Text(
                    'Started: $formattedStartTime',
                    style: const TextStyle(color: AppTheme.accentCyan, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'You can resume picking with this session, or close it to start a new worker session.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop(); // Exit back to HomeScreen
            },
            child: const Text('Exit to Home'),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFFE07B00)),
              foregroundColor: const Color(0xFFE07B00),
            ),
            onPressed: () async {
              final now = DateTime.now().millisecondsSinceEpoch;
              await widget.dbService.closeAllActiveSessions(endTime: now);
              LogService.picker('All active sessions closed by user to start new session');
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) {
                setState(() {
                  _workerName = '';
                  _nameController.clear();
                  _currentStep = 0;
                });
              }
            },
            child: const Text('End Session & Start New'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusComplete),
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            label: const Text('Resume Session', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
            onPressed: () {
              Navigator.of(ctx).pop();
              if (mounted) {
                setState(() {
                  _workerName = session.workerName;
                  _nameController.text = session.workerName;
                  _selectedUnit = unit;
                  _currentStep = 1; // Go to Unit select
                });
                _loadUnits();
                if (unit != null) {
                  _loadDepartments(unit);
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _loadStandardPickers() async {
    final list = await widget.dbService.getStandardPickers();
    if (mounted) {
      setState(() {
        _standardPickers = list;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ─── Navigation ───────────────────────────────────────────────

  void _nextStep() {
    if (_currentStep == 0) {
      final name = _nameController.text.trim();
      if (name.isEmpty || !_standardPickers.contains(name)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please tap and select your name from the pickers list.'),
            backgroundColor: AppTheme.statusDanger,
          ),
        );
        return;
      }
      _workerName = name;
      LogService.picker('$_workerName → step 2 (unit select)');
      _loadUnits();
    } else if (_currentStep == 1) {
      if (_selectedUnit == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select a unit to continue.'),
            backgroundColor: AppTheme.statusDanger,
          ),
        );
        return;
      }
      LogService.picker('$_workerName → unit ${_selectedUnit!.name}');
      _loadDepartments(_selectedUnit!);
    } else if (_currentStep == 2) {
      if (_selectedDepartment == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select a department.'),
            backgroundColor: AppTheme.statusDanger,
          ),
        );
        return;
      }
      _startSessionAndNavigate();
      return;
    }
    setState(() => _currentStep++);
  }

  // ─── Step 2: Unit Loading & Import ───────────────────────────

  Future<void> _loadUnits() async {
    final units = await widget.dbService.getAllUnits();
    final progressMap = <String, Map<String, int>>{};
    final urgencyMap = <String, UnitPickDateUrgency>{};
    for (final u in units) {
      progressMap[u.id] = await widget.dbService.getUnitPartProgress(u.id);
      final urgency = await widget.dbService.getUnitEarliestIncompletePickDate(u.id);
      if (urgency != null) {
        urgencyMap[u.id] = urgency;
      }
    }
    if (mounted) {
      setState(() {
        _availableUnits = units;
        _unitPartProgress = progressMap;
        _unitUrgencies = urgencyMap;
      });
    }
  }

  Future<void> _importNewFile() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
    );

    if (result == null || result.path == null) return;
    final filePath = result.path!;
    final fileName = p.basenameWithoutExtension(filePath);

    // Check if a unit from the same file name already exists in the database
    final existingUnits = await widget.dbService.getAllUnits();
    final duplicate = existingUnits.where((u) =>
        u.id.toLowerCase() == fileName.toLowerCase() ||
        u.name.toLowerCase() == fileName.toLowerCase() ||
        p.basename(u.filePath).toLowerCase() == p.basename(filePath).toLowerCase()
    ).firstOrNull;

    if (duplicate != null && mounted) {
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppTheme.statusPartial, size: 26),
              SizedBox(width: 10),
              Text('File Already Imported', style: TextStyle(color: AppTheme.textLight, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A unit from "${p.basename(filePath)}" is already loaded on this tablet.',
                style: const TextStyle(color: AppTheme.textLight, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderDark),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Unit Name: ${duplicate.name}', style: const TextStyle(color: AppTheme.accentCyan, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      'Status: ${duplicate.status} • ${duplicate.totalPicked}/${duplicate.totalRequired} pcs (${duplicate.progressPercentage.toStringAsFixed(1)}%)',
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Overwriting existing units is strictly blocked to protect picking progress. You can open this existing unit directly. If you need to re-import from scratch, an Administrator must delete it from the Admin Storage tab.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('CANCEL'),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryBlue),
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              label: const Text('Open Existing Unit'),
              onPressed: () => Navigator.of(ctx).pop('OPEN'),
            ),
          ],
        ),
      );

      if (choice == 'OPEN') {
        setState(() {
          _selectedUnit = duplicate;
          _currentStep = 2;
        });
        await _loadDepartments(duplicate);
      }
      return;
    }

    setState(() => _isImporting = true);
    try {
      final prunedId = await widget.storageManager.enforceCapacityLimit();
      if (prunedId != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Storage full (40 units): oldest completed unit was automatically removed.'),
            backgroundColor: AppTheme.primaryBlue,
          ),
        );
      }

      final autoIssueDepts = await widget.dbService.getAutoIssueComponents();
      final autoIssueResourceIds = await widget.dbService.getAutoIssueResourceIds();
      final parseResult = await widget.excelService.parseExcelFile(
        filePath,
        autoIssueDepartments: autoIssueDepts,
        autoIssueResourceIds: autoIssueResourceIds,
      );
      final unitId = parseResult['unitId'] as String;
      final deptList = parseResult['departments'] as List<String>;
      final parsedItems = parseResult['items'] as List<PicklistItem>;

      final totalReq = parsedItems.fold<double>(0.0, (s, i) => s + i.qtyRequired).round();
      final totalPicked = parsedItems.fold<double>(0.0, (s, i) => s + i.qtyPicked).round();
      final now = DateTime.now().millisecondsSinceEpoch;

      final newUnit = UnitRecord(
        id: unitId,
        name: unitId,
        filePath: filePath,
        totalRequired: totalReq,
        totalPicked: totalPicked,
        status: totalPicked >= totalReq && totalReq > 0 ? 'COMPLETED' : 'IN_PROGRESS',
        createdAt: now,
        lastAccessedAt: now,
      );

      await widget.dbService.insertUnit(newUnit);
      await widget.dbService.savePicklistItems(unitId, parsedItems);
      await widget.dbService.saveDepartments(unitId, deptList);

      await _loadUnits();
      setState(() {
        _selectedUnit = newUnit;
        _currentStep = 2;
      });
      await _loadDepartments(newUnit);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: AppTheme.statusDanger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  // ─── Step 3: Department Loading ───────────────────────────────

  Future<void> _loadDepartments(UnitRecord unit) async {
    final depts = await widget.dbService.getDepartmentsForUnit(unit.id);
    final deptUrgencies = await widget.dbService.getDepartmentPickDates(unit.id);
    final deptProgress = <String, Map<String, int>>{};
    for (final dept in depts.keys) {
      deptProgress[dept] = await widget.dbService.getDepartmentPartProgress(unit.id, dept);
    }
    setState(() {
      _departments = depts;
      _departmentUrgencies = deptUrgencies;
      _departmentPartProgress = deptProgress;
      // Pre-select the first active department if only one is active
      final activeDepts = depts.entries.where((e) => e.value).map((e) => e.key).toList();
      _selectedDepartment = activeDepts.length == 1 ? activeDepts.first : null;
    });
  }

  // ─── Start Session & Navigate to Picking ─────────────────────

  Future<void> _startSessionAndNavigate() async {
    if (_selectedUnit == null || _selectedDepartment == null) return;

    // Check for an existing open session on this unit.
    final existingSession = await widget.dbService.getActiveSession(_selectedUnit!.id);
    if (existingSession != null && mounted) {
      final isSameWorker = existingSession.workerName.trim().toLowerCase() == _workerName.trim().toLowerCase();
      if (isSameWorker) {
        // Picker is switching departments or returning within active session — reuse it seamlessly!
        final updatedUnit = _selectedUnit!.copyWith(
          lastAccessedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await widget.dbService.updateUnit(updatedUnit);
        LogService.picker('$_workerName → dept $_selectedDepartment (resume session)');
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PickingScreen(
              dbService: widget.dbService,
              storageManager: widget.storageManager,
              excelService: widget.excelService,
              columnMapper: widget.columnMapper,
              initialUnit: updatedUnit,
              initialSession: existingSession,
              initialDepartment: _selectedDepartment,
            ),
          ),
        );
        if (mounted) {
          _loadUnits();
          if (_selectedUnit != null) _loadDepartments(_selectedUnit!);
        }
        return;
      }

      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppTheme.statusPartial),
              SizedBox(width: 10),
              Text('Unfinished Session Found', style: TextStyle(color: AppTheme.textLight)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Unit "${_selectedUnit!.name}" already has an open session:',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 14),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderDark),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Session: ${existingSession.sessionSeqNo > 0 ? '#${existingSession.sessionSeqNo}' : existingSession.id.substring(0, 8)}', style: const TextStyle(color: AppTheme.accentCyan, fontSize: 13, fontWeight: FontWeight.bold)),
                    Text('Picker: ${existingSession.workerName}', style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    Text('Started: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(existingSession.startTime))}', style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    Text('Items picked: ${existingSession.totalItemsPicked}', style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'What would you like to do?',
                style: TextStyle(color: AppTheme.textLight, fontSize: 14),
              ),
            ],
          ),
          actions: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textMuted,
                side: const BorderSide(color: AppTheme.borderDark),
              ),
              onPressed: () => Navigator.of(ctx).pop('new'),
              child: const Text('Start Fresh Session'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.statusComplete,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
              label: const Text(
                'Resume Existing Session',
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15),
              ),
              onPressed: () => Navigator.of(ctx).pop('resume'),
            ),
          ],
        ),
      );

      if (!mounted) return;
      if (choice == 'resume') {
        // Resume the existing session — navigate directly without creating a new one.
        final updatedUnit = _selectedUnit!.copyWith(
          lastAccessedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await widget.dbService.updateUnit(updatedUnit);
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PickingScreen(
              dbService: widget.dbService,
              storageManager: widget.storageManager,
              excelService: widget.excelService,
              columnMapper: widget.columnMapper,
              initialUnit: updatedUnit,
              initialSession: existingSession,
              initialDepartment: _selectedDepartment,
            ),
          ),
        );
        if (mounted) {
          _loadUnits();
          if (_selectedUnit != null) _loadDepartments(_selectedUnit!);
        }
        return;
      }
      // choice == 'new': delete if empty, otherwise close/abandon old session, then create a new one below.
      if (choice == 'new') {
        if (existingSession.totalItemsPicked <= 0) {
          // Empty session — delete it so seq counter doesn't waste a number
          await widget.dbService.deleteEmptySession(existingSession.id);
        } else {
          await widget.dbService.closeSession(
            existingSession.id,
            DateTime.now().millisecondsSinceEpoch,
            existingSession.totalItemsPicked,
          );
        }
      }
    }

    // Create and save new session.
    final now = DateTime.now();
    final uuid = const Uuid().v4();
    final sessionId = uuid;

    final seqNo = await widget.dbService.nextSessionSeqNo(_selectedUnit!.id);
    final tabletId = await widget.dbService.getConfig('tablet_id') ?? 'Tablet 1';

    final session = SessionMetadata(
      id: sessionId,
      sessionSeqNo: seqNo,
      unitId: _selectedUnit!.id,
      workerName: _workerName,
      tabletId: tabletId,
      startTime: now.millisecondsSinceEpoch,
      pickDate: DateFormat('yyyy-MM-dd').format(now),
      status: 'ACTIVE',
      issuedStatus: 'Pending',
      totalItemsPicked: 0,
    );

    await widget.dbService.saveSession(session);
    LogService.picker('$_workerName → new session #${session.sessionSeqNo} on ${_selectedUnit!.name} / $_selectedDepartment');

    // Update last accessed timestamp
    final updatedUnit = _selectedUnit!.copyWith(
      lastAccessedAt: now.millisecondsSinceEpoch,
    );
    await widget.dbService.updateUnit(updatedUnit);

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PickingScreen(
          dbService: widget.dbService,
          storageManager: widget.storageManager,
          excelService: widget.excelService,
          columnMapper: widget.columnMapper,
          initialUnit: updatedUnit,
          initialSession: session,
          initialDepartment: _selectedDepartment,
        ),
      ),
    );

    if (mounted) {
      _loadUnits();
      if (_selectedUnit != null) _loadDepartments(_selectedUnit!);
    }
  }


  Future<void> _promptExitFromPicker() async {
    final activeSessions = await widget.dbService.getAllActiveSessions();
    final session = activeSessions.isNotEmpty ? activeSessions.first : null;
    final worker = _workerName.isNotEmpty ? _workerName : (session?.workerName ?? 'Worker');

    if (!mounted) return;

    final pinCtrl = TextEditingController();
    String? inlineError;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          title: Row(
            children: [
              const Icon(Icons.exit_to_app_rounded, color: AppTheme.accentCyan, size: 24),
              const SizedBox(width: 10),
              Flexible(
                child: Text('Exit Picker ($worker)', style: const TextStyle(color: AppTheme.textLight, fontSize: 18), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session != null
                    ? 'Active session is in progress for $worker.\nTo change worker or exit to Home, close the session or enter Admin PIN.'
                    : 'Worker name is locked to $worker.\nTo change worker or exit to Home, enter Admin PIN.',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pinCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                style: const TextStyle(color: AppTheme.textLight, fontSize: 18),
                decoration: InputDecoration(
                  hintText: 'Enter Admin PIN to exit',
                  errorText: inlineError,
                  prefixIcon: const Icon(Icons.lock_outline, color: AppTheme.textMuted),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Stay in Picker'),
            ),
            if (session != null)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE07B00)),
                icon: const Icon(Icons.lock_clock_rounded, size: 16),
                label: const Text('End Session & Exit'),
                onPressed: () async {
                  final now = DateTime.now().millisecondsSinceEpoch;
                  final activeSessions = await widget.dbService.getAllActiveSessions();
                  for (final s in activeSessions) {
                    if (s.totalItemsPicked > 0) {
                      final unit = await widget.dbService.getUnit(s.unitId);
                      if (unit != null) {
                        try {
                          final exportDir = await widget.dbService.getLastExportDir();
                          final dir = (exportDir != null && exportDir.isNotEmpty)
                              ? exportDir
                              : File(unit.filePath).parent.path;
                          final closedSession = s.copyWith(
                            status: 'EXPORTED',
                            endTime: now,
                          );
                          final outputPath = p.join(
                            dir,
                            closedSession.buildExportFileName(unit.name, customEndTime: now),
                          );
                          final items = await widget.dbService.getPicklistItems(unit.id);
                          final returnComments = await widget.dbService.getReturnCommentsForUnit(unit.id);
                          final autoIssueRes = await widget.dbService.getAutoIssueResourceIds();
                          await widget.excelService.exportAndOverwrite(
                            originalFilePath: unit.filePath,
                            items: items,
                            session: closedSession,
                            unitName: unit.name,
                            returnComments: returnComments,
                            outputPath: outputPath,
                            autoIssueResourceIds: autoIssueRes,
                          );
                          await widget.dbService.finishSession(s.id, now, s.totalItemsPicked, 'Exported');
                          LogService.picker('Session ${s.id} auto-exported on exit to $outputPath');
                        } catch (e) {
                          LogService.error('PickerFlow', 'Auto-export on exit failed for session ${s.id}', stackTrace: e.toString());
                        }
                      }
                    }
                  }
                  await widget.dbService.closeAllActiveSessions(endTime: now);
                  LogService.picker('All active sessions ended by "$worker" from exit menu');
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (mounted) Navigator.of(context).pop();
                },
              )
            else
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE07B00)),
                onPressed: () {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (mounted) {
                    setState(() {
                      _workerName = '';
                      _nameController.clear();
                      _currentStep = 0;
                    });
                    Navigator.of(context).pop();
                  }
                },
                child: const Text('Exit & Reset Name'),
              ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryBlue),
              onPressed: () async {
                final pin = pinCtrl.text.trim();
                final ok = await widget.dbService.verifyAdminPin(pin);
                if (ok) {
                  ScaffoldMessenger.of(context).clearSnackBars();
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (mounted) Navigator.of(context).pop();
                } else {
                  setDialogState(() {
                    inlineError = 'Incorrect Admin PIN';
                  });
                }
              },
              child: const Text('Admin Exit'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleStepBack() async {
    if (_currentStep == 2) {
      // Step 3 (Dept) -> Step 2 (Unit) freely without PIN!
      setState(() => _currentStep = 1);
      return;
    }
    if (_currentStep == 1) {
      final activeSessions = await widget.dbService.getAllActiveSessions();
      if (activeSessions.isNotEmpty) {
        await _promptExitFromPicker();
      } else {
        // No session active yet! Allow safely returning to Step 0 (Worker Name)
        setState(() => _currentStep = 0);
      }
      return;
    }
    // Step 0 (Worker Name) -> exit back to HomeScreen freely!
    Navigator.of(context).pop();
  }

  // ─── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleStepBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Start Picking Session'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _handleStepBack,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.home_outlined),
              tooltip: 'Exit to Home Screen',
              onPressed: () async {
                final activeSessions = await widget.dbService.getAllActiveSessions();
                if (activeSessions.isNotEmpty) {
                  await _promptExitFromPicker();
                } else {
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
        ),
      body: SafeArea(
        child: Column(
          children: [
            // Progress Stepper
            _buildStepIndicator(),
            const SizedBox(height: 8),
            const Divider(color: AppTheme.borderDark, height: 1),

            // Step Content
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _buildCurrentStep(),
              ),
            ),

            // Bottom Navigation
            _buildBottomBar(),
          ],
        ),
      ),
    ),
  );
}

  Widget _buildStepIndicator() {
    final steps = ['Worker Name', 'Select Unit', 'Select Department'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: List.generate(steps.length, (i) {
          final isActive = i == _currentStep;
          final isDone = i < _currentStep;
          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone
                        ? AppTheme.statusComplete
                        : isActive
                            ? AppTheme.primaryBlue
                            : AppTheme.borderDark,
                  ),
                  child: Center(
                    child: isDone
                        ? const Icon(Icons.check, size: 18, color: Colors.white)
                        : Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: isActive ? Colors.white : AppTheme.textMuted,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    steps[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                      color: isActive ? AppTheme.textLight : AppTheme.textMuted,
                    ),
                  ),
                ),
                if (i < steps.length - 1)
                  Container(
                    width: 32,
                    height: 2,
                    color: isDone ? AppTheme.statusComplete : AppTheme.borderDark,
                    margin: const EdgeInsets.only(right: 8),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case 0:
        return _buildStep1Name();
      case 1:
        return _buildStep2UnitSelect();
      case 2:
        return _buildStep3DeptSelect();
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── Step 1: Worker Name ──────────────────────────────────────
  Widget _buildStep1Name() {
    return Padding(
      key: const ValueKey('step1'),
      padding: const EdgeInsets.all(32),
      child: Form(
        key: _nameFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Who is picking today?',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.textLight),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your name will be recorded in the session and exported to the Excel file.',
              style: TextStyle(fontSize: 14, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 18),
            // Live Active Picker Indicator Card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: _nameController.text.trim().isNotEmpty
                    ? AppTheme.primaryBlue.withValues(alpha: 0.15)
                    : AppTheme.cardDark,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _nameController.text.trim().isNotEmpty
                      ? AppTheme.accentCyan
                      : AppTheme.borderDark,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _nameController.text.trim().isNotEmpty
                          ? AppTheme.accentCyan.withValues(alpha: 0.2)
                          : AppTheme.borderDark,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.person_pin,
                      color: _nameController.text.trim().isNotEmpty
                          ? AppTheme.accentCyan
                          : AppTheme.textMuted,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CURRENT ACTIVE PICKER',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _nameController.text.trim().isNotEmpty
                            ? _nameController.text.trim()
                            : 'None selected yet — tap below or type',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _nameController.text.trim().isNotEmpty
                              ? AppTheme.textLight
                              : AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const SizedBox(height: 24),
            const Text(
              'Select Your Name:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textLight),
            ),
            const SizedBox(height: 12),
            if (_standardPickers.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.statusDanger.withValues(alpha: 0.5)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: AppTheme.statusDanger, size: 28),
                    SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'No workers configured on this tablet.\nPlease ask an Administrator to add pickers in Admin settings (Tab 1).',
                        style: TextStyle(color: AppTheme.textLight, fontSize: 14, height: 1.4),
                      ),
                    ),
                  ],
                ),
              )
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final picker in _standardPickers)
                    ActionChip(
                      avatar: CircleAvatar(
                        backgroundColor: _nameController.text.trim() == picker
                            ? AppTheme.accentCyan
                            : AppTheme.primaryBlue,
                        child: Text(
                          picker.isNotEmpty ? picker[0].toUpperCase() : '?',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: _nameController.text.trim() == picker
                                ? AppTheme.bgDark
                                : Colors.white,
                          ),
                        ),
                      ),
                      label: Text(
                        picker,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: _nameController.text.trim() == picker ? FontWeight.bold : FontWeight.w600,
                          color: _nameController.text.trim() == picker ? AppTheme.accentCyan : AppTheme.textLight,
                        ),
                      ),
                      backgroundColor: _nameController.text.trim() == picker
                          ? AppTheme.accentCyan.withValues(alpha: 0.15)
                          : AppTheme.cardDark,
                      side: BorderSide(
                        color: _nameController.text.trim() == picker
                            ? AppTheme.accentCyan
                            : AppTheme.borderDark,
                        width: _nameController.text.trim() == picker ? 2 : 1.2,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      onPressed: () {
                        setState(() {
                          _nameController.text = picker;
                          _workerName = picker;
                        });
                      },
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ─── Step 2: Unit Selection ───────────────────────────────────
  Widget _buildStep2UnitSelect() {
    return _isImporting
        ? const Center(
            key: ValueKey('step2_loading'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Importing Excel file...', style: TextStyle(color: AppTheme.textMuted)),
              ],
            ),
          )
        : Column(
            key: const ValueKey('step2'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Select Your Unit',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                        ),
                        Text(
                          '${_availableUnits.length} / 40 units loaded in device',
                          style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.upload_file_rounded, size: 20),
                      label: const Text('Import New File'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        minimumSize: const Size(160, 46),
                      ),
                      onPressed: _importNewFile,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _availableUnits.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.folder_open_rounded, size: 64, color: AppTheme.borderDark),
                            const SizedBox(height: 16),
                            const Text(
                              'No files imported yet.',
                              style: TextStyle(fontSize: 18, color: AppTheme.textMuted),
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.upload_file_rounded),
                              label: const Text('Import Excel Picklist'),
                              onPressed: _importNewFile,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                        itemCount: _availableUnits.length,
                        itemBuilder: (ctx, i) {
                          final unit = _availableUnits[i];
                          final isSelected = _selectedUnit?.id == unit.id;
                          final urgency = _unitUrgencies[unit.id];

                          Color urgencyBorderColor;
                          Color? glowColor;
                          Widget? urgencyBadge;

                          if (urgency != null) {
                            switch (urgency.status) {
                              case UnitUrgencyStatus.pastDue:
                                urgencyBorderColor = const Color(0xFFFF3B30);
                                glowColor = const Color(0xFFFF3B30).withOpacity(0.35);
                                final days = urgency.daysRemaining?.abs() ?? 0;
                                final daysText = days == 0 ? 'Due Today' : '$days d overdue';
                                urgencyBadge = Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF3B30).withOpacity(0.18),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFFFF3B30), width: 1.2),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.error_outline_rounded, color: Color(0xFFFF3B30), size: 14),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          'Earliest Pick: ${UnitPickDateUrgency.formatShortDate(urgency.earliestPickDateStr)} ($daysText) • Dept: ${urgency.department ?? ""}',
                                          style: const TextStyle(
                                            color: Color(0xFFFF3B30),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                break;

                              case UnitUrgencyStatus.dueSoon:
                                urgencyBorderColor = const Color(0xFFFFB300);
                                glowColor = const Color(0xFFFFB300).withOpacity(0.30);
                                final days = urgency.daysRemaining ?? 0;
                                final daysText = days == 0 ? 'Due Today' : 'Due in $days d';
                                urgencyBadge = Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFB300).withOpacity(0.18),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFFFFB300), width: 1.2),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.timer_outlined, color: Color(0xFFFFB300), size: 14),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          'Earliest Pick: ${UnitPickDateUrgency.formatShortDate(urgency.earliestPickDateStr)} ($daysText) • Dept: ${urgency.department ?? ""}',
                                          style: const TextStyle(
                                            color: Color(0xFFFFB300),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                break;

                              case UnitUrgencyStatus.normal:
                                urgencyBorderColor = const Color(0xFF2196F3);
                                glowColor = const Color(0xFF2196F3).withOpacity(0.25);
                                final days = urgency.daysRemaining ?? 0;
                                urgencyBadge = Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2196F3).withOpacity(0.14),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF2196F3), width: 1),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.event_available_rounded, color: Color(0xFF2196F3), size: 14),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          'Earliest Pick: ${UnitPickDateUrgency.formatShortDate(urgency.earliestPickDateStr)} (in $days d) • Dept: ${urgency.department ?? ""}',
                                          style: const TextStyle(
                                            color: Color(0xFF2196F3),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                break;

                              case UnitUrgencyStatus.completed:
                                urgencyBorderColor = AppTheme.statusComplete;
                                glowColor = AppTheme.statusComplete.withOpacity(0.25);
                                urgencyBadge = Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.statusComplete.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: AppTheme.statusComplete, width: 1),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.check_circle_outline_rounded, color: AppTheme.statusComplete, size: 14),
                                      SizedBox(width: 6),
                                      Text(
                                        'All Parts Completed',
                                        style: TextStyle(
                                          color: AppTheme.statusComplete,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                break;

                              case UnitUrgencyStatus.none:
                                urgencyBorderColor = isSelected ? AppTheme.accentCyan : AppTheme.borderDark;
                                glowColor = null;
                                urgencyBadge = null;
                                break;
                            }
                          } else {
                            urgencyBorderColor = isSelected ? AppTheme.accentCyan : AppTheme.borderDark;
                            glowColor = null;
                            urgencyBadge = null;
                          }

                          return GestureDetector(
                            onTap: () => setState(() => _selectedUnit = unit),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              margin: const EdgeInsets.symmetric(vertical: 7),
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppTheme.primaryBlue.withOpacity(0.18)
                                    : AppTheme.cardDark,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isSelected ? AppTheme.accentCyan : urgencyBorderColor,
                                  width: isSelected ? 2.5 : (glowColor != null ? 1.8 : 1),
                                ),
                                boxShadow: glowColor != null
                                    ? [
                                        BoxShadow(
                                          color: glowColor,
                                          blurRadius: 12,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Icon(
                                      unit.isCompleted
                                          ? Icons.check_circle_rounded
                                          : Icons.pending_actions_rounded,
                                      color: unit.isCompleted ? AppTheme.statusComplete : AppTheme.statusPartial,
                                      size: 28,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Builder(
                                      builder: (context) {
                                        final partInfo = _unitPartProgress[unit.id];
                                        final totalParts = partInfo?['totalParts'] ?? 0;
                                        final completedParts = partInfo?['completedParts'] ?? 0;
                                        final partPct = totalParts > 0
                                            ? (completedParts / totalParts * 100).toStringAsFixed(1)
                                            : '0.0';
                                        final partProgressVal = totalParts > 0
                                            ? (completedParts / totalParts).clamp(0.0, 1.0)
                                            : 0.0;

                                        return Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              unit.name,
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: isSelected ? AppTheme.accentCyan : AppTheme.textLight,
                                              ),
                                            ),
                                            if (urgencyBadge != null) ...[
                                              const SizedBox(height: 6),
                                              urgencyBadge,
                                            ],
                                            const SizedBox(height: 6),
                                            LinearProgressIndicator(
                                              value: partProgressVal,
                                              backgroundColor: AppTheme.bgDark,
                                              valueColor: AlwaysStoppedAnimation<Color>(
                                                unit.isCompleted ? AppTheme.statusComplete : AppTheme.statusPartial,
                                              ),
                                              minHeight: 6,
                                              borderRadius: BorderRadius.circular(3),
                                            ),
                                            const SizedBox(height: 5),
                                            Row(
                                              children: [
                                                Text(
                                                  '$completedParts / $totalParts parts ($partPct%)',
                                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  '• ${unit.totalPicked}/${unit.totalRequired} pcs • ${unit.status}',
                                                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                                                ),
                                              ],
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: isSelected
                                        ? const Icon(Icons.check_rounded, color: AppTheme.accentCyan, size: 28)
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
  }

  // ─── Step 3: Department Selection ────────────────────────────
  Widget _buildStep3DeptSelect() {
    final activeDepts = _departments.entries.where((e) => e.value).map((e) => e.key).toList();
    final inactiveDepts = _departments.entries.where((e) => !e.value).map((e) => e.key).toList();

    return Column(
      key: const ValueKey('step3'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your Department',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textLight),
              ),
              Text(
                'Unit: ${_selectedUnit?.name ?? ""}',
                style: const TextStyle(fontSize: 14, color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
        Expanded(
          child: activeDepts.isEmpty
              ? const Center(
                  child: Text(
                    'No active departments. Ask admin to enable departments.',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  children: [
                    const Text('Available departments:', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                    const SizedBox(height: 10),
                    ...activeDepts.map((dept) {
                      final isSelected = _selectedDepartment == dept;
                      final deptUrgency = _departmentUrgencies[dept];
                      final partInfo = _departmentPartProgress[dept];
                      final totalParts = partInfo?['totalParts'] ?? 0;
                      final completedParts = partInfo?['completedParts'] ?? 0;
                      final missingParts = partInfo?['missingParts'] ?? 0;
                      final pendingParts = (totalParts - completedParts).clamp(0, totalParts);
                      final isDeptCompleted = (deptUrgency?.isAllCompleted == true) || (totalParts > 0 && completedParts >= totalParts);
                      final partPct = totalParts > 0
                          ? (completedParts / totalParts * 100).toStringAsFixed(1)
                          : '0.0';
                      final partProgressVal = totalParts > 0
                          ? (completedParts / totalParts).clamp(0.0, 1.0)
                          : 0.0;

                      Color deptBorderColor = isSelected ? const Color(0xFF00B0FF) : AppTheme.borderDark;
                      Color? deptGlow;
                      if (isSelected) {
                        deptGlow = const Color(0xFF00B0FF).withValues(alpha: 0.35);
                      } else if (deptUrgency != null) {
                        if (deptUrgency.status == UnitUrgencyStatus.pastDue) {
                          deptBorderColor = const Color(0xFFFF3B30);
                          deptGlow = const Color(0xFFFF3B30).withValues(alpha: 0.3);
                        } else if (deptUrgency.status == UnitUrgencyStatus.dueSoon) {
                          deptBorderColor = const Color(0xFFFFB300);
                          deptGlow = const Color(0xFFFFB300).withValues(alpha: 0.25);
                        } else if (deptUrgency.status == UnitUrgencyStatus.normal) {
                          deptBorderColor = const Color(0xFF2196F3);
                          deptGlow = const Color(0xFF2196F3).withValues(alpha: 0.20);
                        } else if (deptUrgency.status == UnitUrgencyStatus.completed) {
                          deptBorderColor = AppTheme.statusComplete;
                          deptGlow = AppTheme.statusComplete.withValues(alpha: 0.2);
                        }
                      }

                      return GestureDetector(
                        onTap: () {
                          setState(() => _selectedDepartment = dept);
                          LogService.info('USER_ACTION', 'Department selected: $dept on unit "${_selectedUnit?.name}"');
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF091E3A)
                                : AppTheme.cardDark,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF00B0FF) : deptBorderColor,
                              width: isSelected ? 2.5 : (deptGlow != null ? 1.6 : 1),
                            ),
                            boxShadow: deptGlow != null
                                ? [
                                    BoxShadow(
                                      color: deptGlow,
                                      blurRadius: isSelected ? 10 : 8,
                                      spreadRadius: isSelected ? 1.5 : 1,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected
                                    ? Icons.radio_button_checked_rounded
                                    : (isDeptCompleted
                                        ? Icons.check_circle_rounded
                                        : Icons.apartment_rounded),
                                color: isSelected
                                    ? const Color(0xFF00B0FF)
                                    : (isDeptCompleted
                                        ? AppTheme.statusComplete
                                        : (deptUrgency?.status == UnitUrgencyStatus.pastDue
                                            ? const Color(0xFFFF3B30)
                                            : (deptUrgency?.status == UnitUrgencyStatus.dueSoon
                                                ? const Color(0xFFFFB300)
                                                : (deptUrgency?.status == UnitUrgencyStatus.normal
                                                    ? const Color(0xFF2196F3)
                                                    : AppTheme.textMuted)))),
                                size: 26,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      dept,
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: isSelected ? const Color(0xFFE0F2FE) : AppTheme.textLight,
                                      ),
                                    ),
                                    if (deptUrgency != null && !isDeptCompleted && deptUrgency.earliestPickDateStr != null && deptUrgency.earliestPickDateStr!.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        'Pick Date: ${UnitPickDateUrgency.formatShortDate(deptUrgency.earliestPickDateStr)} • ${deptUrgency.status == UnitUrgencyStatus.pastDue ? "PAST DUE (${deptUrgency.daysRemaining?.abs()}d ago)" : (deptUrgency.status == UnitUrgencyStatus.dueSoon ? "DUE SOON (${deptUrgency.daysRemaining}d left)" : "NORMAL (${deptUrgency.daysRemaining}d left)")}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: deptUrgency.status == UnitUrgencyStatus.pastDue
                                              ? const Color(0xFFFF3B30)
                                              : (deptUrgency.status == UnitUrgencyStatus.dueSoon
                                                  ? const Color(0xFFFFB300)
                                                  : (deptUrgency.status == UnitUrgencyStatus.normal
                                                      ? const Color(0xFF2196F3)
                                                      : AppTheme.textMuted)),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 8),
                                    LinearProgressIndicator(
                                      value: partProgressVal,
                                      backgroundColor: AppTheme.bgDark,
                                      valueColor: AlwaysStoppedAnimation(
                                        isDeptCompleted
                                            ? AppTheme.statusComplete
                                            : (isSelected ? const Color(0xFF00B0FF) : AppTheme.accentCyan),
                                      ),
                                      minHeight: 6,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 8,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      runSpacing: 4,
                                      children: [
                                        Text(
                                          '$completedParts / $totalParts parts ($partPct%)',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: isDeptCompleted ? AppTheme.statusComplete : (isSelected ? const Color(0xFF00B0FF) : AppTheme.accentCyan),
                                          ),
                                        ),
                                        Text(
                                          isDeptCompleted ? '• All parts completed' : '• $pendingParts pending',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: isDeptCompleted ? FontWeight.bold : FontWeight.normal,
                                            color: isDeptCompleted ? AppTheme.statusComplete : AppTheme.textMuted,
                                          ),
                                        ),
                                        if (missingParts > 0)
                                          Text(
                                            '• $missingParts missing',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFFFF3B30),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (isSelected)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00B0FF).withValues(alpha: 0.22),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF00B0FF), width: 1.5),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.check_circle_rounded, color: Color(0xFF00B0FF), size: 16),
                                      SizedBox(width: 6),
                                      Text(
                                        'SELECTED',
                                        style: TextStyle(
                                          color: Color(0xFF00B0FF),
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else if (isDeptCompleted)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.statusComplete.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: AppTheme.statusComplete.withValues(alpha: 0.5)),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.check_rounded, color: AppTheme.statusComplete, size: 14),
                                      SizedBox(width: 4),
                                      Text(
                                        'COMPLETED',
                                        style: TextStyle(
                                          color: AppTheme.statusComplete,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                    if (inactiveDepts.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      const Text(
                        'Not assigned to this device (contact admin):',
                        style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 8),
                      ...inactiveDepts.map(
                        (dept) => Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          decoration: BoxDecoration(
                            color: AppTheme.bgDark,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.borderDark),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.lock_outline_rounded, size: 18, color: AppTheme.textMuted),
                              const SizedBox(width: 10),
                              Text(dept, style: const TextStyle(color: AppTheme.textMuted, fontSize: 16)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    String buttonLabel;
    switch (_currentStep) {
      case 0:
        buttonLabel = 'Continue to Unit Selection';
        break;
      case 1:
        buttonLabel = 'Continue to Department';
        break;
      case 2:
        final deptCompletedParts = (_selectedDepartment != null && _departmentPartProgress[_selectedDepartment] != null)
            ? (_departmentPartProgress[_selectedDepartment]!['completedParts'] ?? 0)
            : 0;
        final hasPicked = deptCompletedParts > 0 || (_selectedUnit?.totalPicked ?? 0) > 0;
        buttonLabel = hasPicked ? 'Start Picking' : 'Start Picking Session';
        break;
      default:
        buttonLabel = 'Continue';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
      decoration: const BoxDecoration(
        color: AppTheme.cardDark,
        border: Border(top: BorderSide(color: AppTheme.borderDark)),
      ),
      child: Row(
        children: [
          if (_currentStep > 0)
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(120, 52)),
              onPressed: _handleStepBack,
              child: const Text('Back'),
            ),
          if (_currentStep > 0) const SizedBox(width: 16),
          Expanded(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentStep == 2 ? AppTheme.statusComplete : AppTheme.primaryBlue,
                minimumSize: const Size(double.infinity, 54),
              ),
              onPressed: (_currentStep == 1 && _selectedUnit == null) ? null : _nextStep,
              child: Text(
                buttonLabel,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
