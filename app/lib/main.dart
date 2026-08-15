import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:workmanager/workmanager.dart';

import 'data/api_service.dart';
import 'database/app_database.dart';
import 'models/landmark.dart';
import 'models/visit_record.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    final database = LocalDatabase();
    final apiService = ApiService();
    
    try {
      final pending = await database.getPendingVisits();
      if (pending.isEmpty) return true;

      bool allSuccessful = true;

      for (final visit in pending) {
        // If specific ID is provided, skip others
        if (inputData != null && inputData.containsKey('visit_local_id')) {
          if (visit.visitId != inputData['visit_local_id']) continue;
        }

        final landmarkId = visit.landmarkId;
        final visitId = visit.visitId;
        var jobId = visit.jobId ?? 0;
        var status = visit.status;

        if (landmarkId <= 0 || visitId <= 0) continue;

        // Step 1: Submit visit if queued
        if (status == 'queued' || jobId <= 0) {
          try {
            final response = await apiService.visitLandmark(
              landmarkId: landmarkId,
              userLat: visit.userLatitude,
              userLon: visit.userLongitude,
            );
            
            final payload = response.data is Map ? Map<String, dynamic>.from(response.data as Map) : <String, dynamic>{};
            jobId = (payload['job_id'] as num?)?.toInt() ?? 0;
            
            if (jobId > 0) {
              status = 'pending';
              await database.updatePendingVisitDetails(visit.id!, jobId, 'pending');
              await database.updateVisitJobId(visitId, jobId, 'pending');
            } else {
              allSuccessful = false;
              continue;
            }
          } catch (e) {
            allSuccessful = false;
            if (e is DioException && e.response?.statusCode == 403) {
              await database.updateVisitStatusById(visitId, 'failed', error: 'Invalid Key');
              await database.deletePendingVisit(visit.id!);
            }
            continue;
          }
        }

        // Step 2: Poll status
        if (status == 'pending' && jobId > 0) {
          bool jobResolved = false;
          // Poll up to 20 times for better reliability
          for (int attempt = 0; attempt < 20; attempt++) {
            try {
              final response = await apiService.getJobStatus(jobId);
              final data = response.data is Map ? Map<String, dynamic>.from(response.data as Map) : <String, dynamic>{};
              final jobStatus = (data['status'] ?? 'pending').toString();

              if (jobStatus == 'done') {
                final distance = (data['distance'] as num?)?.toDouble() ?? 0.0;
                await database.updateVisitStatusById(visitId, 'done', distance: distance);
                await database.deletePendingVisit(visit.id!);
                jobResolved = true;
                break;
              } else if (jobStatus == 'failed') {
                final error = (data['error'] ?? 'API Error').toString();
                await database.updateVisitStatusById(visitId, 'failed', error: error);
                await database.deletePendingVisit(visit.id!);
                jobResolved = true;
                break;
              }
            } catch (_) {}
            await Future.delayed(const Duration(seconds: 3));
          }

          if (!jobResolved) allSuccessful = false;
        }
      }

      return allSuccessful;
    } catch (_) {
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().initialize(callbackDispatcher);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..initialize(),
      child: MaterialApp(
        title: 'Smart Geo Landmarks',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0F9D58), // Rich Green
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

class AppState extends ChangeNotifier {
  final LocalDatabase _database = LocalDatabase();
  final ApiService _apiService = ApiService();
  final ImagePicker _picker = ImagePicker();

  final StreamController<String> _notificationsController = StreamController<String>.broadcast();
  Stream<String> get notifications => _notificationsController.stream;

  List<Landmark> landmarks = [];
  List<VisitRecord> visits = [];
  bool isLoading = false;
  bool isOffline = false;
  String? errorMessage;
  int selectedIndex = 0;

  // Track score range for filtering
  double minLandmarkScore = -1000000.0;
  double maxLandmarkScore = 1000000.0;
  double currentMinFilter = -1000000.0;

  Timer? _syncTimer;

  Future<void> initialize() async {
    await loadCachedLandmarks();
    await loadVisits();
    await refreshLandmarks();

    // Periodic refresh for background job updates in UI
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      loadVisits();
      loadCachedLandmarks();
    });

    // Monitor connectivity changes to sync
    Connectivity().onConnectivityChanged.listen((results) async {
      final hasConnection = results.isNotEmpty && !results.contains(ConnectivityResult.none);
      if (hasConnection) {
        // Use Workmanager to sync when back online
        Workmanager().registerOneOffTask(
          'manual_sync_${DateTime.now().millisecondsSinceEpoch}',
          'syncPendingJobs',
          constraints: Constraints(networkType: NetworkType.connected),
        );
      }
    });
  }

  void setSelectedIndex(int index) {
    selectedIndex = index;
    notifyListeners();
  }

  void setMinScoreFilter(double value) {
    currentMinFilter = value;
    notifyListeners();
  }

  Future<void> loadCachedLandmarks() async {
    final cached = await _database.getLandmarks();
    landmarks = cached.where((l) => l.isActive).toList();
    _updateScoreBounds();
    notifyListeners();
  }

  void _updateScoreBounds() {
    if (landmarks.isNotEmpty) {
      final oldMin = minLandmarkScore;
      final scores = landmarks.map((l) => l.score).toList();
      minLandmarkScore = scores.reduce((a, b) => a < b ? a : b);
      maxLandmarkScore = scores.reduce((a, b) => a > b ? a : b);
      
      // Ensure range is valid for slider
      if (minLandmarkScore >= maxLandmarkScore) {
        maxLandmarkScore = minLandmarkScore + 1.0;
      }
      
      // If we were at the default/edge, or it's first time, stay at the edge to show all
      if (currentMinFilter == -1000000.0 || currentMinFilter == oldMin) {
        currentMinFilter = minLandmarkScore;
      }
      
      // Clamp to current valid range
      if (currentMinFilter < minLandmarkScore) currentMinFilter = minLandmarkScore;
      if (currentMinFilter > maxLandmarkScore) currentMinFilter = maxLandmarkScore;
    }
  }

  Future<void> loadVisits() async {
    visits = await _database.getVisits();
    notifyListeners();
  }

  Future<void> refreshLandmarks() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final response = await _apiService.getLandmarks();
      final data = response.data;
      final items = switch (data) {
        Map map when map['landmarks'] is List => List<dynamic>.from(map['landmarks'] as List),
        List list => list,
        _ => const <dynamic>[],
      };

      final parsed = items
          .map((item) => Landmark.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

      await _database.saveLandmarks(parsed);
      landmarks = parsed.where((landmark) => landmark.isActive).toList();
      _updateScoreBounds();
      isOffline = false;
    } on DioException catch (e) {
      isOffline = true;
      errorMessage = e.message ?? 'Unable to reach API';
      await loadCachedLandmarks();
    } catch (e) {
      isOffline = true;
      errorMessage = e.toString();
      await loadCachedLandmarks();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> visitLandmark(Landmark landmark) async {
    try {
      errorMessage = null;
      notifyListeners();
      
      final location = await getCurrentPosition();
      
      // Save PENDING visit record in local DB (Requirement 3.4)
      final visitId = await _database.queueVisit(
        landmarkId: landmark.id,
        landmarkName: landmark.title,
        userLat: location.latitude,
        userLon: location.longitude,
      );

      // Enqueue WorkManager task (Requirement 3.5 & 10)
      Workmanager().registerOneOffTask(
        'visit_sync_${visitId}_${DateTime.now().millisecondsSinceEpoch}',
        'syncPendingJobs',
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 1),
        inputData: {'visit_local_id': visitId},
      );

      final connectivity = await Connectivity().checkConnectivity();
      final offline = connectivity.contains(ConnectivityResult.none) || connectivity.isEmpty;

      if (offline) {
        _notificationsController.add('Offline: Visit to ${landmark.title} queued.');
      } else {
        _notificationsController.add('Visit request for ${landmark.title} sent to background.');
      }

      await loadVisits();
      notifyListeners();
    } catch (e) {
      errorMessage = e.toString().replaceAll('Exception: ', '');
      _notificationsController.add('Error: $errorMessage');
      notifyListeners();
    }
  }


  Future<void> createLandmark({
    required String title,
    required double lat,
    required double lon,
    File? image,
  }) async {
    await _apiService.createLandmark(title: title, lat: lat, lon: lon, imageFile: image);
    await refreshLandmarks();
  }

  Future<void> deleteLandmark(int id) async {
    try {
      // Optimistic update: mark as deleted locally first for instant UI response
      landmarks = landmarks.where((l) => l.id != id).toList();
      notifyListeners();

      await _apiService.deleteLandmark(id);
      await _database.softDeleteLandmark(id);
      
      // Removed generic notification to allow UI-specific SnackBar with UNDO
    } catch (e) {
      errorMessage = 'Failed to delete landmark: ${e.toString()}';
      _notificationsController.add('Error: $errorMessage');
      // Refresh to restore state if deletion failed
      await refreshLandmarks();
    }
  }

  Future<void> restoreLandmark(int id) async {
    try {
      await _apiService.restoreLandmark(id);
      
      // Update local database
      await _database.database.then((db) => db.update(
        'landmarks',
        {'is_active': 1},
        where: 'id = ?',
        whereArgs: [id],
      ));
      
      // Refresh local state immediately from cache
      await loadCachedLandmarks();
      
      // Sync with server to ensure everything is up to date
      await refreshLandmarks();
      
      _notificationsController.add('Landmark restored successfully.');
    } catch (e) {
      errorMessage = 'Failed to restore landmark: ${e.toString()}';
      _notificationsController.add('Error: $errorMessage');
      await refreshLandmarks(); // Refresh anyway to ensure sync
    }
  }

  Future<Position> getCurrentPosition() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw Exception('Location permission denied. Please enable location access in Settings.');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location access is permanently denied. Please enable it in app settings.');
    }
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw Exception('Location services are disabled. Please enable location in Settings.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 30),
      ),
    ).timeout(
      const Duration(seconds: 35),
      onTimeout: () => throw Exception('Location request timed out. Please try again.'),
    );
  }

  Future<Position?> autoFetchLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        final enabled = await Geolocator.isLocationServiceEnabled();
        if (enabled) {
          return await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 15),
            ),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<File?> pickImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return null;

    final file = File(picked.path);
    final sizeInMb = file.lengthSync() / (1024 * 1024);
    if (sizeInMb > 2) {
      throw Exception('Image size must be 2 MB or less');
    }

    final lower = p.extension(file.path).toLowerCase();
    if (!['.jpg', '.jpeg', '.png', '.webp'].contains(lower)) {
      throw Exception('Unsupported image type. Use JPG, PNG, or WEBP');
    }

    return file;
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _notificationsController.close();
    super.dispose();
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<String>? _notificationSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      _notificationSub = appState.notifications.listen((message) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _notificationSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final pages = [
      MapTab(landmarks: appState.landmarks),
      LandmarkListTab(landmarks: appState.landmarks),
      ActivityTab(visits: appState.visits),
      AddLandmarkTab(appState: appState),
    ];

    return Scaffold(
      body: IndexedStack(index: appState.selectedIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: appState.selectedIndex,
        onDestinationSelected: (index) {
          appState.setSelectedIndex(index);
          // Refresh data when switching tabs to ensure latest background updates are visible
          if (index == 2) appState.loadVisits();
          if (index == 1 || index == 0) appState.loadCachedLandmarks();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: 'Landmarks'),
          NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'Activity'),
          NavigationDestination(icon: Icon(Icons.add_circle_outline), selectedIcon: Icon(Icons.add_circle), label: 'Add/View'),
        ],
      ),
    );
  }
}

class MapTab extends StatefulWidget {
  const MapTab({super.key, required this.landmarks});

  final List<Landmark> landmarks;

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final MapController _mapController = MapController();
  bool _myLocationEnabled = false;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
  }

  Future<void> _checkLocationPermission() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
      if (mounted) {
        setState(() {
          _myLocationEnabled = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Filter active landmarks
    final activeLandmarks = widget.landmarks.where((item) => item.isActive).toList();
    final markers = <Marker>[];

    if (activeLandmarks.isNotEmpty) {
      final minScore = activeLandmarks.map((item) => item.score).reduce((a, b) => a < b ? a : b);
      final maxScore = activeLandmarks.map((item) => item.score).reduce((a, b) => a > b ? a : b);

      for (final landmark in activeLandmarks) {
        markers.add(
          Marker(
            point: latlong.LatLng(landmark.lat, landmark.lon),
            width: 80,
            height: 80,
            child: GestureDetector(
              onTap: () => _showDetailsSheet(landmark),
              child: Icon(
                Icons.location_on,
                size: 40,
                color: _scoreToColor(landmark.score, minScore, maxScore),
              ),
            ),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Landmarks Map', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: FlutterMap(
        mapController: _mapController,
        options: const MapOptions(
          initialCenter: latlong.LatLng(23.6850, 90.3563), // Center on Bangladesh
          initialZoom: 7.0,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.smart_geotagged_landmarks',
          ),
          MarkerLayer(markers: markers),
        ],
      ),
    );
  }

  Color _scoreToColor(double score, double minScore, double maxScore) {
    if (maxScore <= minScore) return Colors.blue;
    final ratio = ((score - minScore) / (maxScore - minScore)).clamp(0.0, 1.0);
    // Red (0.0) -> Yellow/Orange (0.5) -> Green (1.0)
    if (ratio < 0.5) {
      return Color.lerp(Colors.red, Colors.orange, ratio * 2)!;
    } else {
      return Color.lerp(Colors.orange, Colors.green, (ratio - 0.5) * 2)!;
    }
  }

  void _showDetailsSheet(Landmark landmark) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LandmarkDetailsSheet(landmark: landmark),
    );
  }
}

class LandmarkListTab extends StatefulWidget {
  const LandmarkListTab({super.key, required this.landmarks});

  final List<Landmark> landmarks;

  @override
  State<LandmarkListTab> createState() => _LandmarkListTabState();
}

class _LandmarkListTabState extends State<LandmarkListTab> {
  bool sortAscending = false;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    
    // Filter active landmarks
    final activeLandmarks = widget.landmarks.where((l) => l.isActive).toList();

    var filtered = activeLandmarks.where((l) => l.score >= appState.currentMinFilter).toList();
    filtered.sort((a, b) => sortAscending ? a.score.compareTo(b.score) : b.score.compareTo(a.score));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Landmarks', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Min Score: ${appState.currentMinFilter.toStringAsFixed(1)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    FilterChip(
                      avatar: Icon(sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
                      label: Text(sortAscending ? 'Score: Low→High' : 'Score: High→Low'),
                      onSelected: (_) => setState(() => sortAscending = !sortAscending),
                      selected: true,
                      selectedColor: Theme.of(context).colorScheme.primaryContainer,
                      labelStyle: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer),
                    ),
                  ],
                ),
                Slider(
                  value: appState.currentMinFilter.clamp(appState.minLandmarkScore, appState.maxLandmarkScore),
                  min: appState.minLandmarkScore,
                  max: appState.maxLandmarkScore,
                  activeColor: Theme.of(context).colorScheme.primary,
                  inactiveColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  onChanged: (val) => appState.setMinScoreFilter(val),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4.0),
                  child: Text(
                    'Showing ${filtered.length} of ${activeLandmarks.length} landmarks',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: appState.isLoading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(child: Text('No landmarks matching filters'))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final landmark = filtered[index];
                          return Card(
                            elevation: 1,
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(10),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: landmark.fullImageUrl.isEmpty
                                    ? Container(
                                        width: 56,
                                        height: 56,
                                        color: Colors.grey[200],
                                        child: const Icon(Icons.image_not_supported, color: Colors.grey),
                                      )
                                    : CachedNetworkImage(
                                        imageUrl: landmark.fullImageUrl,
                                        width: 56,
                                        height: 56,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) => Container(
                                          width: 56,
                                          height: 56,
                                          color: Colors.grey[200],
                                          child: const Center(
                                            child: SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            ),
                                          ),
                                        ),
                                        errorWidget: (context, url, error) => Container(
                                          width: 56,
                                          height: 56,
                                          color: Colors.grey[200],
                                          child: const Icon(Icons.broken_image, color: Colors.grey),
                                        ),
                                      ),
                              ),
                              title: Text(
                                landmark.title,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: Text(
                                  'Score: ${landmark.score.toStringAsFixed(1)} • Visits: ${landmark.visitCount}',
                                  style: TextStyle(color: Colors.grey[700]),
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                                    onPressed: () => _confirmDelete(context, appState, landmark),
                                    tooltip: 'Delete Landmark',
                                  ),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Theme.of(context).colorScheme.primary,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                    ),
                                    onPressed: () async {
                                      await appState.visitLandmark(landmark);
                                      if (context.mounted) {
                                        final message = appState.errorMessage ?? 'Visit initiated for ${landmark.title}';
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text(message)),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.place, size: 16),
                                    label: const Text('Visit'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, AppState appState, Landmark landmark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Are you sure you want to delete "${landmark.title}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final landmarkId = landmark.id;
      final landmarkTitle = landmark.title;
      
      await appState.deleteLandmark(landmarkId);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Landmark "$landmarkTitle" deleted'),
            action: SnackBarAction(
              label: 'UNDO',
              onPressed: () => appState.restoreLandmark(landmarkId),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }
}

class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key, required this.visits});

  final List<VisitRecord> visits;

  @override
  Widget build(BuildContext context) {
    final ordered = [...visits]..sort((a, b) => b.visitTime.compareTo(a.visitTime));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity History', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: ordered.isEmpty
          ? const Center(child: Text('No visit history yet'))
          : ListView.builder(
              itemCount: ordered.length,
              itemBuilder: (context, index) {
                final item = ordered[index];
                
                Color statusColor;
                IconData statusIcon;
                switch (item.status) {
                  case 'done':
                    statusColor = Colors.green;
                    statusIcon = Icons.check_circle;
                    break;
                  case 'pending':
                    statusColor = Colors.orange;
                    statusIcon = Icons.hourglass_empty;
                    break;
                  case 'failed':
                    statusColor = Colors.red;
                    statusIcon = Icons.error;
                    break;
                  default:
                    statusColor = Colors.grey;
                    statusIcon = Icons.cloud_queue;
                }

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  elevation: 0.5,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: statusColor.withValues(alpha: 0.1),
                      child: Icon(statusIcon, color: statusColor),
                    ),
                    title: Text(
                      item.landmarkName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      DateFormat('dd MMM yyyy, h:mm a').format(item.visitTime),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          item.status == 'done'
                              ? '${item.distance.toStringAsFixed(1)} m'
                              : item.status.toUpperCase(),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                        if (item.error != null && item.error!.isNotEmpty)
                          SizedBox(
                            width: 120,
                            child: Text(
                              item.error!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: AxisDirection.down == AxisDirection.down ? TextAlign.right : TextAlign.left,
                              style: const TextStyle(color: Colors.red, fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class AddLandmarkTab extends StatefulWidget {
  const AddLandmarkTab({super.key, required this.appState});

  final AppState appState;

  @override
  State<AddLandmarkTab> createState() => _AddLandmarkTabState();
}

class _AddLandmarkTabState extends State<AddLandmarkTab> {
  final _formKey = GlobalKey<FormState>();
  final titleController = TextEditingController();
  final latController = TextEditingController();
  final lonController = TextEditingController();
  File? selectedImage;
  bool isCreating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoFetchGPS();
    });
  }

  Future<void> _autoFetchGPS() async {
    final pos = await widget.appState.autoFetchLocation();
    if (pos != null && mounted) {
      latController.text = pos.latitude.toStringAsFixed(6);
      lonController.text = pos.longitude.toStringAsFixed(6);
    }
  }

  @override
  void dispose() {
    titleController.dispose();
    latController.dispose();
    lonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Landmark', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 0.5,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: titleController,
                        decoration: const InputDecoration(
                          labelText: 'Landmark Title',
                          prefixIcon: Icon(Icons.title),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => (value == null || value.trim().isEmpty) ? 'Please enter a title' : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: latController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(
                                labelText: 'Latitude',
                                prefixIcon: Icon(Icons.explore_outlined),
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) return 'Required';
                                final val = double.tryParse(value);
                                if (val == null || val < -90 || val > 90) return 'Invalid lat';
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: lonController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(
                                labelText: 'Longitude',
                                prefixIcon: Icon(Icons.explore_outlined),
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) return 'Required';
                                final val = double.tryParse(value);
                                if (val == null || val < -180 || val > 180) return 'Invalid lon';
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.white,
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        side: BorderSide(color: Theme.of(context).colorScheme.primary),
                      ),
                      onPressed: () async {
                        try {
                          final position = await widget.appState.getCurrentPosition();
                          latController.text = position.latitude.toStringAsFixed(6);
                          lonController.text = position.longitude.toStringAsFixed(6);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('GPS coordinates updated')),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.gps_fixed),
                      label: const Text('Fetch GPS'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.white,
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        side: BorderSide(color: Theme.of(context).colorScheme.primary),
                      ),
                      onPressed: () async {
                        try {
                          final file = await widget.appState.pickImage();
                          setState(() => selectedImage = file);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.add_photo_alternate),
                      label: const Text('Add Image'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (selectedImage != null)
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    alignment: Alignment.topRight,
                    children: [
                      Image.file(selectedImage!, height: 180, width: double.infinity, fit: BoxFit.cover),
                      IconButton(
                        style: IconButton.styleFrom(backgroundColor: Colors.black45),
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => setState(() => selectedImage = null),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: isCreating ? null : _submitLandmark,
                child: isCreating
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Create Landmark', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submitLandmark() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => isCreating = true);
    try {
      final title = titleController.text.trim();
      final lat = double.parse(latController.text);
      final lon = double.parse(lonController.text);

      await widget.appState.createLandmark(
        title: title,
        lat: lat,
        lon: lon,
        image: selectedImage,
      );

      titleController.clear();
      latController.clear();
      lonController.clear();
      setState(() => selectedImage = null);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Landmark created successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => isCreating = false);
    }
  }
}

class LandmarkDetailsSheet extends StatelessWidget {
  const LandmarkDetailsSheet({super.key, required this.landmark});

  final Landmark landmark;

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: ListView(
          controller: controller,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              landmark.title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Chip(
                  avatar: const Icon(Icons.star, color: Colors.orange, size: 16),
                  label: Text('Score: ${landmark.score.toStringAsFixed(1)}'),
                ),
                const SizedBox(width: 8),
                Chip(
                  avatar: const Icon(Icons.people, size: 16),
                  label: Text('Visits: ${landmark.visitCount}'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.location_on, color: Colors.red),
              title: const Text('Coordinates'),
              subtitle: Text('${landmark.lat.toStringAsFixed(6)}, ${landmark.lon.toStringAsFixed(6)}'),
            ),
            if (landmark.avgDistance > 0)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.map_outlined, color: Colors.blue),
                title: const Text('Average Visit Distance'),
                subtitle: Text('${landmark.avgDistance.toStringAsFixed(2)} meters'),
              ),
            const SizedBox(height: 12),
            if (landmark.fullImageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  imageUrl: landmark.fullImageUrl,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    height: 200,
                    color: Colors.grey[100],
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    height: 200,
                    color: Colors.grey[100],
                    child: const Icon(Icons.broken_image, size: 50, color: Colors.grey),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () async {
                      await appState.visitLandmark(landmark);
                      if (context.mounted) {
                        Navigator.pop(context);
                        final message = appState.errorMessage ?? 'Visit initiated for ${landmark.title}';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(message)),
                        );
                      }
                    },
                    icon: const Icon(Icons.navigation),
                    label: const Text('Visit Landmark', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

