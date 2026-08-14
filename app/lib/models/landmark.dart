import '../core/constants.dart';

class Landmark {
  Landmark({
    required this.id,
    required this.title,
    required this.lat,
    required this.lon,
    required this.image,
    required this.isActive,
    required this.visitCount,
    required this.avgDistance,
    required this.score,
    required this.cachedAt,
  });

  final int id;
  final String title;
  final double lat;
  final double lon;
  final String image;
  final bool isActive;
  final int visitCount;
  final double avgDistance;
  final double score;
  final DateTime cachedAt;

  factory Landmark.fromJson(Map<String, dynamic> json) {
    return Landmark(
      id: int.tryParse('${json['id'] ?? 0}') ?? 0,
      title: (json['title'] ?? '').toString(),
      lat: double.tryParse('${json['lat'] ?? 0}') ?? 0.0,
      lon: double.tryParse('${json['lon'] ?? 0}') ?? 0.0,
      image: (json['image'] ?? '').toString().replaceAll('\\', '/'),
      isActive: (json['is_active'] ?? 1) == 1,
      visitCount: int.tryParse('${json['visit_count'] ?? 0}') ?? 0,
      avgDistance: double.tryParse('${json['avg_distance'] ?? 0}') ?? 0.0,
      score: double.tryParse('${json['score'] ?? 0}') ?? 0.0,
      cachedAt: DateTime.now(),
    );
  }

  factory Landmark.fromDbMap(Map<String, dynamic> row) {
    return Landmark(
      id: (row['id'] as int?) ?? 0,
      title: (row['title'] as String?) ?? '',
      lat: (row['latitude'] as num?)?.toDouble() ?? 0,
      lon: (row['longitude'] as num?)?.toDouble() ?? 0,
      image: (row['image'] as String?) ?? '',
      isActive: (row['is_active'] as int?) == 1,
      visitCount: (row['visit_count'] as int?) ?? 0,
      avgDistance: (row['avg_distance'] as num?)?.toDouble() ?? 0,
      score: (row['score'] as num?)?.toDouble() ?? 0,
      cachedAt: DateTime.fromMillisecondsSinceEpoch((row['cached_at'] as int?) ?? DateTime.now().millisecondsSinceEpoch),
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'title': title,
      'latitude': lat,
      'longitude': lon,
      'image': image,
      'is_active': isActive ? 1 : 0,
      'visit_count': visitCount,
      'avg_distance': avgDistance,
      'score': score,
      'cached_at': cachedAt.millisecondsSinceEpoch,
    };
  }

  String get fullImageUrl {
    if (image.trim().isEmpty) return '';
    return '$apiBaseUrl$image';
  }
}
