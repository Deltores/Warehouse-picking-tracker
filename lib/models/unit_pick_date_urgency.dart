import 'package:intl/intl.dart';

/// Urgency status for a unit based on its earliest incomplete pick date:
/// - pastDue: < 0 days (past due date) -> Glow RED (#FF3B30)
/// - dueSoon: 0..2 days from today -> Glow YELLOW (#FFB300)
/// - normal: > 2 days from today -> Glow BLUE (#2196F3)
/// - completed: All parts picked or flagged missing -> GREEN checkmark (#00E676)
/// - none: No pick date available
enum UnitUrgencyStatus {
  pastDue,
  dueSoon,
  normal,
  completed,
  none,
}

class UnitPickDateUrgency {
  final String? earliestPickDateStr;
  final DateTime? earliestPickDate;
  final String? department;
  final int? daysRemaining;
  final bool isAllCompleted;
  final UnitUrgencyStatus status;

  const UnitPickDateUrgency({
    this.earliestPickDateStr,
    this.earliestPickDate,
    this.department,
    this.daysRemaining,
    required this.isAllCompleted,
    required this.status,
  });

  /// Robust date parser supporting ISO, Excel serial dates, US, and European formats.
  static DateTime? parseDateRobust(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;

    // 1. Try standard ISO
    final iso = DateTime.tryParse(s);
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);

    // 2. Try Excel serial date (e.g. 45548 or 45548.0)
    final numVal = double.tryParse(s);
    if (numVal != null && numVal > 30000 && numVal < 65000) {
      final base = DateTime(1899, 12, 30);
      final dt = base.add(Duration(days: numVal.toInt()));
      return DateTime(dt.year, dt.month, dt.day);
    }

    final datePart = s.split(' ').first;
    final formats = [
      'yyyy-MM-dd',
      'MM/dd/yyyy',
      'M/d/yyyy',
      'dd/MM/yyyy',
      'd/M/yyyy',
      'yyyy/MM/dd',
      'dd.MM.yyyy',
      'd.M.yyyy',
      'yyyy.MM.dd',
      'MM-dd-yyyy',
      'dd-MM-yyyy',
    ];

    for (final fmt in formats) {
      try {
        final dt = DateFormat(fmt).parseStrict(datePart);
        return DateTime(dt.year, dt.month, dt.day);
      } catch (_) {}
    }

    return null;
  }

  /// Formats raw date string (e.g. ISO 2026-09-18T00:00:00.000Z, Excel serial, etc.) into clean yyyy-MM-dd.
  static String formatShortDate(String? raw) {
    if (raw == null) return '';
    final s = raw.trim();
    if (s.isEmpty) return '';
    final dt = parseDateRobust(s);
    if (dt != null) {
      return DateFormat('yyyy-MM-dd').format(dt);
    }
    // Fallback: if it starts with yyyy-MM-dd, extract it
    final match = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(s);
    if (match != null) return match.group(1)!;
    return s;
  }

  /// Evaluates urgency given date string, department, completion status, and optional reference date.
  static UnitPickDateUrgency evaluate({
    required String? dateStr,
    required String? department,
    required bool isAllCompleted,
    DateTime? referenceToday,
  }) {
    final cleanDateStr = formatShortDate(dateStr);
    if (isAllCompleted) {
      return UnitPickDateUrgency(
        earliestPickDateStr: cleanDateStr.isNotEmpty ? cleanDateStr : dateStr,
        department: department,
        isAllCompleted: true,
        status: UnitUrgencyStatus.completed,
      );
    }

    final parsed = parseDateRobust(dateStr);
    if (parsed == null) {
      return UnitPickDateUrgency(
        earliestPickDateStr: cleanDateStr.isNotEmpty ? cleanDateStr : dateStr,
        department: department,
        isAllCompleted: false,
        status: UnitUrgencyStatus.none,
      );
    }

    final ref = referenceToday ?? DateTime.now();
    final today = DateTime(ref.year, ref.month, ref.day);
    final days = parsed.difference(today).inDays;

    UnitUrgencyStatus st;
    if (days < 0) {
      st = UnitUrgencyStatus.pastDue; // Red: past due date
    } else if (days <= 2) {
      st = UnitUrgencyStatus.dueSoon; // Yellow: 2 days or less
    } else {
      st = UnitUrgencyStatus.normal;  // Green: > 2 days
    }

    return UnitPickDateUrgency(
      earliestPickDateStr: dateStr,
      earliestPickDate: parsed,
      department: department,
      daysRemaining: days,
      isAllCompleted: false,
      status: st,
    );
  }
}
