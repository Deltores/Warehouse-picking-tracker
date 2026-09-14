import 'package:flutter/material.dart';
import '../../models/session_metadata.dart';
import '../../models/unit_record.dart';
import '../theme/app_theme.dart';

class ExportSummaryDialog extends StatefulWidget {
  final UnitRecord unit;
  final SessionMetadata session;
  final int currentSessionPickedCount;

  const ExportSummaryDialog({
    super.key,
    required this.unit,
    required this.session,
    required this.currentSessionPickedCount,
  });

  static Future<String?> show(
    BuildContext context, {
    required UnitRecord unit,
    required SessionMetadata session,
    required int currentSessionPickedCount,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (context) => ExportSummaryDialog(
        unit: unit,
        session: session,
        currentSessionPickedCount: currentSessionPickedCount,
      ),
    );
  }

  @override
  State<ExportSummaryDialog> createState() => _ExportSummaryDialogState();
}

class _ExportSummaryDialogState extends State<ExportSummaryDialog> {
  late String _selectedIssuedStatus;

  @override
  void initState() {
    super.initState();
    _selectedIssuedStatus = widget.session.issuedStatus;
  }

  @override
  Widget build(BuildContext context) {
    final bool isEmptySession = widget.currentSessionPickedCount == 0 && widget.unit.totalPicked == 0;
    final double overallProgress = widget.unit.totalRequired > 0
        ? (widget.unit.totalPicked / widget.unit.totalRequired) * 100
        : 0.0;

    return Dialog(
      backgroundColor: AppTheme.cardDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.borderDark, width: 1.5),
      ),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.statusComplete.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.file_download_done_rounded, color: AppTheme.statusComplete, size: 28),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Text(
                    'Export & Finalize Session',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textLight,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: AppTheme.textMuted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Anti-Empty Safeguard Warning
            if (isEmptySession) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.statusDanger.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.statusDanger),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: AppTheme.statusDanger, size: 30),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Empty Session Detected: Exactly 0 parts were picked! Exporting empty sessions is blocked to prevent uploading blank records to ERP.',
                        style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
            ],

            // Summary Details Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.bgDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderDark),
              ),
              child: Column(
                children: [
                  _buildDetailRow('Unit Target', widget.unit.name),
                  const Divider(color: AppTheme.borderDark, height: 16),
                  _buildDetailRow('Worker Name', widget.session.workerName),
                  const Divider(color: AppTheme.borderDark, height: 16),
                  _buildDetailRow('Session ID', widget.session.id),
                  const Divider(color: AppTheme.borderDark, height: 16),
                  _buildDetailRow(
                    'Unit Total Picked',
                    '${widget.unit.totalPicked} / ${widget.unit.totalRequired} pcs (${overallProgress.toStringAsFixed(1)}%)',
                    highlightColor: widget.unit.totalPicked > 0 ? AppTheme.statusComplete : AppTheme.statusUnpicked,
                  ),
                  const Divider(color: AppTheme.borderDark, height: 16),
                  _buildDetailRow(
                    'Picked In This Session',
                    '${widget.currentSessionPickedCount} items',
                    highlightColor: widget.currentSessionPickedCount > 0 ? AppTheme.accentCyan : AppTheme.statusDanger,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ERP Issued Status Selector
            const Text(
              'ERP Issued Status:',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textLight),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: const Center(child: Text('Pending (Awaiting ERP)')),
                    selected: _selectedIssuedStatus == 'Pending',
                    onSelected: (selected) {
                      if (selected) setState(() => _selectedIssuedStatus = 'Pending');
                    },
                    selectedColor: AppTheme.statusPartial.withOpacity(0.25),
                    labelStyle: TextStyle(
                      color: _selectedIssuedStatus == 'Pending' ? AppTheme.statusPartial : AppTheme.textMuted,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ChoiceChip(
                    label: const Center(child: Text('Issued (Posted in ERP)')),
                    selected: _selectedIssuedStatus == 'Issued',
                    onSelected: (selected) {
                      if (selected) setState(() => _selectedIssuedStatus = 'Issued');
                    },
                    selectedColor: AppTheme.statusComplete.withOpacity(0.25),
                    labelStyle: TextStyle(
                      color: _selectedIssuedStatus == 'Issued' ? AppTheme.statusComplete : AppTheme.textMuted,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isEmptySession ? AppTheme.borderDark : AppTheme.statusComplete,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: isEmptySession
                        ? null // Block empty export!
                        : () {
                            Navigator.of(context).pop(_selectedIssuedStatus);
                          },
                    child: const Text(
                      'Confirm & Overwrite File',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {Color? highlightColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textMuted)),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: highlightColor ?? AppTheme.textLight,
          ),
        ),
      ],
    );
  }
}
