import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../engine/column_mapper.dart';
import '../../models/unit_record.dart';
import '../../services/database_service.dart';
import '../../services/log_service.dart';
import '../../services/storage_manager.dart';
import '../theme/app_theme.dart';

/// AdminScreen: PIN-protected configuration panel.
///
/// Tabs:
///  1. Department Filter   — toggle which departments this device can pick
///  2. Component Groups    — map departments to named picker specialties (e.g. PRIMA, Purchasing)
///  3. Column Mapper       — add custom Excel header aliases
///  4. Grouping Presets    — view all built-in hierarchy presets
///  5. Storage Manager     — view 40-unit DB usage, admin-delete units
class AdminScreen extends StatefulWidget {
  final DatabaseService dbService;
  final StorageManager storageManager;
  final ColumnMapper columnMapper;
  final String? activeUnitId;
  final VoidCallback onDataChanged;

  const AdminScreen({
    super.key,
    required this.dbService,
    required this.storageManager,
    required this.columnMapper,
    this.activeUnitId,
    required this.onDataChanged,
  });

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> with SingleTickerProviderStateMixin {
  bool _isAuthenticated = false;
  final _pinController = TextEditingController();
  String _currentPin = '1234';

  late TabController _tabController;

  // Tab 1 — General Settings
  String _tabletId = 'Tablet 1';
  final _tabletIdController = TextEditingController();
  bool _autoAdvancePick = false;

  // Tab 2 — Departments
  Map<String, bool> _departments = {};
  String? _selectedAdminUnitId;
  List<String> _allDistinctDepartments = [];

  // Tab 3 — Component Resources
  List<String> _allDistinctResources = [];
  List<String> _blockedResourceIds = [];
  List<String> _autoIssueResourceIds = [];

  // Tab 4 — Grouping Presets
  bool _groupByLine = true;
  Map<String, bool> _deptLineOverrides = {};
  Map<String, bool> _resourceLineOverrides = {};

  // Tab 5 — Storage
  List<UnitRecord> _storedUnits = [];
  bool _isLoading = false;

  // Standard Pickers
  List<String> _standardPickers = [];
  final _newPickerNameController = TextEditingController();

  // Tab 7 — System Logs (Super Admin Protected)
  bool _isSuperAdminAuthenticated = false;
  String _currentSuperAdminPin = '9999';
  final _superAdminPinController = TextEditingController();
  List<Map<String, dynamic>> _logs = [];
  Map<String, dynamic> _logsStats = {'count': 0, 'sizeBytes': 0};
  String _selectedLogLevel = 'ALL';
  final _logsSearchController = TextEditingController();
  bool _isLoadingLogs = false;

  DateTime? _lastAdminAuthTime;
  static const Duration _adminSessionTimeout = Duration(minutes: 15);
  Timer? _authInactivityTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _loadPin();
  }

  @override
  void dispose() {
    _authInactivityTimer?.cancel();
    _pinController.dispose();
    _tabletIdController.dispose();
    _newPickerNameController.dispose();
    _superAdminPinController.dispose();
    _logsSearchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPin() async {
    final pin = await widget.dbService.getConfig('admin_pin');
    if (pin != null) _currentPin = pin;
  }

  void _startInactivityTimer() {
    _authInactivityTimer?.cancel();
    _authInactivityTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkAdminSessionTimeout();
    });
  }

  /// Verifies whether the 15-minute admin session window is still valid.
  /// If expired, cancels session and redirects to HomeScreen.
  bool _ensureAdminSessionValid() {
    if (!_isAuthenticated) return false;
    return _checkAdminSessionTimeout();
  }

  bool _checkAdminSessionTimeout() {
    if (!_isAuthenticated) return false;
    if (_lastAdminAuthTime == null ||
        DateTime.now().difference(_lastAdminAuthTime!) >= _adminSessionTimeout) {
      _authInactivityTimer?.cancel();
      if (mounted) {
        setState(() {
          _isAuthenticated = false;
          _lastAdminAuthTime = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Admin session expired (15-minute timeout). Returning to Home.'),
            backgroundColor: AppTheme.statusDanger,
            duration: Duration(seconds: 4),
          ),
        );
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return false;
    }
    return true;
  }

  Future<void> _loadAdminData() async {
    setState(() => _isLoading = true);
    // General Settings
    final tabletId = await widget.dbService.getConfig('tablet_id');
    if (tabletId != null) {
      _tabletId = tabletId;
    }
    _tabletIdController.text = _tabletId;

    _autoAdvancePick = await widget.dbService.getAutoAdvancePick();
    _groupByLine = await widget.dbService.getGroupByLine();
    _deptLineOverrides = await widget.dbService.getLineGroupingDeptOverrides();
    _resourceLineOverrides = await widget.dbService.getLineGroupingResourceOverrides();
    _allDistinctResources = await widget.dbService.getAllDistinctResourceIds();
    _blockedResourceIds = await widget.dbService.getBlockedResourceIds();
    _autoIssueResourceIds = await widget.dbService.getAutoIssueResourceIds();

    // Standard Pickers
    _standardPickers = await widget.dbService.getStandardPickers();

    // Super Admin PIN
    final sap = await widget.dbService.getConfig('super_admin_pin');
    if (sap != null) _currentSuperAdminPin = sap;

    if (_isSuperAdminAuthenticated) {
      await _loadLogs();
    }

    // Units
    _storedUnits = await widget.dbService.getAllUnits();
    if (_selectedAdminUnitId == null || !_storedUnits.any((u) => u.id == _selectedAdminUnitId)) {
      _selectedAdminUnitId = widget.activeUnitId ?? (_storedUnits.isNotEmpty ? _storedUnits.first.id : null);
    }

    // Global departments across all units (auto-added from imported picklists)
    _departments = await widget.dbService.getGlobalDepartments();
    _allDistinctDepartments = _departments.keys.toList();

    setState(() => _isLoading = false);
  }

  void _verifyPin() {
    if (_pinController.text.trim() == _currentPin) {
      LogService.admin('Admin panel unlocked with PIN');
      _lastAdminAuthTime = DateTime.now();
      _startInactivityTimer();
      setState(() => _isAuthenticated = true);
      _loadAdminData();
    } else {
      LogService.warn('Admin', 'Invalid Admin PIN entered');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid PIN. Please try again.'),
          backgroundColor: AppTheme.statusDanger,
        ),
      );
      _pinController.clear();
    }
  }

  void _showChangePinDialog() {
    final newPinController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Text('Change Admin PIN', style: TextStyle(color: AppTheme.textLight)),
        content: TextField(
          controller: newPinController,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          style: const TextStyle(color: AppTheme.textLight, fontSize: 20),
          decoration: const InputDecoration(
            hintText: 'Enter new 4–6 digit PIN',
            hintStyle: TextStyle(color: AppTheme.textMuted),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newPin = newPinController.text.trim();
              if (newPin.length >= 4) {
                await widget.dbService.setConfig('admin_pin', newPin);
                _currentPin = newPin;
                await LogService.admin('Admin PIN was changed');
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Admin PIN successfully updated!'),
                    backgroundColor: AppTheme.statusComplete,
                  ),
                );
              }
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAuthenticated) return _buildPinGate();
    if (!_ensureAdminSessionValid()) {
      return const Scaffold(
        backgroundColor: AppTheme.bgDark,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _ensureAdminSessionValid(),
      child: Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.admin_panel_settings_rounded, color: AppTheme.accentCyan),
              SizedBox(width: 10),
              Text('Admin & Device Configuration'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.password_rounded),
              tooltip: 'Change PIN',
              onPressed: _showChangePinDialog,
            ),
            const SizedBox(width: 8),
          ],
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: AppTheme.accentCyan,
            labelColor: AppTheme.accentCyan,
            unselectedLabelColor: AppTheme.textMuted,
            isScrollable: true,
            tabs: const [
              Tab(icon: Icon(Icons.settings_rounded), text: 'General'),
              Tab(icon: Icon(Icons.apartment_rounded), text: 'Departments'),
              Tab(icon: Icon(Icons.precision_manufacturing_rounded), text: 'Component Resources'),
              Tab(icon: Icon(Icons.view_column_rounded), text: 'Column Mapper'),
              Tab(icon: Icon(Icons.layers_rounded), text: 'Grouping Presets'),
              Tab(icon: Icon(Icons.storage_rounded), text: 'Storage'),
              Tab(icon: Icon(Icons.terminal_rounded), text: 'System Logs'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _tabController,
                children: [
                  _buildGeneralSettingsTab(),
                  _buildDepartmentFilterTab(),
                  _buildComponentResourcesTab(),
                  _buildColumnMapperTab(),
                  _buildGroupingPresetsTab(),
                  _buildStorageTab(),
                  _buildSystemLogsTab(),
                ],
              ),
      ),
    );
  }

  // ─── Tab 1: General Settings ──────────────────────────────────────────────

  Widget _buildGeneralSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Device Configuration',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textLight),
        ),
        const SizedBox(height: 8),
        const Text(
          'Set a unique Tablet ID for this device. This ID is used as a prefix for all exported Excel files to prevent naming conflicts when multiple tablets export to the same location.',
          style: TextStyle(color: AppTheme.textMuted, height: 1.5),
        ),
        const SizedBox(height: 24),
        Card(
          color: AppTheme.bgDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Tablet ID', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.accentCyan)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _tabletIdController,
                        style: const TextStyle(color: AppTheme.textLight),
                        decoration: const InputDecoration(
                          hintText: 'e.g. TAB-01',
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.save_rounded, size: 18),
                      label: const Text('Save ID'),
                      onPressed: () async {
                        if (!_ensureAdminSessionValid()) return;
                        final val = _tabletIdController.text.trim();
                        if (val.isNotEmpty) {
                          await widget.dbService.setConfig('tablet_id', val);
                          setState(() => _tabletId = val);
                          await LogService.admin('Tablet ID updated to "$val"');
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Tablet ID saved!'), backgroundColor: AppTheme.statusComplete),
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Card(
          color: AppTheme.bgDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pick Mode Auto-Advance',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Control behavior when entering a quantity in Pick Mode (Full-Screen).',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-advance to next part', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textLight)),
                  subtitle: Text(
                    _autoAdvancePick
                        ? 'Active: Automatically advances to next Part ID when picked'
                        : 'Inactive: Stays on current Part ID until manually navigating',
                    style: TextStyle(fontSize: 12, color: _autoAdvancePick ? AppTheme.statusComplete : AppTheme.textMuted),
                  ),
                  value: _autoAdvancePick,
                  activeColor: AppTheme.accentCyan,
                  onChanged: (val) async {
                    if (!_ensureAdminSessionValid()) return;
                    await widget.dbService.setAutoAdvancePick(val);
                    setState(() => _autoAdvancePick = val);
                    await LogService.admin('Auto-advance pick set to $val');
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Card(
          color: AppTheme.bgDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Standard Pickers',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Manage picker names that appear as quick-select options on the login screen.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 16),
                if (_standardPickers.isEmpty)
                  const Text('No standard pickers added yet.', style: TextStyle(color: AppTheme.textMuted, fontSize: 13))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in _standardPickers)
                        Chip(
                          avatar: CircleAvatar(
                            backgroundColor: AppTheme.primaryBlue,
                            child: Text(
                              p.isNotEmpty ? p[0].toUpperCase() : '?',
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                            ),
                          ),
                          label: Text(p, style: const TextStyle(color: AppTheme.textLight)),
                          backgroundColor: AppTheme.cardDark,
                          deleteIcon: const Icon(Icons.close, size: 16, color: AppTheme.statusDanger),
                          onDeleted: () async {
                            if (!_ensureAdminSessionValid()) return;
                            final updated = List<String>.from(_standardPickers)..remove(p);
                            await widget.dbService.saveStandardPickers(updated);
                            setState(() => _standardPickers = updated);
                            await LogService.admin('Standard picker "$p" removed');
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newPickerNameController,
                        style: const TextStyle(color: AppTheme.textLight),
                        decoration: const InputDecoration(
                          hintText: 'New worker name...',
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Add'),
                      onPressed: () async {
                        if (!_ensureAdminSessionValid()) return;
                        final name = _newPickerNameController.text.trim();
                        if (name.isNotEmpty && !_standardPickers.contains(name)) {
                          final updated = List<String>.from(_standardPickers)..add(name);
                          await widget.dbService.saveStandardPickers(updated);
                          _newPickerNameController.clear();
                          setState(() => _standardPickers = updated);
                          await LogService.admin('Standard picker "$name" added');
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Picker "$name" added!'), backgroundColor: AppTheme.statusComplete),
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── PIN Gate ─────────────────────────────────────────────────────────────

  Widget _buildPinGate() {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Authentication')),
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.borderDark),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_rounded, size: 54, color: AppTheme.accentCyan),
              const SizedBox(height: 16),
              const Text(
                'Enter Admin PIN',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textLight),
              ),
              const SizedBox(height: 8),
              const Text('Default PIN is 1234', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
              const SizedBox(height: 20),
              TextField(
                controller: _pinController,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 26, letterSpacing: 8, color: AppTheme.textLight),
                decoration: InputDecoration(
                  hintText: '••••',
                  filled: true,
                  fillColor: AppTheme.bgDark,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onSubmitted: (_) => _verifyPin(),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
                onPressed: _verifyPin,
                child: const Text('Unlock Admin Panel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── TAB 2: DEPARTMENT FILTER ──────────────────────────────────────────────

  Widget _buildDepartmentFilterTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Picking Departments (Global Permissions)',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textLight),
        ),
        const SizedBox(height: 6),
        const Text(
          'Configure global picking permissions for each department across this device.\n'
          'Departments represent the work areas / assembly destinations where parts are assembled.',
          style: TextStyle(fontSize: 13, color: AppTheme.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),

        // ── Bulk Actions ──────────────────────────────────────────────────
        Card(
          color: AppTheme.bgDark,
          margin: const EdgeInsets.only(bottom: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.assignment_turned_in_outlined, color: AppTheme.accentCyan, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Picking Departments Bulk:',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.check_circle_outline, size: 16, color: AppTheme.accentCyan),
                  label: const Text('Allow All Departments', style: TextStyle(fontSize: 12, color: AppTheme.accentCyan)),
                  onPressed: () async {
                    await widget.dbService.setAllGlobalDepartmentsActive(true);
                    setState(() {
                      for (final k in _departments.keys) {
                        _departments[k] = true;
                      }
                    });
                    widget.onDataChanged();
                    await LogService.admin('Admin allowed all global departments for picking');
                  },
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.block_rounded, size: 16, color: AppTheme.statusDanger),
                  label: const Text('Block All Departments', style: TextStyle(fontSize: 12, color: AppTheme.statusDanger)),
                  onPressed: () async {
                    await widget.dbService.setAllGlobalDepartmentsActive(false);
                    setState(() {
                      for (final k in _departments.keys) {
                        _departments[k] = false;
                      }
                    });
                    widget.onDataChanged();
                    await LogService.admin('Admin blocked all global departments for picking');
                  },
                ),
              ],
            ),
          ),
        ),

        // ── Department Permissions Table ──────────────────────────────────
        Card(
          color: AppTheme.bgDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: const Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: Text(
                        'Department Name',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: Center(
                        child: Text(
                          'Allowed for Pick',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppTheme.borderDark),
              if (_departments.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No departments found. Import an Excel picklist to auto-detect departments.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                    ),
                  ),
                )
              else
                ..._departments.keys.map((dept) {
                  final isActive = _departments[dept] ?? true;

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppTheme.borderDark, width: 0.5)),
                    ),
                    child: Row(
                      children: [
                        // Dept Name & Status
                        Expanded(
                          flex: 6,
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppTheme.cardDark,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(Icons.apartment_rounded, size: 18, color: AppTheme.accentCyan),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      dept,
                                      style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textLight, fontSize: 14),
                                    ),
                                    Text(
                                      isActive ? 'Allowed for picking' : 'Blocked on this tablet',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isActive ? AppTheme.accentCyan : AppTheme.statusDanger,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Checkbox: Allowed for Pick
                        Expanded(
                          flex: 4,
                          child: Center(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () async {
                                final newVal = !isActive;
                                setState(() => _departments[dept] = newVal);
                                await widget.dbService.setGlobalDepartmentActive(dept, newVal);
                                widget.onDataChanged();
                                await LogService.admin('Admin set department "$dept" pick allowed to $newVal');
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(6.0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Checkbox(
                                      value: isActive,
                                      activeColor: AppTheme.accentCyan,
                                      checkColor: AppTheme.bgDark,
                                      onChanged: (val) async {
                                        if (val != null) {
                                          setState(() => _departments[dept] = val);
                                          await widget.dbService.setGlobalDepartmentActive(dept, val);
                                          widget.onDataChanged();
                                          await LogService.admin('Admin set department "$dept" pick allowed to $val');
                                        }
                                      },
                                    ),
                                    Text(
                                      isActive ? 'Allowed' : 'Blocked',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: isActive ? AppTheme.accentCyan : AppTheme.statusDanger,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }

  // ─── TAB 3: COMPONENT RESOURCES ───────────────────────────────────────────

  Widget _buildComponentResourcesTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Component Resources (Component Departments)',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textLight),
        ),
        const SizedBox(height: 6),
        const Text(
          'Configure picking permissions and 100% auto-issue rules by Component Resource ID (where parts originate from).\n'
          'Parts from Auto-Issue resources are hidden from picking and marked 100% issued on export.\n'
          'Note: If a component resource is blocked from picking on this tablet, its auto-issue control is disabled.',
          style: TextStyle(fontSize: 13, color: AppTheme.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),

        // ── Bulk Controls ─────────────────────────────────────────────────
        Card(
          color: AppTheme.bgDark,
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.touch_app_rounded, color: AppTheme.accentCyan, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Picking Permissions Bulk:',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.check_circle_outline, size: 16, color: AppTheme.accentCyan),
                  label: const Text('Allow All for Pick', style: TextStyle(fontSize: 12, color: AppTheme.accentCyan)),
                  onPressed: () async {
                    setState(() {
                      _blockedResourceIds.clear();
                    });
                    await widget.dbService.setBlockedResourceIds(_blockedResourceIds);
                    widget.onDataChanged();
                    await LogService.admin('Admin allowed all component resources for picking');
                  },
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.block_rounded, size: 16, color: AppTheme.statusDanger),
                  label: const Text('Block All for Pick', style: TextStyle(fontSize: 12, color: AppTheme.statusDanger)),
                  onPressed: () async {
                    setState(() {
                      _blockedResourceIds = List<String>.from(_allDistinctResources);
                      // Blocked resources cannot be auto-issued!
                      _autoIssueResourceIds.clear();
                    });
                    await widget.dbService.setBlockedResourceIds(_blockedResourceIds);
                    await widget.dbService.setAutoIssueResourceIds(_autoIssueResourceIds);
                    widget.onDataChanged();
                    await LogService.admin('Admin blocked all component resources for picking and cleared auto-issue');
                  },
                ),
              ],
            ),
          ),
        ),

        Card(
          color: AppTheme.bgDark,
          margin: const EdgeInsets.only(bottom: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.flash_on_rounded, color: AppTheme.statusComplete, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Auto-Issue on Export Bulk:',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.flash_on_rounded, size: 16, color: AppTheme.statusComplete),
                  label: const Text('Auto-Issue All (100%)', style: TextStyle(fontSize: 12, color: AppTheme.statusComplete)),
                  onPressed: () async {
                    setState(() {
                      // Only allow auto-issue on resources that are allowed for picking!
                      for (final res in _allDistinctResources) {
                        if (!_blockedResourceIds.contains(res) && !_autoIssueResourceIds.contains(res)) {
                          _autoIssueResourceIds.add(res);
                        }
                      }
                    });
                    await widget.dbService.setAutoIssueResourceIds(_autoIssueResourceIds);
                    widget.onDataChanged();
                    await LogService.admin('Admin enabled auto-issue for all allowed component resources');
                  },
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.clear_all_rounded, size: 16, color: AppTheme.textMuted),
                  label: const Text('Disable All Auto-Issue', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  onPressed: () async {
                    setState(() {
                      _autoIssueResourceIds.clear();
                    });
                    await widget.dbService.setAutoIssueResourceIds(_autoIssueResourceIds);
                    widget.onDataChanged();
                    await LogService.admin('Admin cleared all auto-issue component resources');
                  },
                ),
              ],
            ),
          ),
        ),

        // ── Consolidated 3-Column Table ───────────────────────────────────
        Card(
          color: AppTheme.bgDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: const Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        'Component Resource ID',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Center(
                        child: Text(
                          'Allowed for Pick',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Center(
                        child: Text(
                          'Auto-Issue 100%',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.statusComplete),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppTheme.borderDark),
              if (_allDistinctResources.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No Resource IDs detected in imported picklists.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                    ),
                  ),
                )
              else
                ..._allDistinctResources.map((res) {
                  final isAllowed = !_blockedResourceIds.contains(res);
                  final isAuto = _autoIssueResourceIds.contains(res);
                  final isBlankResource = res.trim().isEmpty || res == '(Empty / Unassigned)';

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppTheme.borderDark, width: 0.5)),
                    ),
                    child: Row(
                      children: [
                        // Col 1: Resource Name & Status
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppTheme.cardDark,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(
                                  Icons.precision_manufacturing_rounded,
                                  size: 18,
                                  color: isAllowed
                                      ? (isAuto ? AppTheme.statusComplete : AppTheme.accentCyan)
                                      : AppTheme.statusDanger,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      res,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isBlankResource ? AppTheme.accentCyan : AppTheme.textLight,
                                        fontStyle: isBlankResource ? FontStyle.italic : FontStyle.normal,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      !isAllowed
                                          ? 'Blocked on this tablet (Auto-issue disabled)'
                                          : (isAuto
                                              ? 'Auto-issued on export (100%)'
                                              : 'Allowed for manual picking'),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: !isAllowed
                                            ? AppTheme.statusDanger
                                            : (isAuto ? AppTheme.statusComplete : AppTheme.accentCyan),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Col 2: Checkbox Allowed for Pick
                        Expanded(
                          flex: 3,
                          child: Center(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () async {
                                final newVal = !isAllowed;
                                setState(() {
                                  if (newVal) {
                                    _blockedResourceIds.remove(res);
                                  } else {
                                    _blockedResourceIds.add(res);
                                    // Blocked resources CANNOT be auto-issued!
                                    _autoIssueResourceIds.remove(res);
                                  }
                                });
                                await widget.dbService.setBlockedResourceIds(_blockedResourceIds);
                                await widget.dbService.setAutoIssueResourceIds(_autoIssueResourceIds);
                                widget.onDataChanged();
                                await LogService.admin('Admin set resource "$res" pick allowed to $newVal');
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(6.0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Checkbox(
                                      value: isAllowed,
                                      activeColor: AppTheme.accentCyan,
                                      checkColor: AppTheme.bgDark,
                                      onChanged: (val) async {
                                        if (val != null) {
                                          setState(() {
                                            if (val) {
                                              _blockedResourceIds.remove(res);
                                            } else {
                                              _blockedResourceIds.add(res);
                                              _autoIssueResourceIds.remove(res);
                                            }
                                          });
                                          await widget.dbService.setBlockedResourceIds(_blockedResourceIds);
                                          await widget.dbService.setAutoIssueResourceIds(_autoIssueResourceIds);
                                          widget.onDataChanged();
                                          await LogService.admin('Admin set resource "$res" pick allowed to $val');
                                        }
                                      },
                                    ),
                                    Text(
                                      isAllowed ? 'Allowed' : 'Blocked',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: isAllowed ? AppTheme.accentCyan : AppTheme.statusDanger,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Col 3: Checkbox Auto-Issue 100% (Disabled if picking is blocked!)
                        Expanded(
                          flex: 3,
                          child: Center(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: !isAllowed
                                  ? null
                                  : () async {
                                      final newVal = !isAuto;
                                      setState(() {
                                        if (newVal) {
                                          if (!_autoIssueResourceIds.contains(res)) _autoIssueResourceIds.add(res);
                                        } else {
                                          _autoIssueResourceIds.remove(res);
                                        }
                                      });
                                      await widget.dbService.setAutoIssueResourceIds(_autoIssueResourceIds);
                                      widget.onDataChanged();
                                      await LogService.admin('Admin set resource "$res" auto-issue to $newVal');
                                    },
                              child: Opacity(
                                opacity: isAllowed ? 1.0 : 0.35,
                                child: Padding(
                                  padding: const EdgeInsets.all(6.0),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Checkbox(
                                        value: isAllowed && isAuto,
                                        activeColor: AppTheme.statusComplete,
                                        checkColor: AppTheme.bgDark,
                                        onChanged: !isAllowed
                                            ? null
                                            : (val) async {
                                                if (val != null) {
                                                  setState(() {
                                                    if (val) {
                                                      if (!_autoIssueResourceIds.contains(res)) _autoIssueResourceIds.add(res);
                                                    } else {
                                                      _autoIssueResourceIds.remove(res);
                                                    }
                                                  });
                                                  await widget.dbService.setAutoIssueResourceIds(_autoIssueResourceIds);
                                                  widget.onDataChanged();
                                                  await LogService.admin('Admin set resource "$res" auto-issue to $val');
                                                }
                                              },
                                      ),
                                      Text(
                                        !isAllowed
                                            ? 'Inactive'
                                            : (isAuto ? 'Auto 100%' : 'Manual'),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: !isAllowed
                                              ? AppTheme.textMuted
                                              : (isAuto ? AppTheme.statusComplete : AppTheme.textMuted),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }

  // ─── TAB 3: COLUMN MAPPER ─────────────────────────────────────────────────

  Widget _buildColumnMapperTab() {
    final entries = widget.columnMapper.aliases.entries.toList();

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final key = entry.key;
        final aliases = entry.value;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Target Column: ${key.toUpperCase()}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, color: AppTheme.accentCyan),
                      tooltip: 'Add Alias',
                      onPressed: () => _showAddAliasDialog(key),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: aliases.map((alias) {
                    return Chip(
                      label: Text(alias, style: const TextStyle(fontSize: 12, color: AppTheme.textLight)),
                      backgroundColor: AppTheme.bgDark,
                      side: const BorderSide(color: AppTheme.borderDark),
                      deleteIcon: const Icon(Icons.close_rounded, size: 15, color: AppTheme.statusDanger),
                      onDeleted: () async {
                        widget.columnMapper.removeAlias(key, alias);
                        await widget.dbService.setConfig('column_mapper_config', widget.columnMapper.toJson());
                        setState(() {});
                        widget.onDataChanged();
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAddAliasDialog(String canonicalKey) {
    final aliasController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: Text('Add Alias for ${canonicalKey.toUpperCase()}', style: const TextStyle(color: AppTheme.textLight)),
        content: TextField(
          controller: aliasController,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textLight),
          decoration: const InputDecoration(
            hintText: 'e.g. COMPONENT_CODE',
            hintStyle: TextStyle(color: AppTheme.textMuted),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newAlias = aliasController.text.trim();
              if (newAlias.isNotEmpty) {
                widget.columnMapper.addAlias(canonicalKey, newAlias);
                await widget.dbService.setConfig('column_mapper_config', widget.columnMapper.toJson());
                Navigator.of(ctx).pop();
                setState(() {});
                widget.onDataChanged();
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  // ─── TAB 4: GROUPING PRESETS ──────────────────────────────────────────────

  Widget _buildGroupingPresetsTab() {
    final allDepts = _allDistinctDepartments.isNotEmpty
        ? _allDistinctDepartments
        : _departments.keys.toList();

    final mainLineDepts = allDepts.where((d) {
      final u = d.toUpperCase().trim();
      return u.contains('MAIN') || u.contains('MACG');
    }).toList();

    final subassemblyDepts = allDepts.where((d) {
      final u = d.toUpperCase().trim();
      return !u.contains('MAIN') && !u.contains('MACG');
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Line Grouping Configuration',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textLight),
        ),
        const SizedBox(height: 6),
        const Text(
          'Configure Line grouping separately for each Subassembly department and Main Line resource/department.',
          style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 16),

        // Default global toggle
        Card(
          color: AppTheme.bgDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Default Line Grouping (Fallback)', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textLight)),
              subtitle: Text(
                _groupByLine
                    ? 'Default Enabled: New departments/resources will group by Line'
                    : 'Default Disabled: New departments/resources will skip Line',
                style: TextStyle(fontSize: 12, color: _groupByLine ? AppTheme.statusComplete : AppTheme.textMuted),
              ),
              value: _groupByLine,
              activeColor: AppTheme.accentCyan,
              onChanged: (val) async {
                await widget.dbService.setGroupByLine(val);
                setState(() => _groupByLine = val);
                widget.onDataChanged();
              },
            ),
          ),
        ),
        const SizedBox(height: 24),

        // 1. SUBASSEMBLY SECTION
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFE07B00).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.build_circle_outlined, color: Color(0xFFE07B00), size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              'SUBASSEMBLY DEPARTMENTS',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFE07B00), letterSpacing: 0.5),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (subassemblyDepts.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No Subassembly departments detected in loaded picklists.', style: TextStyle(color: AppTheme.textMuted)),
            ),
          )
        else
          Card(
            color: AppTheme.cardDark,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppTheme.borderDark),
            ),
            child: Column(
              children: subassemblyDepts.map((dept) {
                final isEnabled = _deptLineOverrides.containsKey(dept)
                    ? _deptLineOverrides[dept]!
                    : _groupByLine;
                return SwitchListTile(
                  title: Text(dept, style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textLight)),
                  subtitle: Text(
                    isEnabled
                        ? 'Department → Line → Part ID (Line Grouping Active)'
                        : 'Department → Part ID (Line Grouping Disabled)',
                    style: TextStyle(fontSize: 12, color: isEnabled ? AppTheme.statusComplete : AppTheme.textMuted),
                  ),
                  value: isEnabled,
                  activeColor: AppTheme.statusComplete,
                  onChanged: (val) async {
                    await widget.dbService.setLineGroupingDeptOverride(dept, val);
                    setState(() {
                      _deptLineOverrides[dept] = val;
                    });
                    widget.onDataChanged();
                  },
                );
              }).toList(),
            ),
          ),

        const SizedBox(height: 28),

        // 2. MAIN LINE SECTION
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppTheme.accentCyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.precision_manufacturing_rounded, color: AppTheme.accentCyan, size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              'MAIN LINE (DEPARTMENTS & RESOURCE IDs)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.accentCyan, letterSpacing: 0.5),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Card(
          color: AppTheme.cardDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderDark),
          ),
          child: Column(
            children: [
              if (mainLineDepts.isEmpty && _allDistinctResources.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No Main Line departments or resources detected in loaded picklists.', style: TextStyle(color: AppTheme.textMuted)),
                ),
              ...mainLineDepts.map((dept) {
                final isEnabled = _deptLineOverrides.containsKey(dept)
                    ? _deptLineOverrides[dept]!
                    : _groupByLine;
                return SwitchListTile(
                  secondary: const Icon(Icons.apartment_rounded, color: AppTheme.accentCyan, size: 20),
                  title: Text(dept, style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textLight)),
                  subtitle: Text(
                    isEnabled
                        ? 'Resource ID → Line → Part ID (Line Grouping Active)'
                        : 'Resource ID → Part ID (Line Grouping Disabled)',
                    style: TextStyle(fontSize: 12, color: isEnabled ? AppTheme.statusComplete : AppTheme.textMuted),
                  ),
                  value: isEnabled,
                  activeColor: AppTheme.accentCyan,
                  onChanged: (val) async {
                    await widget.dbService.setLineGroupingDeptOverride(dept, val);
                    setState(() {
                      _deptLineOverrides[dept] = val;
                    });
                    widget.onDataChanged();
                  },
                );
              }),
              if (_allDistinctResources.isNotEmpty) ...[
                const Divider(color: AppTheme.borderDark, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Specific Resource IDs (${_allDistinctResources.length}):',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                ..._allDistinctResources.map((resId) {
                  final isEnabled = _resourceLineOverrides.containsKey(resId)
                      ? _resourceLineOverrides[resId]!
                      : _groupByLine;
                  return SwitchListTile(
                    secondary: const Icon(Icons.tune_rounded, color: AppTheme.textMuted, size: 18),
                    title: Text('Resource: $resId', style: const TextStyle(color: AppTheme.textLight, fontSize: 14)),
                    subtitle: Text(
                      isEnabled
                          ? 'Group by Line before Part ID'
                          : 'Skip Line level for this resource',
                      style: TextStyle(fontSize: 11, color: isEnabled ? AppTheme.statusComplete : AppTheme.textMuted),
                    ),
                    value: isEnabled,
                    activeColor: AppTheme.accentCyan,
                    onChanged: (val) async {
                      await widget.dbService.setLineGroupingResourceOverride(resId, val);
                      setState(() {
                        _resourceLineOverrides[resId] = val;
                      });
                      widget.onDataChanged();
                    },
                  );
                }),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ─── TAB 5: STORAGE ───────────────────────────────────────────────────────

  Widget _buildStorageTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Local Database Storage',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                  ),
                  Text(
                    '${_storedUnits.length} / 40 Units stored  •  Auto-prunes oldest COMPLETED on #41',
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_storedUnits.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text('Database is currently empty.', style: TextStyle(color: AppTheme.textMuted)),
              ),
            ),
          )
        else
          ..._storedUnits.map((u) => Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: Icon(
                u.isCompleted ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
                color: u.isCompleted ? AppTheme.statusComplete : AppTheme.statusPartial,
              ),
              title: Text(u.name, style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textLight)),
              subtitle: Text(
                '${u.totalPicked}/${u.totalRequired} pcs (${u.progressPercentage.toStringAsFixed(1)}%) • ${u.status}',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: AppTheme.statusDanger),
                tooltip: 'Admin Delete Unit',
                onPressed: () => _confirmDeleteUnit(u),
              ),
            ),
          )),
      ],
    );
  }

  void _confirmDeleteUnit(UnitRecord unit) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Text('Delete Stored Unit?', style: TextStyle(color: AppTheme.textLight)),
        content: Text(
          'Move unit "${unit.name}" to deleted status? Picklist items and unit will be hidden, but its picking sessions remain retained for 30 days in the Export Hub.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusDanger),
            onPressed: () async {
              await widget.storageManager.adminDeleteUnit(unit.id);
              Navigator.of(ctx).pop();
              _loadAdminData();
              widget.onDataChanged();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ─── Tab 7: System Logs (Super Admin Protected) ──────────────────────────

  Future<void> _loadLogs() async {
    setState(() => _isLoadingLogs = true);
    try {
      final stats = await widget.dbService.getLogsStats();
      final logs = await widget.dbService.getLogs(
        level: _selectedLogLevel == 'ALL' ? null : _selectedLogLevel,
        search: _logsSearchController.text.trim().isEmpty ? null : _logsSearchController.text.trim(),
        limit: 300,
      );
      if (mounted) {
        setState(() {
          _logsStats = stats;
          _logs = logs;
          _isLoadingLogs = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingLogs = false);
    }
  }

  Future<void> _verifySuperAdminPin() async {
    final entered = _superAdminPinController.text.trim();
    if (entered == _currentSuperAdminPin) {
      setState(() {
        _isSuperAdminAuthenticated = true;
      });
      _superAdminPinController.clear();
      await _loadLogs();
      await LogService.superAdmin('Super Admin logged into System Logs viewer');
    } else {
      _superAdminPinController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid Super Admin PIN'),
          backgroundColor: AppTheme.statusDanger,
        ),
      );
      await LogService.warn('Admin', 'Failed Super Admin PIN attempt');
    }
  }

  void _showChangeSuperAdminPinDialog() {
    final oldPinController = TextEditingController();
    final newPinController = TextEditingController();
    final confirmPinController = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.cardDark,
          title: const Row(
            children: [
              Icon(Icons.lock_reset_rounded, color: AppTheme.accentCyan),
              SizedBox(width: 8),
              Text('Change Super Admin PIN', style: TextStyle(color: AppTheme.textLight)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (errorText != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(errorText!, style: const TextStyle(color: AppTheme.statusDanger, fontSize: 13)),
                ),
              TextField(
                controller: oldPinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Current Super Admin PIN'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newPinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'New PIN (at least 4 digits)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmPinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Confirm New PIN'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
              onPressed: () async {
                if (oldPinController.text.trim() != _currentSuperAdminPin) {
                  setDialogState(() => errorText = 'Current PIN is incorrect.');
                  return;
                }
                final newPin = newPinController.text.trim();
                if (newPin.length < 4) {
                  setDialogState(() => errorText = 'New PIN must be at least 4 digits.');
                  return;
                }
                if (newPin != confirmPinController.text.trim()) {
                  setDialogState(() => errorText = 'New PINs do not match.');
                  return;
                }

                await widget.dbService.setConfig('super_admin_pin', newPin);
                setState(() => _currentSuperAdminPin = newPin);
                await LogService.superAdmin('Super Admin PIN updated');
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Super Admin PIN successfully updated'),
                      backgroundColor: AppTheme.statusComplete,
                    ),
                  );
                }
              },
              child: const Text('Save PIN', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportLogsToCsv() async {
    try {
      String? targetDir = await widget.dbService.getLastExportDir();
      final pickedDir = await FilePicker.getDirectoryPath();
      if (pickedDir != null && pickedDir.isNotEmpty) {
        targetDir = pickedDir;
        await widget.dbService.setLastExportDir(targetDir);
      }

      if (targetDir == null || targetDir.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No destination folder selected for CSV export.'),
              backgroundColor: AppTheme.statusPartial,
            ),
          );
        }
        return;
      }

      final filePath = await LogService.exportLogsToCsv(targetDir);
      await LogService.superAdmin('Exported system logs to CSV: $filePath');
      await _loadLogs();

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.cardDark,
            title: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: AppTheme.statusComplete),
                SizedBox(width: 8),
                Text('Logs Exported Successfully', style: TextStyle(color: AppTheme.textLight)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('All system logs have been exported to CSV for troubleshooting:'),
                const SizedBox(height: 12),
                SelectableText(
                  filePath,
                  style: const TextStyle(fontFamily: 'monospace', color: AppTheme.accentCyan, fontSize: 13),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done', style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
        );
      }
    } catch (e, st) {
      await LogService.error('Admin', 'Failed to export logs to CSV: $e', stackTrace: st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export logs: $e'),
            backgroundColor: AppTheme.statusDanger,
          ),
        );
      }
    }
  }

  Future<void> _purgeOldLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Row(
          children: [
            Icon(Icons.auto_delete_rounded, color: AppTheme.accentCyan),
            SizedBox(width: 8),
            Text('Delete Logs Older Than 30 Days?', style: TextStyle(color: AppTheme.textLight)),
          ],
        ),
        content: const Text(
          'Diagnostic and audit logs older than 30 days will be permanently deleted. Recent logs from the last 30 days will be preserved.',
          style: TextStyle(color: AppTheme.textMuted),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Logs > 30 Days', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final deletedCount = await widget.dbService.purgeLogsOlderThanDays(30);
      await LogService.superAdmin('Purged $deletedCount system logs older than 30 days');
      await _loadLogs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted $deletedCount logs older than 30 days'),
            backgroundColor: AppTheme.statusComplete,
          ),
        );
      }
    }
  }

  void _showStackTraceDialog(Map<String, dynamic> log) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: Row(
          children: [
            Icon(
              log['level'] == 'CRASH' || log['level'] == 'ERROR'
                  ? Icons.bug_report_rounded
                  : Icons.info_outline_rounded,
              color: log['level'] == 'CRASH' || log['level'] == 'ERROR'
                  ? AppTheme.statusDanger
                  : AppTheme.accentCyan,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${log['level']} Details: ${log['tag']}',
                style: const TextStyle(color: AppTheme.textLight, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 700,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Message:', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMuted)),
                const SizedBox(height: 4),
                SelectableText(
                  log['message'] ?? '',
                  style: const TextStyle(color: AppTheme.textLight, fontSize: 14),
                ),
                const SizedBox(height: 16),
                const Text('Stack Trace:', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMuted)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.bgDark,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    (log['stack_trace'] as String?)?.isNotEmpty == true
                        ? log['stack_trace']!
                        : '(No stack trace recorded)',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppTheme.accentCyan,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemLogsTab() {
    if (!_isSuperAdminAuthenticated) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Card(
            child: Container(
              width: 480,
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.accentCyan.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.shield_rounded,
                      size: 48,
                      color: AppTheme.accentCyan,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Super Admin Protected Area',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textLight,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Enter the Super Admin PIN to view, search, export, or manage low-level diagnostic and crash logs.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textMuted, height: 1.4),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _superAdminPinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: '••••',
                      hintStyle: TextStyle(letterSpacing: 8),
                    ),
                    onSubmitted: (_) => _verifySuperAdminPin(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
                      icon: const Icon(Icons.lock_open_rounded, color: Colors.black),
                      label: const Text(
                        'Unlock System Logs',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black),
                      ),
                      onPressed: _verifySuperAdminPin,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final count = _logsStats['count'] as int? ?? 0;
    final sizeBytes = _logsStats['sizeBytes'] as int? ?? 0;
    final sizeMb = sizeBytes / (1024 * 1024);
    final usagePercent = (sizeBytes / LogService.maxLogSizeBytes).clamp(0.0, 1.0);

    return Column(
      children: [
        // Top statistics & actions bar
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.cardDark,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.analytics_rounded, size: 20, color: AppTheme.accentCyan),
                            const SizedBox(width: 8),
                            Text(
                              '$count log entries  •  ${sizeMb.toStringAsFixed(2)} / 49.00 MB used (${(usagePercent * 100).toStringAsFixed(1)}%)',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textLight),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: usagePercent,
                            backgroundColor: AppTheme.bgDark,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              usagePercent > 0.9
                                  ? AppTheme.statusDanger
                                  : usagePercent > 0.7
                                      ? AppTheme.statusPartial
                                      : AppTheme.accentCyan,
                            ),
                            minHeight: 6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
                    icon: const Icon(Icons.file_download_rounded, color: Colors.black, size: 18),
                    label: const Text('Export CSV', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    onPressed: _exportLogsToCsv,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: AppTheme.textLight),
                    tooltip: 'Refresh Logs',
                    onPressed: _loadLogs,
                  ),
                  IconButton(
                    icon: const Icon(Icons.password_rounded, color: AppTheme.textLight),
                    tooltip: 'Change Super Admin PIN',
                    onPressed: _showChangeSuperAdminPinDialog,
                  ),
                  IconButton(
                    icon: const Icon(Icons.auto_delete_rounded, color: AppTheme.accentCyan),
                    tooltip: 'Delete Logs Older Than 30 Days',
                    onPressed: _purgeOldLogs,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Search & filter row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppTheme.bgDark,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedLogLevel,
                        dropdownColor: AppTheme.cardDark,
                        items: const [
                          DropdownMenuItem(value: 'ALL', child: Text('All Logs / Levels')),
                          DropdownMenuItem(value: 'PICKER', child: Text('PICKER Actions', style: TextStyle(color: AppTheme.statusComplete, fontWeight: FontWeight.bold))),
                          DropdownMenuItem(value: 'ADMIN', child: Text('ADMIN Actions', style: TextStyle(color: AppTheme.accentCyan, fontWeight: FontWeight.bold))),
                          DropdownMenuItem(value: 'CRASH', child: Text('CRASH', style: TextStyle(color: AppTheme.statusDanger))),
                          DropdownMenuItem(value: 'ERROR', child: Text('ERROR', style: TextStyle(color: AppTheme.statusDanger))),
                          DropdownMenuItem(value: 'WARN', child: Text('WARN', style: TextStyle(color: AppTheme.statusPartial))),
                          DropdownMenuItem(value: 'INFO', child: Text('INFO', style: TextStyle(color: AppTheme.textLight))),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedLogLevel = val);
                            _loadLogs();
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _logsSearchController,
                      decoration: InputDecoration(
                        hintText: 'Search logs by tag, message, or stack trace...',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _logsSearchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () {
                                  _logsSearchController.clear();
                                  _loadLogs();
                                },
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      ),
                      onSubmitted: (_) => _loadLogs(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _loadLogs,
                    child: const Text('Filter'),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Logs list
        Expanded(
          child: _isLoadingLogs
              ? const Center(child: CircularProgressIndicator())
              : _logs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.receipt_long_rounded, size: 48, color: AppTheme.textMuted),
                          const SizedBox(height: 12),
                          Text(
                            _logsSearchController.text.isNotEmpty || _selectedLogLevel != 'ALL'
                                ? 'No logs matching current filter'
                                : 'No system logs recorded yet',
                            style: const TextStyle(color: AppTheme.textMuted),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _logs.length,
                      padding: const EdgeInsets.all(12),
                      itemBuilder: (ctx, index) {
                        final log = _logs[index];
                        final level = log['level'] as String? ?? 'INFO';
                        final tag = log['tag'] as String? ?? '';
                        final message = log['message'] as String? ?? '';
                        final stack = log['stack_trace'] as String? ?? '';
                        final ts = (log['timestamp'] as num?)?.toInt() ?? 0;
                        final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(
                          DateTime.fromMillisecondsSinceEpoch(ts),
                        );

                        Color levelColor;
                        switch (level) {
                          case 'CRASH':
                          case 'ERROR':
                            levelColor = AppTheme.statusDanger;
                            break;
                          case 'WARN':
                            levelColor = AppTheme.statusPartial;
                            break;
                          case 'INFO':
                          default:
                            levelColor = AppTheme.accentCyan;
                        }

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: stack.isNotEmpty ? () => _showStackTraceDialog(log) : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: levelColor.withOpacity(0.18),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: levelColor.withOpacity(0.5)),
                                    ),
                                    child: Text(
                                      level,
                                      style: TextStyle(
                                        color: levelColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: tag.toUpperCase() == 'PICKER'
                                                    ? AppTheme.statusComplete.withOpacity(0.18)
                                                    : tag.toUpperCase() == 'ADMIN'
                                                        ? AppTheme.accentCyan.withOpacity(0.18)
                                                        : AppTheme.bgDark,
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(
                                                  color: tag.toUpperCase() == 'PICKER'
                                                      ? AppTheme.statusComplete.withOpacity(0.6)
                                                      : tag.toUpperCase() == 'ADMIN'
                                                          ? AppTheme.accentCyan.withOpacity(0.6)
                                                          : AppTheme.borderDark,
                                                ),
                                              ),
                                              child: Text(
                                                tag.toUpperCase(),
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: tag.toUpperCase() == 'PICKER'
                                                      ? AppTheme.statusComplete
                                                      : tag.toUpperCase() == 'ADMIN'
                                                          ? AppTheme.accentCyan
                                                          : AppTheme.textMuted,
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              dateStr,
                                              style: const TextStyle(
                                                color: AppTheme.textMuted,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          message,
                                          style: const TextStyle(color: AppTheme.textLight, fontSize: 13),
                                        ),
                                        if (stack.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Icon(Icons.info_outline_rounded, size: 14, color: levelColor),
                                              const SizedBox(width: 4),
                                              Text(
                                                'Tap to inspect stack trace',
                                                style: TextStyle(
                                                  color: levelColor,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (stack.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                                      onPressed: () => _showStackTraceDialog(log),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

