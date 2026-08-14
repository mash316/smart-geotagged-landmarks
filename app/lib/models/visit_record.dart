class VisitRecord {
  VisitRecord({
    this.localId,
    required this.landmarkId,
    required this.landmarkName,
    required this.visitTime,
    required this.distance,
    required this.status,
    required this.error,
    this.jobId,
  });

  final int? localId;
  final int landmarkId;
  final String landmarkName;
  final DateTime visitTime;
  final double distance;
  final String status;
  final String? error;
  final int? jobId;

  factory VisitRecord.fromDbMap(Map<String, dynamic> row) {
    return VisitRecord(
      localId: (row['local_id'] as int?) ?? 0,
      landmarkId: (row['landmark_id'] as int?) ?? 0,
      landmarkName: (row['landmark_name'] as String?) ?? 'Unknown',
      visitTime: DateTime.fromMillisecondsSinceEpoch((row['visit_time'] as int?) ?? DateTime.now().millisecondsSinceEpoch),
      distance: (row['distance'] as num?)?.toDouble() ?? 0.0,
      status: (row['status'] as String?) ?? 'queued',
      error: row['error'] as String?,
      jobId: (row['job_id'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'landmark_id': landmarkId,
      'landmark_name': landmarkName,
      'visit_time': visitTime.millisecondsSinceEpoch,
      'distance': distance,
      'status': status,
      'error': error,
      'job_id': jobId,
    };
  }
}
