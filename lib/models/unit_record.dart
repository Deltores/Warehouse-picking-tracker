class UnitRecord {
  final String id;
  final String name;
  final String filePath;
  final int totalRequired;
  final int totalPicked;
  final String status; // 'IN_PROGRESS' or 'COMPLETED'
  final int createdAt;
  final int? completedAt;
  final int lastAccessedAt;
  final int? deletedAt; // Non-null if soft-deleted (30-day grace period)

  UnitRecord({
    required this.id,
    required this.name,
    required this.filePath,
    required this.totalRequired,
    required this.totalPicked,
    this.status = 'IN_PROGRESS',
    required this.createdAt,
    this.completedAt,
    required this.lastAccessedAt,
    this.deletedAt,
  });

  bool get isCompleted => status == 'COMPLETED' || (totalRequired > 0 && totalPicked >= totalRequired);
  bool get isDeleted => deletedAt != null;
  double get progressPercentage => totalRequired > 0 ? (totalPicked / totalRequired) * 100 : 0.0;

  UnitRecord copyWith({
    String? id,
    String? name,
    String? filePath,
    int? totalRequired,
    int? totalPicked,
    String? status,
    int? createdAt,
    int? completedAt,
    int? lastAccessedAt,
    int? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return UnitRecord(
      id: id ?? this.id,
      name: name ?? this.name,
      filePath: filePath ?? this.filePath,
      totalRequired: totalRequired ?? this.totalRequired,
      totalPicked: totalPicked ?? this.totalPicked,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'file_path': filePath,
      'total_required': totalRequired,
      'total_picked': totalPicked,
      'status': status,
      'created_at': createdAt,
      'completed_at': completedAt,
      'last_accessed_at': lastAccessedAt,
      'deleted_at': deletedAt,
    };
  }

  factory UnitRecord.fromMap(Map<String, dynamic> map) {
    return UnitRecord(
      id: map['id'] as String,
      name: (map['name'] ?? '') as String,
      filePath: (map['file_path'] ?? '') as String,
      totalRequired: (map['total_required'] as num?)?.toInt() ?? 0,
      totalPicked: (map['total_picked'] as num?)?.toInt() ?? 0,
      status: (map['status'] ?? 'IN_PROGRESS') as String,
      createdAt: (map['created_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      completedAt: (map['completed_at'] as num?)?.toInt(),
      lastAccessedAt: (map['last_accessed_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      deletedAt: (map['deleted_at'] as num?)?.toInt(),
    );
  }
}
