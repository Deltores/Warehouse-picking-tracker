import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class TouchNumpadDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final int qtyRequired;
  final int qtyDue;
  final int initialValue;

  const TouchNumpadDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.qtyRequired,
    required this.qtyDue,
    required this.initialValue,
  });

  static Future<int?> show(
    BuildContext context, {
    required String title,
    String? subtitle,
    required int qtyRequired,
    required int qtyDue,
    required int initialValue,
  }) {
    return showDialog<int>(
      context: context,
      barrierDismissible: true,
      builder: (context) => TouchNumpadDialog(
        title: title,
        subtitle: subtitle,
        qtyRequired: qtyRequired,
        qtyDue: qtyDue,
        initialValue: initialValue,
      ),
    );
  }

  @override
  State<TouchNumpadDialog> createState() => _TouchNumpadDialogState();
}

class _TouchNumpadDialogState extends State<TouchNumpadDialog> {
  late int _currentValue;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.initialValue;
  }

  void _appendDigit(int digit) {
    setState(() {
      final str = _currentValue == 0 ? '$digit' : '$_currentValue$digit';
      _currentValue = int.tryParse(str) ?? _currentValue;
    });
  }

  void _backspace() {
    setState(() {
      final str = '$_currentValue';
      if (str.length <= 1) {
        _currentValue = 0;
      } else {
        _currentValue = int.tryParse(str.substring(0, str.length - 1)) ?? 0;
      }
    });
  }

  void _clear() {
    setState(() {
      _currentValue = 0;
    });
  }

  void _addStep(int step) {
    setState(() {
      _currentValue += step;
    });
  }

  void _matchDue() {
    setState(() {
      _currentValue = widget.qtyRequired;
    });
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
        width: 480,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title & Part ID Info
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textLight,
                        ),
                      ),
                      if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle!,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppTheme.textMuted,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: AppTheme.textMuted, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Metrics Bar
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.bgDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderDark),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMetric('Required', '${widget.qtyRequired}', AppTheme.textLight),
                  _buildMetric('Due', '${widget.qtyDue}', AppTheme.statusPartial),
                  _buildMetric(
                    'Picked',
                    '$_currentValue',
                    _currentValue >= widget.qtyRequired
                        ? AppTheme.statusComplete
                        : (_currentValue > 0 ? AppTheme.statusPartial : AppTheme.statusUnpicked),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Quick Step Buttons (+1, +5, +10, Match Due)
            Row(
              children: [
                _buildQuickButton('+1', () => _addStep(1)),
                const SizedBox(width: 8),
                _buildQuickButton('+5', () => _addStep(5)),
                const SizedBox(width: 8),
                _buildQuickButton('+10', () => _addStep(10)),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentCyan,
                      foregroundColor: AppTheme.bgDark,
                      minimumSize: const Size(0, 52),
                    ),
                    onPressed: _matchDue,
                    child: const Text('Match Due', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Number Pad Grid (3x4)
            Column(
              children: [
                Row(
                  children: [
                    _buildNumButton(1),
                    const SizedBox(width: 8),
                    _buildNumButton(2),
                    const SizedBox(width: 8),
                    _buildNumButton(3),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildNumButton(4),
                    const SizedBox(width: 8),
                    _buildNumButton(5),
                    const SizedBox(width: 8),
                    _buildNumButton(6),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildNumButton(7),
                    const SizedBox(width: 8),
                    _buildNumButton(8),
                    const SizedBox(width: 8),
                    _buildNumButton(9),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildActionPadButton('CLR', _clear, color: AppTheme.statusDanger),
                    const SizedBox(width: 8),
                    _buildNumButton(0),
                    const SizedBox(width: 8),
                    _buildActionPadButton('⌫', _backspace, color: AppTheme.borderDark),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Confirm Button
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.statusComplete,
                minimumSize: const Size(double.infinity, 56),
              ),
              onPressed: () {
                Navigator.of(context).pop(_currentValue);
              },
              child: const Text(
                'Confirm Picked Quantity',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetric(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  Widget _buildQuickButton(String label, VoidCallback onTap) {
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: EdgeInsets.zero,
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildNumButton(int digit) {
    return Expanded(
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.bgDark,
          foregroundColor: AppTheme.textLight,
          minimumSize: const Size(0, 58),
          elevation: 0,
          side: const BorderSide(color: AppTheme.borderDark),
        ),
        onPressed: () => _appendDigit(digit),
        child: Text(
          '$digit',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildActionPadButton(String label, VoidCallback onTap, {Color? color}) {
    return Expanded(
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? AppTheme.bgDark,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 58),
          elevation: 0,
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
