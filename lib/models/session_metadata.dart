/// Session metadata: tracks a picker's picking session for a specific unit + department.
///
/// Status flow: ACTIVE → CLOSED → EXPORTED → ISSUED (admin action).
///
/// Session IDs are numeric (1–9999, wrapping) scoped per unit. Once a session with
/// zero picks is abandoned, its ID slot is recycled.
class SessionMetadata {
  final String id;         // UUID for internal DB key
  final int sessionSeqNo;  // Numeric display ID (1..9999, per unit)
  final String unitId;
  final String workerName;
  final String tabletId;   // Snapshot of the tablet ID at session creation
  final int startTime;
  final int? endTime;
  final String pickDate;
  final String status;      // 'ACTIVE' | 'CLOSED' | 'EXPORTED' | 'ISSUED'
  final String issuedStatus; // legacy/compat — mirrors status for export hub
  final int totalItemsPicked;

  SessionMetadata({
    required this.id,
    this.sessionSeqNo = 0,
    required this.unitId,
    required this.workerName,
    this.tabletId = '',
    required this.startTime,
    this.endTime,
    required this.pickDate,
    this.status = 'ACTIVE',
    this.issuedStatus = 'Pending',
    this.totalItemsPicked = 0,
  });

  bool get isActive    => status == 'ACTIVE' || status == 'OPEN';
  bool get isClosed    => status == 'CLOSED';
  bool get isExported  => status == 'EXPORTED';
  bool get isFinished  => status == 'EXPORTED' || status == 'FINISHED'; // compat alias
  bool get isIssued    => status == 'ISSUED';

  /// Sessions ready for export hub (picker finished, not just abandoned).
  bool get isReadyToExport => isClosed || isExported || isFinished || isIssued;

  /// Display label for status badges.
  String get statusLabel {
    switch (status) {
      case 'ACTIVE':
      case 'OPEN':      return 'OPEN';
      case 'CLOSED':    return 'CLOSED';
      case 'EXPORTED':  return 'EXPORTED';
      case 'FINISHED':  return 'EXPORTED'; // legacy compat
      case 'ISSUED':    return 'ISSUED';
      default:          return status;
    }
  }

  /// Formatted session display name:
  /// {TabletID}-{SeqNo:03d}-{PickerName}-{UnitHint}
  String displayName(String unitName) {
    final tabId = tabletId.isNotEmpty ? tabletId.replaceAll(' ', '') : 'TAB';
    final seq = sessionSeqNo.toString().padLeft(3, '0');
    final pickerSafe = workerName.replaceAll(' ', '_');
    final unitSafe = unitName.replaceAll(' ', '_').replaceAll(RegExp(r'[^\w_-]'), '').take(20);
    return '$tabId-$seq-$pickerSafe-$unitSafe';
  }

  /// Formatted session export file name, correctly handling overnight sessions:
  /// Same-day:  {TabletID}-{SeqNo:03d}-{PickerName}-{UnitHint}_{yyyyMMdd}_{startHHmm}_{endHHmm}.xlsx
  /// Overnight: {TabletID}-{SeqNo:03d}-{PickerName}-{UnitHint}_{start_yyyyMMdd}_{startHHmm}_{end_yyyyMMdd}_{endHHmm}.xlsx
  String buildExportFileName(String unitName, {int? customEndTime}) {
    final cleanDisplay = displayName(unitName).replaceAll(RegExp(r'[^\w_\-]'), '_');
    final startDt = DateTime.fromMillisecondsSinceEpoch(startTime);
    final endMillis = customEndTime ?? endTime ?? DateTime.now().millisecondsSinceEpoch;
    final endDt = DateTime.fromMillisecondsSinceEpoch(endMillis);

    final startDay = '${startDt.year.toString().padLeft(4, '0')}${startDt.month.toString().padLeft(2, '0')}${startDt.day.toString().padLeft(2, '0')}';
    final endDay = '${endDt.year.toString().padLeft(4, '0')}${endDt.month.toString().padLeft(2, '0')}${endDt.day.toString().padLeft(2, '0')}';
    final startTimeStr = '${startDt.hour.toString().padLeft(2, '0')}${startDt.minute.toString().padLeft(2, '0')}';
    final endTimeStr = '${endDt.hour.toString().padLeft(2, '0')}${endDt.minute.toString().padLeft(2, '0')}';

    if (startDay == endDay) {
      return '${cleanDisplay}_${startDay}_${startTimeStr}_$endTimeStr.xlsx';
    } else {
      // Overnight session spanning across midnight
      return '${cleanDisplay}_${startDay}_${startTimeStr}_${endDay}_$endTimeStr.xlsx';
    }
  }

  SessionMetadata copyWith({
    String? id,
    int? sessionSeqNo,
    String? unitId,
    String? workerName,
    String? tabletId,
    int? startTime,
    int? endTime,
    String? pickDate,
    String? status,
    String? issuedStatus,
    int? totalItemsPicked,
  }) {
    return SessionMetadata(
      id: id ?? this.id,
      sessionSeqNo: sessionSeqNo ?? this.sessionSeqNo,
      unitId: unitId ?? this.unitId,
      workerName: workerName ?? this.workerName,
      tabletId: tabletId ?? this.tabletId,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      pickDate: pickDate ?? this.pickDate,
      status: status ?? this.status,
      issuedStatus: issuedStatus ?? this.issuedStatus,
      totalItemsPicked: totalItemsPicked ?? this.totalItemsPicked,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'session_seq_no': sessionSeqNo,
      'unit_id': unitId,
      'worker_name': workerName,
      'tablet_id': tabletId,
      'start_time': startTime,
      'end_time': endTime,
      'pick_date': pickDate,
      'status': status,
      'issued_status': issuedStatus,
      'total_items_picked': totalItemsPicked,
    };
  }

  factory SessionMetadata.fromMap(Map<String, dynamic> map) {
    return SessionMetadata(
      id: map['id'] as String,
      sessionSeqNo: (map['session_seq_no'] as num?)?.toInt() ?? 0,
      unitId: map['unit_id'] as String,
      workerName: (map['worker_name'] ?? '') as String,
      tabletId: (map['tablet_id'] ?? '') as String,
      startTime: (map['start_time'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      endTime: (map['end_time'] as num?)?.toInt(),
      pickDate: (map['pick_date'] ?? '') as String,
      status: (map['status'] ?? 'ACTIVE') as String,
      issuedStatus: (map['issued_status'] ?? 'Pending') as String,
      totalItemsPicked: (map['total_items_picked'] as num?)?.toInt() ?? 0,
    );
  }
}

extension _StringTake on String {
  String take(int n) => length > n ? substring(0, n) : this;
}
