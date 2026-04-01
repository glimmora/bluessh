/// Runtime permission handler for Android and iOS.
///
/// Checks and requests permissions required for SSH connections,
/// foreground service notifications, file storage access, and
/// clipboard sharing. Falls back gracefully on platforms where
/// permissions are not applicable (desktop).
library;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Result of a permission request batch.
class PermissionResult {
  /// True if all required permissions are granted.
  final bool allGranted;

  /// Map of each permission to its final status.
  final Map<Permission, PermissionStatus> statuses;

  /// Permissions that were permanently denied by the user.
  final List<Permission> permanentlyDenied;

  const PermissionResult({
    required this.allGranted,
    required this.statuses,
    required this.permanentlyDenied,
  });
}

/// Handles runtime permission checks and interactive requests.
class PermissionService {
  /// Permissions required before establishing an SSH connection.
  ///
  /// - [Permission.notification] — needed on Android 13+ (API 33) for the
  ///   foreground service notification that keeps the session alive.
  /// - [Permission.storage] — needed on Android < 11 for SFTP file
  ///   downloads/uploads. On Android 11+ this uses MediaStore / SAF.
  static List<Permission> get _connectionPermissions {
    if (!Platform.isAndroid) return [];
    return [
      Permission.notification,
    ];
  }

  /// Permissions needed for SFTP file operations.
  static List<Permission> get _storagePermissions {
    if (!Platform.isAndroid) return [];
    return [
      Permission.storage,
    ];
  }

  /// Checks whether all connection-critical permissions are already granted.
  ///
  /// Returns true if no interactive prompt is needed.
  static Future<bool> hasConnectionPermissions() async {
    for (final perm in _connectionPermissions) {
      final status = await perm.status;
      if (!status.isGranted && !status.isLimited) {
        return false;
      }
    }
    return true;
  }

  /// Requests all permissions required before connecting.
  ///
  /// Shows the system permission dialogs one at a time. If a permission
  /// is permanently denied, opens the app settings so the user can
  /// enable it manually.
  ///
  /// Returns a [PermissionResult] summarizing the outcome.
  static Future<PermissionResult> requestConnectionPermissions() async {
    final permissions = _connectionPermissions;
    if (permissions.isEmpty) {
      return const PermissionResult(
        allGranted: true,
        statuses: {},
        permanentlyDenied: [],
      );
    }

    final statuses = <Permission, PermissionStatus>{};
    final permanentlyDenied = <Permission>[];

    for (final perm in permissions) {
      final status = await perm.request();
      statuses[perm] = status;

      if (status.isPermanentlyDenied) {
        permanentlyDenied.add(perm);
      }
    }

    // If any permission was permanently denied, open settings
    // so the user can fix it, then re-check after returning.
    if (permanentlyDenied.isNotEmpty) {
      await openAppSettings();
      // Re-check after returning from settings
      for (final perm in permanentlyDenied) {
        final newStatus = await perm.status;
        statuses[perm] = newStatus;
      }
      permanentlyDenied.clear();
      for (final entry in statuses.entries) {
        if (entry.value.isPermanentlyDenied) {
          permanentlyDenied.add(entry.key);
        }
      }
    }

    final allGranted = statuses.values.every(
      (s) => s.isGranted || s.isLimited,
    );

    return PermissionResult(
      allGranted: allGranted,
      statuses: statuses,
      permanentlyDenied: permanentlyDenied,
    );
  }

  /// Requests storage permissions for SFTP file operations.
  static Future<PermissionResult> requestStoragePermissions() async {
    final permissions = _storagePermissions;
    if (permissions.isEmpty) {
      return const PermissionResult(
        allGranted: true,
        statuses: {},
        permanentlyDenied: [],
      );
    }

    final statuses = <Permission, PermissionStatus>{};
    final permanentlyDenied = <Permission>[];

    for (final perm in permissions) {
      final status = await perm.request();
      statuses[perm] = status;
      if (status.isPermanentlyDenied) {
        permanentlyDenied.add(perm);
      }
    }

    final allGranted = statuses.values.every(
      (s) => s.isGranted || s.isLimited,
    );

    return PermissionResult(
      allGranted: allGranted,
      statuses: statuses,
      permanentlyDenied: permanentlyDenied,
    );
  }

  /// Returns a user-facing description for the given permission.
  static String describe(Permission perm) {
    if (perm == Permission.notification) {
      return 'Show notifications for active sessions';
    }
    if (perm == Permission.storage) {
      return 'Access storage for file transfers';
    }
    return perm.toString();
  }
}
