/// SSH terminal screen — xterm-based terminal emulator.
///
/// Connects to the remote session via [SessionService], renders
/// terminal output with xterm.dart, and handles keyboard input,
/// clipboard sync, recording, and compression adjustment.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import '../models/host_profile.dart';
import '../services/session_service.dart';
import 'file_manager_screen.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  final int sessionId;
  final HostProfile profile;

  const TerminalScreen({
    super.key,
    required this.sessionId,
    required this.profile,
  });

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  late final Terminal _terminal;
  late final TerminalController _controller;
  StreamSubscription<TerminalDataEvent>? _dataSub;
  StreamSubscription<ClipboardEvent>? _clipboardSub;
  bool _isRecording = false;
  int _bytesSent = 0;
  int _bytesReceived = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _terminal = Terminal(maxLines: 10000);
    _controller = TerminalController();

    _terminal.onOutput = (data) {
      _sendInput(data);
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      ref.read(sessionServiceProvider).resize(
            widget.sessionId,
            width,
            height,
          );
    };

    _listenForData();
    _listenForClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dataSub?.cancel();
    _clipboardSub?.cancel();
    if (_isRecording) {
      ref.read(sessionServiceProvider).stopRecording(widget.sessionId);
    }
    ref.read(sessionServiceProvider).disconnect(widget.sessionId);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _listenForData() {
    final sessionService = ref.read(sessionServiceProvider);
    _dataSub = sessionService.terminalData
        .where((e) => e.sessionId == widget.sessionId)
        .listen((event) {
      final text = utf8.decode(event.data, allowMalformed: true);
      _terminal.write(text);
      setState(() {
        _bytesReceived += event.data.length;
      });
    });

    sessionService.events
        .where((e) => e.sessionId == widget.sessionId)
        .listen((event) {
      if (event.type == 'disconnected') {
        _terminal.write('\r\n\x1b[31m--- Connection lost ---\x1b[0m\r\n');
      } else if (event.type == 'reconnected') {
        _terminal.write(
            '\r\n\x1b[32m--- Reconnected (attempt ${event.data['attempts']}) ---\x1b[0m\r\n');
      } else if (event.type == 'keepalive_failed') {
        _terminal.write('\r\n\x1b[33m--- Connection unstable ---\x1b[0m\r\n');
      }
    });
  }

  void _listenForClipboard() {
    final sessionService = ref.read(sessionServiceProvider);
    _clipboardSub = sessionService.clipboardEvents
        .where((e) => e.sessionId == widget.sessionId)
        .listen((event) {
      final text = utf8.decode(event.data, allowMalformed: true);
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Remote clipboard copied'),
          duration: Duration(seconds: 1),
        ),
      );
    });
  }

  void _sendInput(String data) {
    final bytes = Uint8List.fromList(utf8.encode(data));
    ref.read(sessionServiceProvider).write(widget.sessionId, bytes);
    setState(() {
      _bytesSent += bytes.length;
    });
  }

  Future<void> _toggleRecording() async {
    final sessionService = ref.read(sessionServiceProvider);
    if (_isRecording) {
      await sessionService.stopRecording(widget.sessionId);
      setState(() => _isRecording = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording stopped')),
        );
      }
    } else {
      final appDir = await sessionService.getAppDir();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '$appDir/recordings/${widget.sessionId}_$timestamp.cast';
      final result = await sessionService.startRecording(widget.sessionId, path);
      if (result == 0) {
        setState(() => _isRecording = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recording started')),
          );
        }
      }
    }
  }

  Future<void> _sendClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      _sendInput(data!.text!);
    }
  }

  void _openFileManager() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileManagerScreen(
          sessionId: widget.sessionId,
          profile: widget.profile,
        ),
      ),
    );
  }

  void _showCompressionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Compression Level'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final level in [0, 1, 2, 3])
              RadioListTile<int>(
                title: Text(_compressionLabel(level)),
                subtitle: Text(_compressionDesc(level)),
                value: level,
                groupValue: widget.profile.compressionLevel,
                onChanged: (v) {
                  ref.read(sessionServiceProvider).setCompression(
                        widget.sessionId,
                        v!,
                      );
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  String _compressionLabel(int level) {
    switch (level) {
      case 0: return 'None';
      case 1: return 'Low (zstd L1-3)';
      case 2: return 'Medium (zstd L4-6)';
      case 3: return 'High (zstd L7-19)';
      default: return 'Unknown';
    }
  }

  String _compressionDesc(int level) {
    switch (level) {
      case 0: return 'Best for local networks (>50 Mbps)';
      case 1: return 'Balanced speed and size (1-50 Mbps)';
      case 2: return 'Good compression (0.5-1 Mbps)';
      case 3: return 'Maximum compression (<0.5 Mbps)';
      default: return '';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name),
        actions: [
          Chip(
            avatar: Icon(
              _isRecording ? Icons.fiber_manual_record : Icons.link,
              size: 16,
              color: _isRecording ? Colors.red : Colors.green,
            ),
            label: Text(
              '${_formatBytes(_bytesReceived)} rx',
              style: theme.textTheme.labelSmall,
            ),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.paste),
            tooltip: 'Paste from clipboard',
            onPressed: _sendClipboard,
          ),
          IconButton(
            icon: Icon(
              _isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
              color: _isRecording ? Colors.red : null,
            ),
            tooltip: _isRecording ? 'Stop recording' : 'Start recording',
            onPressed: _toggleRecording,
          ),
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: 'File Manager',
            onPressed: _openFileManager,
          ),
          IconButton(
            icon: const Icon(Icons.compress),
            tooltip: 'Adjust compression',
            onPressed: _showCompressionDialog,
          ),
        ],
      ),
      body: TerminalView(
        _terminal,
        controller: _controller,
        autofocus: true,
        backgroundOpacity: 0.95,
        theme: TerminalTheme(
          cursor: Colors.lightBlueAccent,
          selection: Colors.blue.withValues(alpha: 0.3),
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
      ),
    );
  }
}
