/// Application self-update checker.
///
/// Checks the update server for newer releases, compares semantic
/// versions, and returns update metadata for download/installation.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Metadata about an available update release.
class UpdateInfo {
  final String version;
  final String releaseDate;
  final String fullUrl;
  final String? patchUrl;
  final int fullSize;
  final int patchSize;
  final String sha256Full;
  final String? sha256Patch;
  final String? signature;
  final String releaseNotes;

  const UpdateInfo({
    required this.version,
    required this.releaseDate,
    required this.fullUrl,
    this.patchUrl,
    required this.fullSize,
    this.patchSize = 0,
    required this.sha256Full,
    this.sha256Patch,
    this.signature,
    required this.releaseNotes,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String,
      releaseDate: json['release_date'] as String,
      fullUrl: json['full_url'] as String,
      patchUrl: json['patch_url'] as String?,
      fullSize: json['full_size'] as int,
      patchSize: json['patch_size'] as int? ?? 0,
      sha256Full: json['sha256_full'] as String,
      sha256Patch: json['sha256_patch'] as String?,
      signature: json['signature'] as String?,
      releaseNotes: json['release_notes'] as String? ?? '',
    );
  }
}

/// Service that periodically checks for application updates.
class UpdateService {
  static const _updateUrl = 'https://api.bluessh.io/v1/releases/latest';
  static const _currentVersion = '0.1.0';

  final http.Client _client;

  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  /// Checks the update server for a newer release.
  ///
  /// Returns [UpdateInfo] if a newer version is available,
  /// or `null` if the current version is up-to-date or the check fails.
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await _client
          .get(
            Uri.parse(_updateUrl),
            headers: {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final info = UpdateInfo.fromJson(data);

      if (_isVersionNewer(info.version, _currentVersion)) {
        return info;
      }
      return null;
    } catch (e) {
      debugPrint('[UpdateService] Update check failed: $e');
      return null;
    }
  }

  /// Compares two semantic version strings (e.g. "1.2.3").
  /// Returns `true` if [remote] is strictly newer than [current].
  bool _isVersionNewer(String remote, String current) {
    final remoteParts = remote.split('.').map(int.parse).toList();
    final currentParts = current.split('.').map(int.parse).toList();

    for (int i = 0; i < 3; i++) {
      final r = i < remoteParts.length ? remoteParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (r > c) return true;
      if (r < c) return false;
    }
    return false;
  }

  /// Releases the underlying HTTP client.
  void dispose() {
    _client.close();
  }
}
