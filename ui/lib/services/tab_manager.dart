/// Terminal tab manager for multi-session support.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';
import '../models/host_profile.dart';
import '../models/terminal_tab.dart';
import '../services/session_service.dart';

/// Manages multiple terminal tabs.
class TabManager extends ChangeNotifier {
  final List<TerminalTab> _tabs = [];
  int _activeIndex = 0;

  List<TerminalTab> get tabs => List.unmodifiable(_tabs);
  int get activeIndex => _activeIndex;
  TerminalTab? get activeTab =>
      _tabs.isNotEmpty ? _tabs[_activeIndex] : null;
  int get length => _tabs.length;
  bool get isEmpty => _tabs.isEmpty;
  bool get isNotEmpty => _tabs.isNotEmpty;

  /// Creates a new tab with an SSH session to the given profile.
  Future<TerminalTab> createTab({
    required HostProfile profile,
    required SessionService sessionService,
  }) async {
    final sessionId = await sessionService.connect(profile);
    if (sessionId <= 0) {
      throw Exception('Connection failed');
    }

    final authResult = await sessionService.authenticate(sessionId, profile);
    if (authResult != 0) {
      await sessionService.disconnect(sessionId);
      throw Exception('Authentication failed');
    }

    return _createTerminalTab(
      sessionId: sessionId,
      profile: profile,
      sessionService: sessionService,
    );
  }

  /// Creates a new tab using an already-authenticated session.
  Future<TerminalTab> createTabWithExistingSession({
    required int sessionId,
    required HostProfile profile,
    required SessionService sessionService,
  }) async {
    return _createTerminalTab(
      sessionId: sessionId,
      profile: profile,
      sessionService: sessionService,
    );
  }

  Future<TerminalTab> _createTerminalTab({
    required int sessionId,
    required HostProfile profile,
    required SessionService sessionService,
  }) async {
    final tab = TerminalTab(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: profile.name,
      sessionId: sessionId,
      profile: profile,
      terminal: Terminal(maxLines: 10000),
      controller: TerminalController(),
    );

    tab.terminal.onOutput = (data) {
      final bytes = Uint8List.fromList(utf8.encode(data));
      sessionService.write(sessionId, bytes);
    };

    tab.terminal.onResize = (width, height, _, __) {
      sessionService.resize(sessionId, width, height);
    };

    tab.dataSubscription = sessionService.terminalData
        .where((e) => e.sessionId == sessionId)
        .listen((event) {
      final text = utf8.decode(event.data, allowMalformed: true);
      tab.terminal.write(text);
    });

    _tabs.add(tab);
    _activeIndex = _tabs.length - 1;
    notifyListeners();
    return tab;
  }

  /// Switches to the tab at [index].
  void switchTo(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _activeIndex = index;
    notifyListeners();
  }

  /// Closes the tab at [index] and disconnects its session.
  Future<void> closeTab(int index, SessionService sessionService) async {
    if (index < 0 || index >= _tabs.length) return;

    final tab = _tabs[index];
    tab.dispose();
    await sessionService.disconnect(tab.sessionId);
    _tabs.removeAt(index);

    if (_tabs.isEmpty) {
      _activeIndex = 0;
    } else if (_activeIndex >= _tabs.length) {
      _activeIndex = _tabs.length - 1;
    }
    notifyListeners();
  }

  /// Closes all tabs and disconnects all sessions.
  Future<void> closeAll(SessionService sessionService) async {
    for (final tab in _tabs) {
      tab.dispose();
      await sessionService.disconnect(tab.sessionId);
    }
    _tabs.clear();
    _activeIndex = 0;
    notifyListeners();
  }
}
