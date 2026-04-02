/// Terminal tab model for multi-tab support.
library;

import 'dart:async';
import 'package:xterm/xterm.dart';
import '../models/host_profile.dart';

/// A single terminal tab with its associated session and terminal state.
class TerminalTab {
  final String id;
  String title;
  final int sessionId;
  final HostProfile profile;
  final Terminal terminal;
  final TerminalController controller;
  DateTime createdAt;

  /// Stream subscription for terminal data — must be cancelled on tab close.
  StreamSubscription? dataSubscription;

  TerminalTab({
    required this.id,
    required this.title,
    required this.sessionId,
    required this.profile,
    required this.terminal,
    required this.controller,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Cancels the data subscription to prevent memory leaks.
  void dispose() {
    dataSubscription?.cancel();
    dataSubscription = null;
  }
}
