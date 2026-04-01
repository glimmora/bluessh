/// Recording playback screen — browse and replay recorded sessions.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

class RecordingPlaybackScreen extends ConsumerStatefulWidget {
  const RecordingPlaybackScreen({super.key});

  @override
  ConsumerState<RecordingPlaybackScreen> createState() =>
      _RecordingPlaybackScreenState();
}

class _RecordingPlaybackScreenState
    extends ConsumerState<RecordingPlaybackScreen> {
  List<RecordingFile> _recordings = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRecordings();
  }

  Future<void> _loadRecordings() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final recDir = Directory('${appDir.path}/recordings');

      if (!await recDir.exists()) {
        setState(() {
          _recordings = [];
          _isLoading = false;
        });
        return;
      }

      final files = await recDir
          .list()
          .where((f) => f.path.endsWith('.cast'))
          .cast<File>()
          .toList();

      final recordings = <RecordingFile>[];
      for (final file in files) {
        final stat = await file.stat();
        recordings.add(RecordingFile(
          name: file.path.split('/').last,
          path: file.path,
          size: stat.size,
          modified: stat.modified,
        ));
      }

      recordings.sort((a, b) => b.modified.compareTo(a.modified));

      if (!mounted) return;
      setState(() {
        _recordings = recordings;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _playRecording(RecordingFile recording) async {
    // Read the .cast file (asciinema v2 format)
    try {
      final content = await File(recording.path).readAsString();
      final lines = content.split('\n');

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (ctx) => _RecordingPlayerDialog(
          title: recording.name,
          lines: lines,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to read recording: $e')),
      );
    }
  }

  Future<void> _deleteRecording(RecordingFile recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Recording'),
        content: Text('Delete "${recording.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await File(recording.path).delete();
    _loadRecordings();
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRecordings,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _recordings.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.videocam_off, size: 64,
                          color: theme.colorScheme.outline),
                      const SizedBox(height: 16),
                      Text('No recordings yet',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        'Start a recording from the terminal screen',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _recordings.length,
                  itemBuilder: (ctx, i) {
                    final rec = _recordings[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.play_circle_outline,
                              color: Colors.red, size: 20),
                        ),
                        title: Text(rec.name),
                        subtitle: Text(
                          '${_formatSize(rec.size)} \u2022 '
                          '${rec.modified.toString().substring(0, 19)}',
                        ),
                        onTap: () => _playRecording(rec),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red, size: 20),
                          onPressed: () => _deleteRecording(rec),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ─────────────────────────────────────────────────
//  Recording Player Dialog
// ─────────────────────────────────────────────────

class _RecordingPlayerDialog extends StatefulWidget {
  final String title;
  final List<String> lines;

  const _RecordingPlayerDialog({
    required this.title,
    required this.lines,
  });

  @override
  State<_RecordingPlayerDialog> createState() => _RecordingPlayerDialogState();
}

class _RecordingPlayerDialogState extends State<_RecordingPlayerDialog> {
  final List<String> _output = [];
  int _currentLine = 0;
  bool _playing = false;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _parseHeader();
  }

  void _parseHeader() {
    // Asciinema v2 format: first line is JSON header
    if (widget.lines.isNotEmpty) {
      try {
        jsonDecode(widget.lines.first);
      } catch (_) {}
    }
  }

  void _play() {
    if (_playing) return;
    setState(() {
      _playing = true;
      _paused = false;
    });
    _playNext();
  }

  void _pause() {
    setState(() => _paused = true);
  }

  void _resume() {
    setState(() => _paused = false);
    _playNext();
  }

  void _stop() {
    setState(() {
      _playing = false;
      _paused = false;
    });
  }

  void _playNext() {
    if (!_playing || _paused || _currentLine >= widget.lines.length) {
      return;
    }

    final line = widget.lines[_currentLine];
    _currentLine++;

    try {
      final parts = jsonDecode(line);
      if (parts is List && parts.length >= 3 && parts[0] is num) {
        // [timestamp, "o", "data"]
        final data = parts[2] as String;
        setState(() {
          _output.add(data);
        });
      }
    } catch (_) {
      // Not a data line, skip
    }

    // Schedule next line with delay
    Future.delayed(const Duration(milliseconds: 50), _playNext);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 600,
        height: 500,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.title,
                      style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Player controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: _playing && !_paused ? null : () {
                    if (_paused) {
                      _resume();
                    } else {
                      _play();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.pause),
                  onPressed: _playing && !_paused ? _pause : null,
                ),
                IconButton(
                  icon: const Icon(Icons.stop),
                  onPressed: _playing ? _stop : null,
                ),
                const SizedBox(width: 16),
                Text(
                  'Line $_currentLine / ${widget.lines.length}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Terminal output
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E2E),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                child: ListView.builder(
                  itemCount: _output.length,
                  itemBuilder: (ctx, i) => SelectableText(
                    _output[i],
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
//  Recording File Model
// ─────────────────────────────────────────────────

class RecordingFile {
  final String name;
  final String path;
  final int size;
  final DateTime modified;

  const RecordingFile({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
  });
}
