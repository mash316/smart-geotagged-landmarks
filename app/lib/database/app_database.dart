import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/landmark.dart';
import '../models/visit_record.dart';

class PendingVisit {
  final int? id;
  final int visitId;
  final int landmarkId;
  final String landmarkName;
  final double userLatitude;
  final double userLongitude;
  final int? jobId;
  final String status;

  PendingVisit({
    this.id,
    required this.visitId,
    required this.landmarkId,
    required this.landmarkName,
    required this.userLatitude,
    required this.userLongitude,
    this.jobId,
    required this.status,
  });

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'visit_id': visitId,
      'landmark_id': landmarkId,
      'landmark_name': landmarkName,
      'user_latitude': userLatitude,
      'user_longitude': userLongitude,
      'job_id': jobId,
      'status': status,
    };
  }

  factory PendingVisit.fromDbMap(Map<String, dynamic> map) {
    return PendingVisit(
      id: map['id'] as int?,
      visitId: map['visit_id'] as int,
      landmarkId: map['landmark_id'] as int,
      landmarkName: map['landmark_name'] as String,
      userLatitude: (map['user_latitude'] as num).toDouble(),
      userLongitude: (map['user_longitude'] as num).toDouble(),
      jobId: map['job_id'] as int?,
      status: map['status'] as String,
    );
  }
}

class LocalDatabase {
  static Database? _database;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = p.join(documentsDirectory.path, 'smart_geo_landmarks.sqlite');

    return openDatabase(
      path,
      version: 3,
      onUpgrade: (db, oldVersion, newVersion) async {
        await db.execute('DROP TABLE IF EXISTS landmarks');
        await db.execute('DROP TABLE IF EXISTS visits');
        await db.execute('DROP TABLE IF EXISTS pending_jobs');
        await db.execute('DROP TABLE IF EXISTS pending_visits');
        
        await db.execute('''
          CREATE TABLE landmarks (
            id INTEGER PRIMARY KEY,
            title TEXT,
            latitude REAL,
            longitude REAL,
            image TEXT,
            is_active INTEGER,
            visit_count INTEGER,
            avg_distance REAL,
            score REAL,
            cached_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE visits (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            landmark_id INTEGER,
            landmark_name TEXT,
            visit_time INTEGER,
            distance REAL,
            status TEXT,
            error TEXT,
            job_id INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE pending_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            visit_id INTEGER,
            landmark_id INTEGER,
            landmark_name TEXT,
            user_latitude REAL,
            user_longitude REAL,
            job_id INTEGER,
            status TEXT
          )
        ''');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE landmarks (
            id INTEGER PRIMARY KEY,
            title TEXT,
            latitude REAL,
            longitude REAL,
            image TEXT,
            is_active INTEGER,
            visit_count INTEGER,
            avg_distance REAL,
            score REAL,
            cached_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE visits (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            landmark_id INTEGER,
            landmark_name TEXT,
            visit_time INTEGER,
            distance REAL,
            status TEXT,
            error TEXT,
            job_id INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE pending_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            visit_id INTEGER,
            landmark_id INTEGER,
            landmark_name TEXT,
            user_latitude REAL,
            user_longitude REAL,
            job_id INTEGER,
            status TEXT
          )
        ''');
      },
    );
  }

  Future<void> saveLandmarks(List<Landmark> landmarks) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('landmarks');
      for (final landmark in landmarks) {
        await txn.insert('landmarks', landmark.toDbMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Landmark>> getLandmarks() async {
    final db = await database;
    final rows = await db.query('landmarks', orderBy: 'score DESC');
    return rows.map((row) => Landmark.fromDbMap(row)).toList();
  }

  Future<List<VisitRecord>> getVisits() async {
    final db = await database;
    final rows = await db.query('visits', orderBy: 'visit_time DESC');
    return rows.map((row) => VisitRecord.fromDbMap(row)).toList();
  }

  Future<int> insertVisitRecord(VisitRecord record) async {
    final db = await database;
    return await db.insert('visits', record.toDbMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> queueVisit({
    required int landmarkId,
    required String landmarkName,
    required double userLat,
    required double userLon,
  }) async {
    final now = DateTime.now();
    final visitId = await insertVisitRecord(VisitRecord(
      landmarkId: landmarkId,
      landmarkName: landmarkName,
      visitTime: now,
      distance: 0,
      status: 'pending',
      error: null,
      jobId: null,
    ));
    await savePendingVisit(PendingVisit(
      visitId: visitId,
      landmarkId: landmarkId,
      landmarkName: landmarkName,
      userLatitude: userLat,
      userLongitude: userLon,
      status: 'pending',
    ));
    return visitId;
  }

  Future<void> savePendingVisit(PendingVisit visit) async {
    final db = await database;
    await db.insert('pending_visits', visit.toDbMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PendingVisit>> getPendingVisits() async {
    final db = await database;
    final rows = await db.query('pending_visits');
    return rows.map((row) => PendingVisit.fromDbMap(row)).toList();
  }

  Future<void> deletePendingVisit(int id) async {
    final db = await database;
    await db.delete('pending_visits', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updatePendingVisitDetails(int id, int jobId, String status) async {
    final db = await database;
    await db.update(
      'pending_visits',
      {
        'job_id': jobId,
        'status': status,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateVisitJobId(int localId, int jobId, String status) async {
    final db = await database;
    await db.update(
      'visits',
      {
        'job_id': jobId,
        'status': status,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> softDeleteLandmark(int id) async {
    final db = await database;
    await db.update(
      'landmarks',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateVisitStatusById(
    int localId,
    String status, {
    double distance = 0,
    String error = '',
  }) async {
    final db = await database;
    await db.update(
      'visits',
      {
        'status': status,
        'distance': distance,
        'error': error.isNotEmpty ? error : null,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }
}
