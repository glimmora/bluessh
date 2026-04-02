/// Multi-tab terminal screen with a tab bar at the top.
library;

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import '../models/host_profile.dart';
import '../models/terminal_tab.dart';
import '../services/session_service.dart';
import '../services/tab_manager.dart';

class MultiTerminalScreen extends ConsumerStatefulWidget {
  final HostProfile profile;
  final int? existingSessionId;

  const MultiTerminalScreen({
    super.key,
    required this.profile,
    this.existingSessionId,
  });

  @override
  ConsumerState<MultiTerminalScreen> createState() =>
      _MultiTerminalScreenState();
}

class _MultiTerminalScreenState extends ConsumerState<MultiTerminalScreen> {
  late final TabManager _tabManager;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _tabManager = TabManager();
    _openInitialTab();
  }

  Future<void> _openInitialTab() async {
    setState(() => _connecting = true);
    final sessionService = ref.read(sessionServiceProvider);
    try {
      if (widget.existingSessionId != null && widget.existingSessionId! > 0) {
        // Reuse the already-authenticated session from home_screen
        await _tabManager.createTabWithExistingSession(
          sessionId: widget.existingSessionId!,
          profile: widget.profile,
          sessionService: sessionService,
        );
      } else {
        await _tabManager.createTab(
          profile: widget.profile,
          sessionService: sessionService,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void dispose() {
    final sessionService = ref.read(sessionServiceProvider);
    _tabManager.closeAll(sessionService);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyT):
            const _NewTabIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyW):
            const _CloseTabIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.tab):
            const _NextTabIntent(),
        LogicalKeySet(LogicalKeyboardKey.control,
            LogicalKeyboardKey.shift, LogicalKeyboardKey.tab):
            const _PreviousTabIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NewTabIntent: CallbackAction(onInvoke: (_) => _addNewTab()),
          _CloseTabIntent:
              CallbackAction(onInvoke: (_) => _closeTab(_tabManager.activeIndex)),
          _NextTabIntent: CallbackAction(
            onInvoke: (_) => _tabManager.switchTo(
              (_tabManager.activeIndex + 1) % (_tabManager.length),
            ),
          ),
          _PreviousTabIntent: CallbackAction(
            onInvoke: (_) => _tabManager.switchTo(
              (_tabManager.activeIndex - 1 + _tabManager.length) %
                  _tabManager.length,
            ),
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            title: _buildTabBar(),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New tab (Ctrl+T)',
                onPressed: _connecting ? null : _addNewTab,
              ),
            ],
          ),
          body: _connecting
              ? const Center(child: CircularProgressIndicator())
              : _buildTabContent(theme),
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return ListenableBuilder(
      listenable: _tabManager,
      builder: (context, _) {
        if (_tabManager.isEmpty) {
          return const Text('Terminal');
        }
        return SizedBox(
          height: 40,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _tabManager.length,
            itemBuilder: (ctx, i) {
              final tab = _tabManager.tabs[i];
              final isActive = i == _tabManager.activeIndex;
              return Padding(
                padding: const EdgeInsets.only(right: 4),
                child: InputChip(
                  label: Text(
                    tab.title,
                    style: TextStyle(
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  selected: isActive,
                  onSelected: (_) => _tabManager.switchTo(i),
                  onDeleted: () => _closeTab(i),
                  avatar: Icon(
                    Icons.terminal,
                    size: 16,
                    color: isActive ? Colors.green : Colors.grey,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTabContent(ThemeData theme) {
    return ListenableBuilder(
      listenable: _tabManager,
      builder: (context, _) {
        final tab = _tabManager.activeTab;
        if (tab == null) {
          return const Center(child: Text('No active sessions'));
        }

        return TerminalView(
          tab.terminal,
          controller: tab.controller,
          autofocus: true,
          backgroundOpacity: 0.95,
          theme: TerminalTheme(
            cursor: Colors.lightBlueAccent,
            selection: Colors.blue.withOpacity(0.3),
            foreground: Colors.white,
            background: const Color(0xFF1E1E2E),
            black: Colors.black,
            red: const Color(0xFFF38BA8),
            green: const Color(0xFFA6E3A1),
            yellow: const Color(0xFFF9E2AF),
            blue: const Color(0xFF89B4FA),
            magenta: const Color(0xFFF5C2E7),
            cyan: const Color(0xFF94E2D5),
            white: const Color(0xFFCDD6F4),
            brightBlack: const Color(0xFF6C7086),
            brightRed: const Color(0xFFF38BA8),
            brightGreen: const Color(0xFFA6E3A1),
            brightYellow: const Color(0xFFF9E2AF),
            brightBlue: const Color(0xFF89B4FA),
            brightMagenta: const Color(0xFFF5C2E7),
            brightCyan: const Color(0xFF94E2D5),
            brightWhite: Colors.white,
            searchHitBackground: Colors.yellow,
            searchHitBackgroundCurrent: Colors.orange,
            searchHitForeground: Colors.black,
          ),
        );
      },
    );
  }

  void _addNewTab() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    final sessionService = ref.read(sessionServiceProvider);
    try {
      await _tabManager.createTab(
        profile: widget.profile,
        sessionService: sessionService,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _closeTab(int index) async {
    final sessionService = ref.read(sessionServiceProvider);
    await _tabManager.closeTab(index, sessionService);
  }
}

// Keyboard shortcut intents
class _NewTabIntent extends Intent {
  const _NewTabIntent();
}

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}

class _NextTabIntent extends Intent {
  const _NextTabIntent();
}

class _PreviousTabIntent extends Intent {
  const _PreviousTabIntent();
}
