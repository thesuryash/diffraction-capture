import 'dart:typed_data';

import 'package:dio/dio.dart';

/// DTO for the backend slit-width analysis response.
class AnalysisResult {
  final double widthPixels;
  final double? widthPhysical;
  final double? pixelSize;

  const AnalysisResult({
    required this.widthPixels,
    this.widthPhysical,
    this.pixelSize,
  });

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    return AnalysisResult(
      widthPixels: (json['width_pixels'] as num).toDouble(),
      widthPhysical: (json['width_physical'] as num?)?.toDouble(),
      pixelSize: (json['pixel_size'] as num?)?.toDouble(),
    );
  }
}

/// Minimal client that allows Flutter to call the Python backend over HTTP.
class BackendClient {
  final Dio _dio;
  final String baseUrl;

  BackendClient({
    required this.baseUrl,
    Dio? dio,
  }) : _dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl));

  /// Sends an image to the backend for analysis.
  ///
  /// The optional [pixelSize] parameter can be used to translate the detected
  /// width in pixels to a physical measurement on the server side.
  Future<AnalysisResult> analyzeImage(
    Uint8List imageBytes, {
    double? pixelSize,
  }) async {
    final formData = FormData.fromMap({
      'image': MultipartFile.fromBytes(
        imageBytes,
        filename: 'capture.jpg',
      ),
      if (pixelSize != null) 'pixel_size': pixelSize.toString(),
    });

    final response = await _dio.post<Map<String, dynamic>>(
      '/analyze',
      data: formData,
      options: Options(responseType: ResponseType.json),
    );

    final body = response.data;
    if (body == null) {
      throw Exception('Backend returned an empty response');
    }

    return AnalysisResult.fromJson(body);
  }
}
