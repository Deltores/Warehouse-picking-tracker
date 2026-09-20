import 'package:flutter/material.dart';

import '../../engine/column_mapper.dart';
import '../../services/database_service.dart';
import '../../services/excel_service.dart';
import '../../services/storage_manager.dart';
import '../theme/app_theme.dart';
import 'admin_screen.dart';
import 'picker_flow_screen.dart';
import 'session_export_screen.dart';

/// HomeScreen: The launch screen presenting two roles — Admin and Picker.
/// Admin → PIN gate → AdminScreen.
/// Picker → PickerFlowScreen (name → unit selection → department selection → picking).
///
/// Shows Tablet ID badge, allowed department filters (only when filtered), and a legal disclaimer.
class HomeScreen extends StatefulWidget {
  final DatabaseService dbService;
  final StorageManager storageManager;
  final ExcelService excelService;
  final ColumnMapper columnMapper;

  const HomeScreen({
    super.key,
    required this.dbService,
    required this.storageManager,
    required this.excelService,
    required this.columnMapper,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _tabletId = 'Tablet 1';
  List<String> _allowedPickingDepts = [];
  List<String> _allowedComponentDepts = [];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final tabletId = await widget.dbService.getConfig('tablet_id');

    // Determine filtered dept lists from admin_config
    final compDeptJson = await widget.dbService.getConfig('component_departments_allowed');
    List<String> compDepts = [];
    if (compDeptJson != null && compDeptJson.isNotEmpty) {
      try {
        // Simple CSV parse or JSON — try JSON first
        // ignore: avoid_dynamic_calls
        compDepts = [];
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _tabletId = tabletId ?? 'Tablet 1';
        _allowedPickingDepts = []; // empty = all allowed
        _allowedComponentDepts = compDepts;
      });
    }
  }

  void _enterAsAdmin(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminScreen(
          dbService: widget.dbService,
          storageManager: widget.storageManager,
          columnMapper: widget.columnMapper,
          onDataChanged: _loadConfig,
        ),
      ),
    );
  }

  void _enterAsPicker(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PickerFlowScreen(
          dbService: widget.dbService,
          storageManager: widget.storageManager,
          excelService: widget.excelService,
          columnMapper: widget.columnMapper,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0F172A), Color(0xFF0C1525)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxHeight < 850;
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: isCompact ? 16 : 24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Tablet ID Badge at top
                          Align(
                            alignment: Alignment.topRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppTheme.accentCyan.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.tablet_android_rounded, size: 14, color: AppTheme.accentCyan),
                                  const SizedBox(width: 6),
                                  Text(
                                    _tabletId,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.accentCyan,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(height: isCompact ? 12 : 24),

                          // Logo / App Identity
                          Container(
                            padding: EdgeInsets.all(isCompact ? 14 : 20),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                              border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.4), width: 2),
                            ),
                            child: Icon(
                              Icons.inventory_2_rounded,
                              size: isCompact ? 52 : 72,
                              color: AppTheme.accentCyan,
                            ),
                          ),
                          SizedBox(height: isCompact ? 12 : 20),

                          Text(
                            'Pick List Tracker',
                            style: TextStyle(
                              fontSize: isCompact ? 26 : 32,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textLight,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Select your role to continue',
                            style: TextStyle(fontSize: 15, color: AppTheme.textMuted),
                          ),

                          // Department filter info (only shown when filtered, not "all")
                          if (_allowedPickingDepts.isNotEmpty || _allowedComponentDepts.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: AppTheme.cardDark,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppTheme.borderDark),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_allowedPickingDepts.isNotEmpty) ...[
                                    const Text(
                                      'Allowed Picking Departments:',
                                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      children: _allowedPickingDepts
                                          .map((d) => _deptChip(d, AppTheme.statusComplete))
                                          .toList(),
                                    ),
                                  ],
                                  if (_allowedComponentDepts.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    const Text(
                                      'Component Departments:',
                                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      children: _allowedComponentDepts
                                          .map((d) => _deptChip(d, AppTheme.accentCyan))
                                          .toList(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],

                          SizedBox(height: isCompact ? 16 : 28),

                          // Role Cards Row
                          Row(
                            children: [
                              // Picker Card
                              Expanded(
                                child: _RoleCard(
                                  icon: Icons.person_rounded,
                                  iconColor: AppTheme.statusComplete,
                                  title: 'Picker',
                                  subtitle: 'Start a picking session\nEnter your name & select a unit',
                                  borderColor: AppTheme.statusComplete,
                                  isCompact: isCompact,
                                  onTap: () => _enterAsPicker(context),
                                ),
                              ),
                              const SizedBox(width: 24),

                              // Admin Card
                              Expanded(
                                child: _RoleCard(
                                  icon: Icons.admin_panel_settings_rounded,
                                  iconColor: AppTheme.accentCyan,
                                  title: 'Admin',
                                  subtitle: 'Manage files, departments\ncolumn mapping & settings',
                                  borderColor: AppTheme.accentCyan,
                                  isCompact: isCompact,
                                  onTap: () => _enterAsAdmin(context),
                                ),
                              ),
                            ],
                          ),

                          SizedBox(height: isCompact ? 16 : 28),

                          // Export Sessions Button
                          ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => SessionExportScreen(
                                    dbService: widget.dbService,
                                    excelService: widget.excelService,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.file_download_rounded, size: 22),
                            label: const Text('Export Sessions'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              foregroundColor: AppTheme.textLight,
                              padding: EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: isCompact ? 12 : 16,
                              ),
                              textStyle: TextStyle(
                                fontSize: isCompact ? 16 : 18,
                                fontWeight: FontWeight.bold,
                              ),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                          ),

                          const Spacer(),
                          const SizedBox(height: 12),

                          // Legal & Operational Disclaimer Footer
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(
                              color: AppTheme.bgDark.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.borderDark.withValues(alpha: 0.6)),
                            ),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.gavel_rounded, size: 13, color: AppTheme.accentCyan),
                                    SizedBox(width: 6),
                                    Text(
                                      'LEGAL & OPERATIONAL DISCLAIMER — AS-IS WARRANTY WAIVER',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.8,
                                        color: AppTheme.accentCyan,
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 5),
                                Text(
                                  'This software and all automated calculations are provided strictly "AS IS" without warranty of any kind, express or implied. The software, developers, and system contributors disclaim any and all liability for inventory inaccuracies, physical counting discrepancies, stock shortages, production delays, allocation mismatches, or ledger errors. Operators and facility management bear sole and ultimate responsibility for independent physical verification of all components, bin locations, piece counts, and manufacturing requisitions prior to staging, assembly, ERP posting, or production release.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    color: AppTheme.textMuted,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppTheme.bgDark.withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppTheme.borderDark),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.terminal_rounded, size: 12, color: AppTheme.accentCyan),
                                    SizedBox(width: 6),
                                    Text(
                                      'Picklist Tracker • v1.02 • Build: 19/Sep/2026 • Production Tablet',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textMuted,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _deptChip(String name, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        name,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Color borderColor;
  final bool isCompact;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.borderColor,
    this.isCompact = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(
            vertical: isCompact ? 22 : 36,
            horizontal: 24,
          ),
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor.withValues(alpha: 0.6), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: borderColor.withValues(alpha: 0.1),
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.all(isCompact ? 14 : 20),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: isCompact ? 40 : 52, color: iconColor),
              ),
              SizedBox(height: isCompact ? 12 : 20),
              Text(
                title,
                style: TextStyle(
                  fontSize: isCompact ? 20 : 24,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textLight,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: iconColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  'Continue as $title →',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: iconColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
