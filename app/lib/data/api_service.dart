import 'dart:io';

import 'package:dio/dio.dart';

import '../core/constants.dart';

class ApiService {
  ApiService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: apiBaseUrl,
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 25),
            headers: {'Accept': 'application/json'},
          ),
        );

  final Dio _dio;

  Future<Response> getLandmarks() async {
    return _dio.get(
      apiEndpoint,
      queryParameters: {'action': apiActionGetLandmarks, 'key': apiKey},
    );
  }

  Future<Response> visitLandmark({
    required int landmarkId,
    required double userLat,
    required double userLon,
  }) async {
    return _dio.post(
      apiEndpoint,
      data: {
        'landmark_id': landmarkId,
        'user_lat': userLat,
        'user_lon': userLon,
      },
      queryParameters: {'action': apiActionVisitLandmark, 'key': apiKey},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
  }

  Future<Response> getJobStatus(int jobId) async {
    return _dio.get(
      apiEndpoint,
      queryParameters: {'action': apiActionGetJobStatus, 'key': apiKey, 'job_id': jobId},
    );
  }

  Future<Response> createLandmark({
    required String title,
    required double lat,
    required double lon,
    File? imageFile,
  }) async {
    final formData = FormData.fromMap({
      'title': title,
      'lat': lat,
      'lon': lon,
    });

    if (imageFile != null) {
      formData.files.add(
        MapEntry(
          'image',
          await MultipartFile.fromFile(
            imageFile.path,
            filename: imageFile.uri.pathSegments.isNotEmpty ? imageFile.uri.pathSegments.last : 'upload.jpg',
          ),
        ),
      );
    }

    return _dio.post(
      apiEndpoint,
      data: formData,
      queryParameters: {
        'action': apiActionCreateLandmark,
        'key': apiKey,
      },
    );
  }

  Future<Response> deleteLandmark(int landmarkId) async {
    return _dio.post(
      apiEndpoint,
      data: {'landmark_id': landmarkId},
      queryParameters: {'action': apiActionDeleteLandmark, 'key': apiKey},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
  }

  Future<Response> restoreLandmark(int landmarkId) async {
    return _dio.post(
      apiEndpoint,
      data: {'landmark_id': landmarkId},
      queryParameters: {'action': apiActionRestoreLandmark, 'key': apiKey},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
  }
}
