import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Interface for persistent log storage.
abstract class LogDatabase {
  Future<void> insertLog({
    required int timestamp,
    required String level,
    required String tag,
    required String message,
    required String stackTrace,
  });
  Future<Map<String, dynamic>> getLogsStats();
  Future<int> pruneOldestLogs(int countToPrune);
  Future<List<Map<String, dynamic>>> getAllLogsForExport();
}

/// App-wide logging service:
/// - Captures events, errors, crashes, and unhandled exceptions.
/// - Maximum storage cap: 49 MB (auto-prunes oldest logs when exceeded).
/// - Export all logs to CSV with proper RFC 4180 escaping.
class LogService {
  static LogDatabase? _db;
  static const int maxLogSizeBytes = 49 * 1024 * 1024; // 49 MB
  static int _approxSizeCheckCounter = 0;

  static void init(LogDatabase db) {
    _db = db;
  }

  static Future<void> info(String tag, String message) => log('INFO', tag, message);
  static Future<void> warn(String tag, String message) => log('WARN', tag, message);
  static Future<void> error(String tag, String message, {dynamic stackTrace}) =>
      log('ERROR', tag, message, stackTrace: stackTrace?.toString());
  static Future<void> crash(String tag, dynamic error, {dynamic stackTrace}) =>
      log('CRASH', tag, error.toString(), stackTrace: stackTrace?.toString());
  static Future<void> picker(String message) => log('INFO', 'PICKER', message);
  static Future<void> admin(String message) => log('INFO', 'ADMIN', message);
  static Future<void> superAdmin(String message) => log('INFO', 'SUPER ADMIN', message);

  static Future<void> log(
    String level,
    String tag,
    String message, {
    String? stackTrace,
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_db != null) {
        await _db!.insertLog(
          timestamp: now,
          level: level,
          tag: tag,
          message: message,
          stackTrace: stackTrace ?? '',
        );

        // Periodically enforce 49 MB limit
        _approxSizeCheckCounter++;
        if (_approxSizeCheckCounter >= 50) {
          _approxSizeCheckCounter = 0;
          await enforceSizeLimit();
        }
      }
    } catch (_) {
      // Avoid failing app execution on logging error
    }
  }

  /// Automatically prunes oldest logs if total size exceeds 49 MB.
  static Future<void> enforceSizeLimit() async {
    if (_db == null) return;
    try {
      final stats = await _db!.getLogsStats();
      final size = stats['sizeBytes'] as int? ?? 0;
      if (size >= maxLogSizeBytes) {
        final totalCount = stats['count'] as int? ?? 0;
        final toPrune = (totalCount * 0.2).ceil().clamp(100, 5000);
        await _db!.pruneOldestLogs(toPrune);
      }
    } catch (_) {}
  }

  /// Formats all stored logs into an RFC 4180 compliant CSV file.
  static Future<String> exportLogsToCsv(String destinationDir) async {
    if (_db == null) throw Exception('Database not initialized');
    final rows = await _db!.getAllLogsForExport();

    final buffer = StringBuffer();
    buffer.writeln('ID,Timestamp,DateTime,Level,Tag,Message,StackTrace');

    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      final ts = (row['timestamp'] as num?)?.toInt() ?? 0;
      final dt = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(
        DateTime.fromMillisecondsSinceEpoch(ts),
      );
      final level = row['level']?.toString() ?? '';
      final tag = row['tag']?.toString() ?? '';
      final message = row['message']?.toString() ?? '';
      final stack = row['stack_trace']?.toString() ?? '';

      buffer.writeln(
        '${escapeCsv(id)},${escapeCsv(ts.toString())},${escapeCsv(dt)},'
        '${escapeCsv(level)},${escapeCsv(tag)},${escapeCsv(message)},${escapeCsv(stack)}',
      );
    }

    final nowStr = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final outPath = p.join(destinationDir, 'app_logs_$nowStr.csv');
    final file = File(outPath);
    try {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(buffer.toString(), flush: true);
      return outPath;
    } on FileSystemException {
      // If external path failed (e.g. Permission Denied), save to app documents directory as fallback
      final appDir = await getApplicationDocumentsDirectory();
      final fallbackPath = p.join(appDir.path, 'app_logs_$nowStr.csv');
      final fallbackFile = File(fallbackPath);
      await fallbackFile.writeAsString(buffer.toString(), flush: true);
      return fallbackPath;
    }
  }

  /// RFC 4180 escaping helper for CSV strings.
  static String escapeCsv(String field) {
    if (field.contains(',') ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }
}
