import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/session_metadata.dart';
import '../theme/app_theme.dart';

class SessionStartDialog extends StatefulWidget {
  final String unitId;
  final String unitName;

  const SessionStartDialog({
    super.key,
    required this.unitId,
    required this.unitName,
  });

  static Future<SessionMetadata?> show(
    BuildContext context, {
    required String unitId,
    required String unitName,
  }) {
    return showDialog<SessionMetadata>(
      context: context,
      barrierDismissible: false,
      builder: (context) => SessionStartDialog(
        unitId: unitId,
        unitName: unitName,
      ),
    );
  }

  @override
  State<SessionStartDialog> createState() => _SessionStartDialogState();
}

class _SessionStartDialogState extends State<SessionStartDialog> {
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _generateSessionId(String workerName) {
    final now = DateTime.now();
    final dateStr = DateFormat('yyyyMMdd').format(now);
    final initials = workerName.trim().split(' ').map((e) => e.isNotEmpty ? e[0].toUpperCase() : '').take(3).join();
    final randomPart = Random().nextInt(900) + 100;
    return 'SESS-$dateStr-${initials.isNotEmpty ? initials : "USR"}-$randomPart';
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      final name = _nameController.text.trim();
      final now = DateTime.now();
      final session = SessionMetadata(
        id: _generateSessionId(name),
        unitId: widget.unitId,
        workerName: name,
        startTime: now.millisecondsSinceEpoch,
        pickDate: DateFormat('yyyy-MM-dd').format(now),
        status: 'ACTIVE',
        issuedStatus: 'Pending Issue',
        totalItemsPicked: 0,
      );
      Navigator.of(context).pop(session);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.borderDark, width: 1.5),
      ),
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(28),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.badge_outlined, color: AppTheme.accentCyan, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Start Picking Session',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textLight,
                          ),
                        ),
                        Text(
                          'Unit: ${widget.unitName}',
                          style: const TextStyle(fontSize: 14, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                'Worker Name:',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textLight),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _nameController,
                autofocus: true,
                style: const TextStyle(fontSize: 18, color: AppTheme.textLight),
                decoration: InputDecoration(
                  hintText: 'e.g. John Doe',
                  hintStyle: const TextStyle(color: AppTheme.textMuted),
                  filled: true,
                  fillColor: AppTheme.bgDark,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppTheme.borderDark),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppTheme.accentCyan, width: 2),
                  ),
                  prefixIcon: const Icon(Icons.person_outline, color: AppTheme.accentCyan),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter worker name to proceed';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  minimumSize: const Size(double.infinity, 54),
                ),
                onPressed: _submit,
                child: const Text(
                  'Begin Session',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
