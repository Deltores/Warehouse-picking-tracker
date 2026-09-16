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
  final String batchId;
  final int? issuedAt;

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
    this.issuedStatus = 'Pending Issue',
    this.totalItemsPicked = 0,
    this.batchId = '',
    this.issuedAt,
  });

  /// Session duration
  Duration get duration {
    final end = endTime ?? DateTime.now().millisecondsSinceEpoch;
    final diffMs = end - startTime;
    return Duration(milliseconds: diffMs > 0 ? diffMs : 0);
  }

  /// Formatted duration (e.g. "1h 24min", "45 min", "< 1 min")
  String get formattedDuration {
    final d = duration;
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}min';
    } else if (minutes > 0) {
      return '$minutes min';
    } else {
      final seconds = d.inSeconds;
      return seconds > 0 ? '${seconds}s' : '< 1 min';
    }
  }

  /// Format cumulative duration for an iterable of sessions
  static String formatTotalDuration(Iterable<SessionMetadata> sessions) {
    int totalMs = 0;
    for (final s in sessions) {
      totalMs += s.duration.inMilliseconds;
    }
    final d = Duration(milliseconds: totalMs);
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}min';
    } else if (minutes > 0) {
      return '$minutes min';
    } else {
      final seconds = d.inSeconds;
      return seconds > 0 ? '${seconds}s' : '< 1 min';
    }
  }

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

  /// Formatted title for UI cards:
  /// "Tablet 1 • Session #4 (Alex)"
  String get cardDisplayTitle {
    final tab = tabletId.isNotEmpty ? tabletId : 'Tablet';
    final seq = sessionSeqNo > 0 ? '#$sessionSeqNo' : id.substring(0, 8);
    return '$tab • Session $seq ($workerName)';
  }

  /// Formatted session display name:
  /// {TabletID}_Session_{SeqNo}_{PickerName}
  String displayName(String unitName) {
    final tabId = tabletId.isNotEmpty ? tabletId.replaceAll(' ', '') : 'TAB';
    final seq = sessionSeqNo > 0 ? sessionSeqNo.toString() : id.substring(0, 8);
    final pickerSafe = workerName.replaceAll(' ', '_');
    return '${tabId}_Session_${seq}_$pickerSafe';
  }

  /// Formatted session export file name, correctly handling overnight sessions:
  /// {UnitHint}_{TabletID}_Session_{SeqNo}_{PickerName}_{Date}_{Times}.xlsx
  String buildExportFileName(String unitName, {int? customEndTime}) {
    final tabId = tabletId.isNotEmpty ? tabletId.replaceAll(' ', '') : 'TAB';
    final seq = sessionSeqNo > 0 ? sessionSeqNo.toString() : id.substring(0, 8);
    final pickerSafe = workerName.replaceAll(' ', '_');
    final unitSafe = unitName.replaceAll(' ', '_').replaceAll(RegExp(r'[^\w_-]'), '').take(20);

    final startDt = DateTime.fromMillisecondsSinceEpoch(startTime);
    final endMillis = customEndTime ?? endTime ?? DateTime.now().millisecondsSinceEpoch;
    final endDt = DateTime.fromMillisecondsSinceEpoch(endMillis);

    final startDay = '${startDt.year.toString().padLeft(4, '0')}${startDt.month.toString().padLeft(2, '0')}${startDt.day.toString().padLeft(2, '0')}';
    final endDay = '${endDt.year.toString().padLeft(4, '0')}${endDt.month.toString().padLeft(2, '0')}${endDt.day.toString().padLeft(2, '0')}';
    final startTimeStr = '${startDt.hour.toString().padLeft(2, '0')}${startDt.minute.toString().padLeft(2, '0')}';
    final endTimeStr = '${endDt.hour.toString().padLeft(2, '0')}${endDt.minute.toString().padLeft(2, '0')}';

    final prefix = '${unitSafe}_${tabId}_Session_${seq}_$pickerSafe';
    if (startDay == endDay) {
      return '${prefix}_${startDay}_${startTimeStr}_$endTimeStr.xlsx';
    } else {
      // Overnight session spanning across midnight
      return '${prefix}_${startDay}_${startTimeStr}_${endDay}_$endTimeStr.xlsx';
    }
  }

  /// Helper to generate consolidated batch super export filename:
  /// {UnitHint}_{TabletID}_Batch_SESS_{MinSeq}-{MaxSeq}_{Date}_{Times}.xlsx
  static String buildBatchExportFileName({
    required String unitName,
    required String tabletId,
    required int minSeq,
    required int maxSeq,
    required int startTime,
    required int endTime,
  }) {
    final tabId = tabletId.isNotEmpty ? tabletId.replaceAll(' ', '') : 'TAB';
    final unitSafe = unitName.replaceAll(' ', '_').replaceAll(RegExp(r'[^\w_-]'), '').take(20);
    final startDt = DateTime.fromMillisecondsSinceEpoch(startTime);
    final endDt = DateTime.fromMillisecondsSinceEpoch(endTime);

    final startDay = '${startDt.year.toString().padLeft(4, '0')}${startDt.month.toString().padLeft(2, '0')}${startDt.day.toString().padLeft(2, '0')}';
    final endDay = '${endDt.year.toString().padLeft(4, '0')}${endDt.month.toString().padLeft(2, '0')}${endDt.day.toString().padLeft(2, '0')}';
    final startTimeStr = '${startDt.hour.toString().padLeft(2, '0')}${startDt.minute.toString().padLeft(2, '0')}';
    final endTimeStr = '${endDt.hour.toString().padLeft(2, '0')}${endDt.minute.toString().padLeft(2, '0')}';

    final seqRange = minSeq == maxSeq ? 'SESS_$minSeq' : 'SESS_${minSeq}_to_$maxSeq';
    final prefix = '${unitSafe}_${tabId}_Batch_$seqRange';

    if (startDay == endDay) {
      return '${prefix}_${startDay}_${startTimeStr}_$endTimeStr.xlsx';
    } else {
      return '${prefix}_${startDay}_${startTimeStr}_${endDay}_$endTimeStr.xlsx';
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
    String? batchId,
    int? issuedAt,
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
      batchId: batchId ?? this.batchId,
      issuedAt: issuedAt ?? this.issuedAt,
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
      'batch_id': batchId,
      'issued_at': issuedAt,
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
      issuedStatus: (map['issued_status'] ?? 'Pending Issue') as String,
      totalItemsPicked: (map['total_items_picked'] as num?)?.toInt() ?? 0,
      batchId: (map['batch_id'] ?? '') as String,
      issuedAt: (map['issued_at'] as num?)?.toInt(),
    );
  }
}

extension _StringTake on String {
  String take(int n) => length > n ? substring(0, n) : this;
}
