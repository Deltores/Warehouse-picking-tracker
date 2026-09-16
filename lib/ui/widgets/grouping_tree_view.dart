import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../engine/grouping_engine.dart';
import '../../models/grouping_preset.dart';
import '../../models/picklist_item.dart';
import '../theme/app_theme.dart';

typedef OnPickQuantityChanged = void Function(
  String department,
  String partId,
  double newTotalPicked,
);

typedef OnSingleItemOverride = void Function(
  PicklistItem item,
  double newPickedQty,
);

/// GroupingTreeView: displays the accordion list of picking nodes.
///
/// - Unit and Department levels are always expanded and non-collapsible
///   (they are already selected upstream in PickerFlowScreen).
/// - Line level has a ⚡ Pick Mode button to start picking from that line.
/// - Department level (when lines are disabled) also has the ⚡ Pick Mode button.
/// - Tapping a leaf Part ID row calls [onLeafPartTapped] to open PickModeScreen.
class GroupingTreeView extends StatelessWidget {
  final List<TreeNode> nodes;
  final OnPickQuantityChanged onPickQuantityChanged;
  final OnSingleItemOverride onSingleItemOverride;

  /// Called when a leaf Part ID row is tapped; passes the partId and its parent group node.
  final void Function(String partId, TreeNode? parentGroupNode)? onLeafPartTapped;

  /// Called when the Pick Mode button on a group node (Resource ID, Line, Dept) is tapped.
  final void Function(TreeNode node)? onPickModeFromNode;

  /// (Legacy) Called when the Pick Mode button on a Line node is tapped.
  final void Function(String? lineLabel)? onPickModeFromLine;
  final Map<String, Map<String, dynamic>>? partFlags;

  const GroupingTreeView({
    super.key,
    required this.nodes,
    required this.onPickQuantityChanged,
    required this.onSingleItemOverride,
    this.onLeafPartTapped,
    this.onPickModeFromNode,
    this.onPickModeFromLine,
    this.partFlags,
  });

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist_rounded, size: 64, color: AppTheme.borderDark),
            SizedBox(height: 16),
            Text(
              'No items to display for the current filter/preset.',
              style: TextStyle(fontSize: 16, color: AppTheme.textMuted),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        return _TreeNodeWidget(
          node: nodes[index],
          parentGroupNode: null,
          onPickQuantityChanged: onPickQuantityChanged,
          onSingleItemOverride: onSingleItemOverride,
          onLeafPartTapped: onLeafPartTapped,
          onPickModeFromNode: onPickModeFromNode,
          onPickModeFromLine: onPickModeFromLine,
          partFlags: partFlags,
          depth: 0,
          isSingleChild: nodes.length == 1,
        );
      },
    );
  }
}

class _TreeNodeWidget extends StatefulWidget {
  final TreeNode node;
  final TreeNode? parentGroupNode;
  final OnPickQuantityChanged onPickQuantityChanged;
  final OnSingleItemOverride onSingleItemOverride;
  final void Function(String partId, TreeNode? parentGroupNode)? onLeafPartTapped;
  final void Function(TreeNode node)? onPickModeFromNode;
  final void Function(String? lineLabel)? onPickModeFromLine;
  final Map<String, Map<String, dynamic>>? partFlags;
  final int depth;
  final bool isSingleChild;

  const _TreeNodeWidget({
    required this.node,
    this.parentGroupNode,
    required this.onPickQuantityChanged,
    required this.onSingleItemOverride,
    required this.depth,
    this.isSingleChild = false,
    this.onLeafPartTapped,
    this.onPickModeFromNode,
    this.onPickModeFromLine,
    this.partFlags,
  });

  @override
  State<_TreeNodeWidget> createState() => _TreeNodeWidgetState();
}

class _TreeNodeWidgetState extends State<_TreeNodeWidget> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    // Requirements:
    // 1. If only 1 resource or department, auto-expand it.
    // 2. If lines exist, lines start collapsed so the picker can choose which line to expand.
    if (widget.node.level == GroupLevel.line) {
      _isExpanded = false;
    } else if (widget.isSingleChild) {
      _isExpanded = true;
    } else {
      _isExpanded = false;
    }
  }

  int get _missingPartsCount {
    if (widget.partFlags == null || widget.partFlags!.isEmpty) return 0;
    final leafPartIds = widget.node.leafItems.map((i) => i.partId).toSet();
    int count = 0;
    for (final pid in leafPartIds) {
      if (widget.partFlags![pid]?['flag_type']?.toString().toUpperCase() == 'MISSING') {
        final items = widget.node.leafItems.where((i) => i.partId == pid);
        final totalDue = items.fold<double>(0.0, (s, i) => s + i.qtyDue);
        if (totalDue > 0.0001) {
          count++;
        }
      }
    }
    return count;
  }

  bool get _isMissing =>
      !widget.node.isComplete &&
      ((widget.partFlags?[widget.node.label]?['flag_type']?.toString().toUpperCase() == 'MISSING') ||
          _missingPartsCount > 0);

  Widget _buildMissingBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.statusDanger.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.statusDanger.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 13, color: AppTheme.statusDanger),
          const SizedBox(width: 3),
          Text(
            '$count MISSING',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: AppTheme.statusDanger,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    if (_isMissing) return AppTheme.statusDanger;
    if (widget.node.isComplete) return AppTheme.statusComplete;
    if (widget.node.isPartial) return AppTheme.statusPartial;
    return AppTheme.statusUnpicked;
  }

  /// Whether this level should always be expanded and not collapsible by the user.
  /// Unit (depth 0) and top-level container (depth <= 1).
  /// In By Department Whole Resource mode, Department is at depth > 1 and is COLLAPSIBLE!
  bool get _isAlwaysExpanded {
    if (widget.node.level == GroupLevel.unit) return true;
    if (widget.node.level == GroupLevel.resourceId && widget.depth <= 1) return true;
    if (widget.node.level == GroupLevel.department && widget.depth <= 1) return true;
    return false;
  }

  /// Whether to show the Pick Mode button inline on this branch node.
  /// In By Department mode, Resource ID contains Department children -> NO Pick Mode on Resource ID!
  /// Pick Mode button is shown on Department nodes (which contain leaf parts).
  /// In Combined mode, Resource ID contains leaf parts -> Pick Mode IS shown on Resource ID.
  bool get _showPickModeButton {
    if (widget.onPickModeFromNode == null && widget.onPickModeFromLine == null) return false;
    if (widget.node.level == GroupLevel.resourceId &&
        widget.node.children.any((c) => c.level == GroupLevel.department)) {
      return false;
    }
    return widget.node.level == GroupLevel.line ||
        widget.node.level == GroupLevel.resourceId ||
        widget.node.children.any((c) => c.isLeaf);
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor();

    if (widget.node.isLeaf) {
      return _buildLeafCard(context, statusColor);
    }

    if (_isAlwaysExpanded) {
      // Non-collapsible: render as a stationary section container with dark banner header and icon
      return Container(
        margin: EdgeInsets.only(
          left: widget.depth * 12.0,
          right: 0,
          top: 6,
          bottom: 6,
        ),
        decoration: BoxDecoration(
          color: AppTheme.bgDark.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderDark.withValues(alpha: 0.8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Static section banner header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: AppTheme.cardDark,
                borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                border: Border(bottom: BorderSide(color: AppTheme.borderDark)),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.node.level == GroupLevel.unit
                        ? Icons.inventory_2_rounded
                        : (widget.node.level == GroupLevel.resourceId
                            ? Icons.precision_manufacturing_rounded
                            : Icons.apartment_rounded),
                    size: 18,
                    color: AppTheme.accentCyan,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${widget.node.level.displayName.toUpperCase()}: ',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                  ),
                  Expanded(
                    child: Text(
                      widget.node.label,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_missingPartsCount > 0) ...[
                    _buildMissingBadge(_missingPartsCount),
                    const SizedBox(width: 8),
                  ],
                  // Progress badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.bgDark,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      '${widget.node.completedParts}/${widget.node.totalParts} parts (${widget.node.partProgress.toStringAsFixed(0)}%)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ),
                  if (_showPickModeButton) ...[
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        minimumSize: const Size(100, 36),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 2,
                      ),
                      icon: const Icon(Icons.bolt_rounded, size: 16),
                      label: const Text('Pick Mode', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        if (widget.onPickModeFromNode != null) {
                          widget.onPickModeFromNode!(widget.node);
                        } else {
                          widget.onPickModeFromLine?.call(
                            widget.node.level == GroupLevel.line ? widget.node.label : null,
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            LinearProgressIndicator(
              value: widget.node.totalParts > 0
                  ? (widget.node.completedParts / widget.node.totalParts).clamp(0.0, 1.0)
                  : 0.0,
              backgroundColor: AppTheme.bgDark,
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
              minHeight: 3,
            ),
            // Children rendered directly below
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.node.children.map((childNode) => _TreeNodeWidget(
                      node: childNode,
                      parentGroupNode: widget.node,
                      onPickQuantityChanged: widget.onPickQuantityChanged,
                      onSingleItemOverride: widget.onSingleItemOverride,
                      onLeafPartTapped: widget.onLeafPartTapped,
                      onPickModeFromNode: widget.onPickModeFromNode,
                      onPickModeFromLine: widget.onPickModeFromLine,
                      partFlags: widget.partFlags,
                      depth: widget.depth + 1,
                      isSingleChild: widget.node.children.length == 1,
                    )).toList(),
              ),
            ),
          ],
        ),
      );
    }

    // Collapsible node (Line, Resource ID when multi, etc.)
    return Card(
      margin: EdgeInsets.only(
        left: widget.depth * 12.0,
        right: 0,
        top: 6,
        bottom: 6,
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey('${widget.node.key}_${widget.node.level.name}'),
          initiallyExpanded: _isExpanded,
          onExpansionChanged: (expanded) {
            setState(() => _isExpanded = expanded);
          },
          leading: Container(
            width: 8,
            height: 36,
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          title: Row(
            children: [
              Text(
                '${widget.node.level.displayName}: ',
                style: const TextStyle(fontSize: 14, color: AppTheme.textMuted, fontWeight: FontWeight.w500),
              ),
              Expanded(
                child: Text(
                  widget.node.label,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Pick Mode button on Line (or Dept/Resource without sub-lines)
              if (_showPickModeButton)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      minimumSize: const Size(110, 42),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 2,
                    ),
                    icon: const Icon(Icons.bolt_rounded, size: 18),
                    label: const Text('Pick Mode', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      if (widget.onPickModeFromNode != null) {
                        widget.onPickModeFromNode!(widget.node);
                      } else {
                        widget.onPickModeFromLine?.call(
                          widget.node.level == GroupLevel.line ? widget.node.label : null,
                        );
                      }
                    },
                  ),
                ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: widget.node.totalParts > 0
                      ? (widget.node.completedParts / widget.node.totalParts).clamp(0.0, 1.0)
                      : 0.0,
                  backgroundColor: AppTheme.bgDark,
                  valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 4),
                Text(
                  _isExpanded ? 'Tap to collapse' : 'Tap to expand',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_missingPartsCount > 0) ...[
                _buildMissingBadge(_missingPartsCount),
                const SizedBox(width: 8),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.bgDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  '${widget.node.completedParts}/${widget.node.totalParts} parts (${widget.node.partProgress.toStringAsFixed(0)}%)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                _isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                color: AppTheme.accentCyan,
                size: 24,
              ),
            ],
          ),
          children: widget.node.children.map((childNode) {
            return _TreeNodeWidget(
              node: childNode,
              parentGroupNode: widget.node,
              onPickQuantityChanged: widget.onPickQuantityChanged,
              onSingleItemOverride: widget.onSingleItemOverride,
              onLeafPartTapped: widget.onLeafPartTapped,
              onPickModeFromNode: widget.onPickModeFromNode,
              onPickModeFromLine: widget.onPickModeFromLine,
              partFlags: widget.partFlags,
              depth: widget.depth + 1,
              isSingleChild: widget.node.children.length == 1,
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildLeafCard(BuildContext context, Color statusColor) {
    final firstItem = widget.node.leafItems.isNotEmpty ? widget.node.leafItems.first : null;
    final onHandItem = widget.node.leafItems.firstWhere(
      (i) => i.onHand.trim().isNotEmpty,
      orElse: () => firstItem ?? PicklistItem(id: '', unitId: '', department: '', line: '', workOrder: '', partId: '', partDescription: '', qtyRequired: 0, qtyDue: 0, qtyPicked: 0, rowOrder: 0),
    );
    final onHandInfo = onHandItem.onHand.trim();

    return Card(
      margin: EdgeInsets.only(
        left: widget.depth * 12.0,
        right: 0,
        top: 4,
        bottom: 4,
      ),
      color: AppTheme.bgDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: statusColor.withValues(alpha: 0.6), width: 1.2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // Tap navigates to unified PickModeScreen — line-scoped or group-scoped
        onTap: () => widget.onLeafPartTapped?.call(widget.node.label, widget.parentGroupNode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              // Status Indicator Dot
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 14),

              // Part Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.node.label,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textLight,
                      ),
                    ),
                    if (_isMissing) ...[
                      const SizedBox(height: 3),
                      Builder(builder: (_) {
                        final flag = widget.partFlags![widget.node.label]!;
                        final ts = flag['created_at'] as int?;
                        final dateStr = ts != null
                            ? DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ts))
                            : '';
                        final note = flag['note']?.toString() ?? '';
                        String pickerName = '';
                        if (note.contains('Marked missing by ')) {
                          pickerName = note.replaceAll('Marked missing by ', '').replaceAll(' in Pick Mode', '').trim();
                        } else if (note.isNotEmpty) {
                          pickerName = note;
                        } else {
                          pickerName = 'Picker';
                        }
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.statusDanger.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: AppTheme.statusDanger.withValues(alpha: 0.6)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.warning_amber_rounded, size: 12, color: AppTheme.statusDanger),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  'MISSING • $pickerName • $dateStr',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.statusDanger),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                    if ((widget.node.partDescription != null && widget.node.partDescription!.isNotEmpty) || onHandInfo.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (widget.node.partDescription != null && widget.node.partDescription!.isNotEmpty)
                            Text(
                              widget.node.partDescription!,
                              style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (onHandInfo.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.accentCyan.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.location_on_rounded, size: 12, color: AppTheme.accentCyan),
                                  const SizedBox(width: 3),
                                  Text(
                                    'ON-HAND: $onHandInfo',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.accentCyan,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                    Builder(builder: (_) {
                      final depts = widget.node.leafItems
                          .map((i) => i.department.trim())
                          .where((d) => d.isNotEmpty)
                          .toSet();
                      if (depts.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          children: [
                            const Icon(Icons.domain_rounded, size: 13, color: Color(0xFF0EA5E9)),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Dept: ${depts.join(', ')}',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF0EA5E9), fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    if (widget.node.leafItems.length > 1) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${widget.node.leafItems.length} Work Orders — tap to pick',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ],
                ),
              ),

              // Quantities Display for this Part ID
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '${PicklistItem.formatQty(widget.node.totalPicked)} ',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: statusColor),
                        ),
                        const TextSpan(
                          text: '/ ',
                          style: TextStyle(fontSize: 14, color: AppTheme.textMuted),
                        ),
                        TextSpan(
                          text: PicklistItem.formatQty(widget.node.totalRequired),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textLight),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Due: ${PicklistItem.formatQty(widget.node.totalDue)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: widget.node.totalDue > 0 ? AppTheme.statusPartial : AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Tap hint
                  const Text(
                    '→ tap to pick',
                    style: TextStyle(fontSize: 10, color: AppTheme.textMuted, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
