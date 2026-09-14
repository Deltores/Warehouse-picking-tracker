import '../models/unit_record.dart';
import 'database_service.dart';

class StorageManager {
  /// Maximum number of units stored on the device at one time.
  static const int maxStoredUnits = 200;

  /// Maximum total sessions stored across all units.
  static const int maxStoredSessions = 2000;

  final DatabaseService _dbService;

  StorageManager(this._dbService);

  /// Checks if the number of stored units has reached [maxStoredUnits].
  /// If so, automatically evicts the oldest COMPLETED unit (FIFO) to make room.
  /// Returns the ID of any pruned unit, or null if no prune was needed.
  Future<String?> enforceCapacityLimit() async {
    final allUnits = await _dbService.getAllUnits();
    if (allUnits.length < maxStoredUnits) return null;

    // Prefer oldest completed unit; fallback to oldest by createdAt.
    final completedUnits = allUnits.where((u) => u.isCompleted).toList();
    UnitRecord? toPrune;

    if (completedUnits.isNotEmpty) {
      completedUnits.sort((a, b) {
        final aTime = a.completedAt ?? a.lastAccessedAt;
        final bTime = b.completedAt ?? b.lastAccessedAt;
        return aTime.compareTo(bTime);
      });
      toPrune = completedUnits.first;
    } else {
      final sortedByAge = List<UnitRecord>.from(allUnits)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      toPrune = sortedByAge.first;
    }

    await _dbService.deleteUnit(toPrune.id); // CASCADE deletes sessions too
    return toPrune.id;
  }

  /// Ensures total session count stays within [maxStoredSessions].
  /// Prunes oldest FINISHED sessions globally until under the limit.
  Future<void> enforceSessionLimit() async {
    final total = await _dbService.countSessions();
    if (total < maxStoredSessions) return;

    final toDelete = total - maxStoredSessions + 1;
    for (int i = 0; i < toDelete; i++) {
      await _dbService.deleteOldestFinishedSession();
    }
  }

  /// Admin-only manual deletion of a specific unit and all its sessions.
  Future<void> adminDeleteUnit(String unitId) async {
    await _dbService.deleteUnit(unitId); // CASCADE deletes all unit sessions
  }

  /// Admin-only: wipes the entire database.
  Future<void> adminClearAllUnits() async {
    await _dbService.clearAllData();
  }
}
