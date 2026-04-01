/// Encrypted credential storage service.
///
/// Stores sensitive fields (passwords, key data, MFA secrets) in the
/// platform's secure enclave, while non-sensitive profile data remains
/// in SharedPreferences for fast loading.
library;

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host_profile.dart';

/// Android-specific secure storage options.
const _androidOptions = AndroidOptions(
  encryptedSharedPreferences: true,
  sharedPreferencesName: 'bluessh_secure_prefs',
);

/// Linux-specific options — uses libsecret (GNOME Keyring).
const _linuxOptions = LinuxOptions();

/// Windows-specific options — uses Data Protection API (DPAPI).
const _windowsOptions = WindowsOptions();

class CredentialService {
  static CredentialService? _instance;

  final FlutterSecureStorage _storage;

  CredentialService._()
      : _storage = const FlutterSecureStorage(
          aOptions: _androidOptions,
          lOptions: _linuxOptions,
          wOptions: _windowsOptions,
        );

  /// Returns the singleton instance.
  factory CredentialService.instance() =>
      _instance ??= CredentialService._();

  /// Stores the sensitive fields of a [HostProfile] in secure storage.
  Future<void> saveCredentials(HostProfile profile) async {
    final creds = <String, String>{};

    if (profile.password != null && profile.password!.isNotEmpty) {
      creds['password'] = profile.password!;
    }
    if (profile.keyData != null && profile.keyData!.isNotEmpty) {
      creds['keyData'] = profile.keyData!;
    }
    if (profile.passphrase != null && profile.passphrase!.isNotEmpty) {
      creds['passphrase'] = profile.passphrase!;
    }
    if (profile.mfaSecret != null && profile.mfaSecret!.isNotEmpty) {
      creds['mfaSecret'] = profile.mfaSecret!;
    }
    if (profile.jumpPassword != null && profile.jumpPassword!.isNotEmpty) {
      creds['jumpPassword'] = profile.jumpPassword!;
    }

    await _storage.write(
      key: 'creds_${profile.id}',
      value: jsonEncode(creds),
    );
  }

  /// Reads the sensitive fields back from secure storage.
  Future<Map<String, String>> loadCredentials(String profileId) async {
    final raw = await _storage.read(key: 'creds_$profileId');
    if (raw == null || raw.isEmpty) return {};

    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  /// Removes stored credentials for a deleted profile.
  Future<void> deleteCredentials(String profileId) async {
    await _storage.delete(key: 'creds_$profileId');
  }

  /// Writes credentials AND non-sensitive profile data to their
  /// respective stores in a single call.
  Future<void> saveProfile(HostProfile profile) async {
    final prefs = await SharedPreferences.getInstance();

    // Save non-sensitive fields to SharedPreferences
    final profiles = prefs.getStringList('host_profiles') ?? [];
    profiles.removeWhere((raw) {
      try {
        final existing = jsonDecode(raw) as Map<String, dynamic>;
        return existing['id'] == profile.id;
      } catch (_) {
        return true;
      }
    });
    profiles.add(jsonEncode(profile.toJson()));
    await prefs.setStringList('host_profiles', profiles);

    // Save sensitive fields to secure storage
    await saveCredentials(profile);
  }

  /// Loads a complete [HostProfile] by merging SharedPreferences
  /// (non-sensitive) with secure storage (sensitive).
  Future<List<HostProfile>> loadAllProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('host_profiles') ?? [];

    final profiles = <HostProfile>[];
    for (final entry in raw) {
      try {
        final json = jsonDecode(entry) as Map<String, dynamic>;
        final creds = await loadCredentials(json['id'] as String);

        json['password'] = creds['password'];
        json['keyData'] = creds['keyData'];
        json['passphrase'] = creds['passphrase'];
        json['mfaSecret'] = creds['mfaSecret'];
        json['jumpPassword'] = creds['jumpPassword'];

        profiles.add(HostProfile.fromJson(json));
      } catch (_) {
        // Skip corrupted entries
      }
    }

    profiles.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return profiles;
  }

  /// Deletes both the profile metadata and its credentials.
  Future<void> deleteProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = prefs.getStringList('host_profiles') ?? [];
    profiles.removeWhere((raw) {
      try {
        final existing = jsonDecode(raw) as Map<String, dynamic>;
        return existing['id'] == profileId;
      } catch (_) {
        return true;
      }
    });
    await prefs.setStringList('host_profiles', profiles);
    await deleteCredentials(profileId);
  }
}
