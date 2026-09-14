import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../engine/column_mapper.dart';
import '../../services/database_service.dart';
import '../../services/excel_service.dart';
import '../../services/log_service.dart';
import '../../services/storage_manager.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

/// CrashRecoveryScreen: Graceful crash dialog/screen displayed whenever an
/// unhandled error or fatal UI exception occurs.
///
/// Features:
///  - Automatically records full exception and stack trace into System Logs (SQLite).
///  - 10-second countdown with visual progress before exiting via SystemNavigator.pop().
///  - Explanatory message for warehouse pickers ("Please reopen and contact Admin/Developer").
///  - Expandable diagnostic details for administrators and field technicians.
///  - "Try Recovering" button to reset state and safely return to HomeScreen.
class CrashRecoveryScreen extends StatefulWidget {
  final FlutterErrorDetails? errorDetails;
  final String? errorMessage;
  final String? stackTrace;
  final DatabaseService? dbService;
  final StorageManager? storageManager;
  final ExcelService? excelService;
  final ColumnMapper? columnMapper;

  const CrashRecoveryScreen({
    super.key,
    this.errorDetails,
    this.errorMessage,
    this.stackTrace,
    this.dbService,
    this.storageManager,
    this.excelService,
    this.columnMapper,
  });

  @override
  State<CrashRecoveryScreen> createState() => _CrashRecoveryScreenState();
}

class _CrashRecoveryScreenState extends State<CrashRecoveryScreen> {
  int _remainingSeconds = 10;
  Timer? _countdownTimer;
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    _logCrashDetails();
    _startCountdown();
  }

  void _logCrashDetails() {
    final msg = widget.errorMessage ?? widget.errorDetails?.exceptionAsString() ?? 'Unknown error';
    final st = widget.stackTrace ?? widget.errorDetails?.stack?.toString() ?? '';
    LogService.crash('FatalError', msg, stackTrace: st);
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_remainingSeconds <= 1) {
        timer.cancel();
        _closeApp();
      } else {
        setState(() {
          _remainingSeconds--;
        });
      }
    });
  }

  void _closeApp() {
    LogService.info('CrashRecovery', 'App closed after crash countdown.');
    SystemNavigator.pop();
  }

  void _tryRecover() {
    _countdownTimer?.cancel();
    LogService.info('CrashRecovery', 'User initiated crash recovery to HomeScreen.');

    if (widget.dbService != null &&
        widget.storageManager != null &&
        widget.excelService != null &&
        widget.columnMapper != null) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => HomeScreen(
            dbService: widget.dbService!,
            storageManager: widget.storageManager!,
            excelService: widget.excelService!,
            columnMapper: widget.columnMapper!,
          ),
        ),
        (route) => false,
      );
    } else {
      // Fallback close if services are unavailable
      _closeApp();
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.errorMessage ?? widget.errorDetails?.exceptionAsString() ?? 'Unexpected Error';
    final st = widget.stackTrace ?? widget.errorDetails?.stack?.toString() ?? '(No stack trace available)';
    final progress = _remainingSeconds / 10.0;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: Scaffold(
        backgroundColor: AppTheme.bgDark,
        body: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 720),
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.statusDanger.withValues(alpha: 0.5), width: 2),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.statusDanger.withValues(alpha: 0.2),
                  blurRadius: 30,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Danger Header Icon
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: AppTheme.statusDanger.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.warning_rounded,
                      size: 56,
                      color: AppTheme.statusDanger,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Title
                  const Text(
                    'Application Error',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textLight,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Subtitle Instructions
                  const Text(
                    'An unhandled exception occurred and detailed logs have been recorded.\\n'
                    'Please reopen the app. If the issue persists, contact your Admin or Developer.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: AppTheme.textMuted, height: 1.5),
                  ),
                  const SizedBox(height: 24),

                  // Countdown Box
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: AppTheme.bgDark,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderDark),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.timer_outlined, color: AppTheme.statusPartial, size: 22),
                            const SizedBox(width: 8),
                            Text(
                              'Closing in $_remainingSeconds s...',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.statusPartial,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            backgroundColor: AppTheme.cardDark,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              _remainingSeconds <= 3 ? AppTheme.statusDanger : AppTheme.statusPartial,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Action Buttons
                  Row(
                    children: [
                      // Close Now Button
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppTheme.statusDanger),
                            foregroundColor: AppTheme.statusDanger,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.power_settings_new_rounded, size: 20),
                          label: const Text(
                            'Close Now',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          onPressed: _closeApp,
                        ),
                      ),
                      const SizedBox(width: 14),

                      // Try Recovering Button
                      if (widget.dbService != null)
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accentCyan,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.refresh_rounded, size: 20),
                            label: const Text(
                              'Try Recovering',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                            ),
                            onPressed: _tryRecover,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Diagnostics toggle
                  TextButton.icon(
                    icon: Icon(
                      _showDetails ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 18,
                      color: AppTheme.textMuted,
                    ),
                    label: Text(
                      _showDetails ? 'Hide Diagnostics' : 'View Diagnostics',
                      style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
                    ),
                    onPressed: () => setState(() => _showDetails = !_showDetails),
                  ),

                  if (_showDetails) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderDark),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Error: $msg',
                            style: const TextStyle(
                              color: AppTheme.statusDanger,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            st,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
