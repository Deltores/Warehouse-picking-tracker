import 'package:flutter/material.dart';
import '../../models/session_metadata.dart';
import '../../models/unit_record.dart';
import '../theme/app_theme.dart';

/// TabletHeader: persistent top bar shown during picking.
///
/// Layout (0 overflow guaranteed):
///  - Large back button (←) — requires admin PIN to exit to main menu.
///  - Unit icon + Unit name + ACTIVE/CLOSED badge.
///  - Picker: {Name} | Session #{seqNo} | Tablet {tabletId}.
///  - Part progress badge: X / Y parts (Z%).
///  - Mode toggle: List ↔ Pick Mode.
///  - Close Session button (orange, only when ACTIVE).
class TabletHeader extends StatelessWidget {
  final UnitRecord? activeUnit;
  final SessionMetadata? activeSession;
  final String tabletId;
  final int? totalParts;
  final int? completedParts;
  final VoidCallback onBack;
  final VoidCallback onCloseSession;
  final bool isPickMode;
  final ValueChanged<bool>? onModeChanged;

  const TabletHeader({
    super.key,
    required this.activeUnit,
    required this.activeSession,
    this.tabletId = '',
    this.totalParts,
    this.completedParts,
    required this.onBack,
    required this.onCloseSession,
    this.isPickMode = false,
    this.onModeChanged,
  });

  String _formatStartTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final mon = months[dt.month - 1];
    final d = dt.day;
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$mon $d, $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final session = activeSession;
    final isActive = session?.isActive ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.cardDark,
        border: Border(bottom: BorderSide(color: AppTheme.borderDark, width: 1.5)),
      ),
      child: Row(
        children: [
          // Back Button — large, consistent across all screens
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton.filledTonal(
              icon: const Icon(Icons.arrow_back_rounded, size: 22),
              tooltip: 'Back to Units & Departments',
              style: IconButton.styleFrom(
                backgroundColor: AppTheme.bgDark,
                foregroundColor: AppTheme.textLight,
              ),
              onPressed: onBack,
            ),
          ),
          const SizedBox(width: 10),

          // Unit Icon Box
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.4)),
            ),
            child: const Icon(Icons.inventory_2_rounded, color: AppTheme.accentCyan, size: 22),
          ),
          const SizedBox(width: 10),

          // Unit & Session Metadata
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        activeUnit?.name ?? 'No Picklist Loaded',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (session != null) ...[
                      const SizedBox(width: 6),
                      _statusBadge(session),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                if (session != null)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    children: [
                      // Picker: Name
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.person_rounded, size: 13, color: AppTheme.accentCyan),
                          const SizedBox(width: 3),
                          Text(
                            'Picker: ${session.workerName}',
                            style: const TextStyle(fontSize: 12, color: AppTheme.accentCyan, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      // Session #N
                      if (session.sessionSeqNo > 0)
                        Text(
                          'Session #${session.sessionSeqNo}',
                          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w500),
                        )
                      else
                        const Text(
                          'New Session',
                          style: TextStyle(fontSize: 11, color: AppTheme.accentCyan, fontWeight: FontWeight.w500),
                        ),
                      // Tablet ID
                      if (tabletId.isNotEmpty)
                        Text(
                          tabletId,
                          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                        ),
                      // Started timestamp
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.schedule_rounded, size: 13, color: AppTheme.textMuted),
                          const SizedBox(width: 3),
                          Text(
                            _formatStartTime(session.startTime),
                            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                          ),
                        ],
                      ),
                    ],
                  )
                else
                  const Text('No Active Session', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Part ID Progress Badge
          _buildPartsProgressBadge(),

          // Close Session Button (only if active)
          if (isActive) ...[
            const SizedBox(width: 10),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE07B00),
                foregroundColor: Colors.white,
                minimumSize: const Size(145, 44),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.lock_clock_rounded, size: 18),
              label: const Text('Close Session', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              onPressed: onCloseSession,
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusBadge(SessionMetadata session) {
    Color color;
    final label = session.statusLabel;
    if (session.isActive) {
      color = AppTheme.statusComplete;
    } else if (session.isClosed) {
      color = const Color(0xFFE07B00);
    } else if (session.isExported || session.isFinished) {
      color = AppTheme.textMuted;
    } else if (session.isIssued) {
      color = AppTheme.accentCyan;
    } else {
      color = AppTheme.statusDanger;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _buildPartsProgressBadge() {
    final total = totalParts ?? 0;
    final done = completedParts ?? 0;
    final pct = total > 0 ? (done / total * 100).toStringAsFixed(1) : '0.0';
    final isDone = total > 0 && done >= total;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isDone ? AppTheme.statusComplete.withValues(alpha: 0.15) : AppTheme.bgDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDone ? AppTheme.statusComplete : AppTheme.borderDark),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDone ? Icons.check_circle_rounded : Icons.pending_actions_rounded,
            size: 15,
            color: isDone ? AppTheme.statusComplete : AppTheme.statusPartial,
          ),
          const SizedBox(width: 5),
          Text(
            'Unit: $done / $total parts ($pct%)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isDone ? AppTheme.statusComplete : AppTheme.textLight,
            ),
          ),
        ],
      ),
    );
  }
}
