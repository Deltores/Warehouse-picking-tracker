import 'package:flutter/material.dart';

import '../../models/part_summary.dart';
import '../../models/picklist_item.dart';
import '../../models/session_metadata.dart';
import '../../models/unit_record.dart';
import '../../services/database_service.dart';
import '../theme/app_theme.dart';
import 'pick_mode_screen.dart';

/// DepartmentPartsView: Shows all unique Part IDs for a department.
///
/// From here the picker can:
///  - Tap any part → goes to PickModeScreen at that part
///  - Tap "Start FIFO Picking" FAB → goes to PickModeScreen at the first incomplete part
class DepartmentPartsView extends StatelessWidget {
  final UnitRecord unit;
  final String department;
  final List<PicklistItem> items;
  final DatabaseService dbService;
  final SessionMetadata? activeSession;

  const DepartmentPartsView({
    super.key,
    required this.unit,
    required this.department,
    required this.items,
    required this.dbService,
    this.activeSession,
  });

  // Group items by partId, summing qty fields.
  List<PartSummary> _buildPartSummaries() {
    final map = <String, PartSummary>{};
    for (final item in items) {
      if (item.department != department) continue;
      if (map.containsKey(item.partId)) {
        map[item.partId] = map[item.partId]!.add(item);
      } else {
        map[item.partId] = PartSummary.fromItem(item);
      }
    }
    final parts = map.values.toList();
    // Sort: incomplete (FIFO rowOrder ascending) first, complete last
    parts.sort((a, b) {
      final aDone = a.qtyPicked >= a.qtyRequired;
      final bDone = b.qtyPicked >= b.qtyRequired;
      if (aDone != bDone) return aDone ? 1 : -1;
      return a.minRowOrder.compareTo(b.minRowOrder);
    });
    return parts;
  }

  // Find the index of the first incomplete part (FIFO pick mode entry point).
  int _firstIncompleteIndex(List<PartSummary> parts) {
    return parts.indexWhere((p) => p.qtyPicked < p.qtyRequired);
  }

  void _enterPickMode(BuildContext context, List<PartSummary> parts, int startIndex) {
    if (parts.isEmpty) return;
    final clampedIndex = startIndex.clamp(0, parts.length - 1);
    // Gather dept items in FIFO order for pick mode navigation
    final deptItems = items.where((i) => i.department == department).toList()
      ..sort((a, b) => a.rowOrder.compareTo(b.rowOrder));

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PickModeScreen(
          unit: unit,
          department: department,
          partSummaries: parts,
          allDeptItems: deptItems,
          startIndex: clampedIndex,
          dbService: dbService,
          activeSession: activeSession,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parts = _buildPartSummaries();
    final firstIncomplete = _firstIncompleteIndex(parts);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: firstIncomplete >= 0 ? AppTheme.primaryBlue : AppTheme.borderDark,
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('Start FIFO Picking'),
        onPressed: firstIncomplete >= 0
            ? () => _enterPickMode(context, parts, firstIncomplete)
            : null,
      ),
      body: parts.isEmpty
          ? const Center(child: Text('No parts found for this department.', style: TextStyle(color: AppTheme.textMuted)))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              itemCount: parts.length,
              itemBuilder: (ctx, i) => _buildPartRow(context, parts, i),
            ),
    );
  }

  Widget _buildPartRow(BuildContext context, List<PartSummary> parts, int index) {
    final part = parts[index];
    final isDone = part.qtyPicked >= part.qtyRequired && part.qtyRequired > 0;
    final isPartial = part.qtyPicked > 0 && !isDone;
    final progress = part.qtyRequired > 0 ? (part.qtyPicked / part.qtyRequired).clamp(0.0, 1.0) : 0.0;

    final statusColor = isDone
        ? AppTheme.statusComplete
        : isPartial
            ? AppTheme.statusPartial
            : AppTheme.statusUnpicked;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isDone ? AppTheme.statusComplete.withValues(alpha: 0.3) : AppTheme.borderDark,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _enterPickMode(context, parts, index),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                isDone ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: statusColor,
                size: 22,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      part.partId,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textLight),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (part.description.isNotEmpty)
                          Text(
                            part.description,
                            style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: part.onHand.isNotEmpty
                                ? AppTheme.accentCyan.withOpacity(0.12)
                                : AppTheme.cardDark.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: part.onHand.isNotEmpty
                                  ? AppTheme.accentCyan.withOpacity(0.4)
                                  : AppTheme.borderDark,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.location_on_rounded,
                                size: 11,
                                color: part.onHand.isNotEmpty ? AppTheme.accentCyan : AppTheme.textMuted,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                part.onHand.isNotEmpty ? 'ON-HAND: ${part.onHand}' : 'ON-HAND: —',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: part.onHand.isNotEmpty ? AppTheme.accentCyan : AppTheme.textMuted,
                                  fontWeight: part.onHand.isNotEmpty ? FontWeight.bold : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: progress,
                      backgroundColor: AppTheme.bgDark,
                      valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${part.qtyPicked} / ${part.qtyRequired}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: isDone ? AppTheme.statusComplete : AppTheme.textLight,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Due: ${part.qtyDue}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.statusPartial),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
