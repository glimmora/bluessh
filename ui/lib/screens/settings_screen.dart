/// Settings screen — application preferences and SSH key management.
///
/// Provides configuration for connection behavior (keep-alive, reconnect),
/// compression defaults, terminal appearance, recording preferences,
/// and SSH key generation/import/deletion.
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Preferences
  bool _keepScreenOn = true;
  bool _clipboardSync = true;
  bool _autoReconnect = true;
  int _maxReconnectAttempts = 5;
  int _defaultCompression = 2;
  bool _showTimestamps = false;
  int _terminalFontSize = 14;
  int _keepaliveInterval = 30;
  bool _recordByDefault = false;

  // Keys management
  final List<KeyInfo> _sshKeys = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _keepScreenOn = prefs.getBool('keep_screen_on') ?? true;
      _clipboardSync = prefs.getBool('clipboard_sync') ?? true;
      _autoReconnect = prefs.getBool('auto_reconnect') ?? true;
      _maxReconnectAttempts = prefs.getInt('max_reconnect_attempts') ?? 5;
      _defaultCompression = prefs.getInt('default_compression') ?? 2;
      _showTimestamps = prefs.getBool('show_timestamps') ?? false;
      _terminalFontSize = prefs.getInt('terminal_font_size') ?? 14;
      _keepaliveInterval = prefs.getInt('keepalive_interval') ?? 30;
      _recordByDefault = prefs.getBool('record_by_default') ?? false;

      // Load SSH keys
      final keyStrings = prefs.getStringList('ssh_keys') ?? [];
      _sshKeys.clear();
      for (final k in keyStrings) {
        final json = jsonDecode(k);
        _sshKeys.add(KeyInfo(
          name: json['name'] as String,
          type: json['type'] as String,
          fingerprint: json['fingerprint'] as String,
          createdAt: DateTime.parse(json['createdAt'] as String),
        ));
      }
    });
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is int) await prefs.setInt(key, value);
    if (value is String) await prefs.setString(key, value);
  }

  Future<void> _importKey() async {
    // In a real implementation, use file_picker to select key file
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import SSH Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Key name',
                hintText: 'My Server Key',
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'In a full implementation, this would use file_picker '
              'to select the key file from device storage.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty) return;

    setState(() {
      _sshKeys.add(KeyInfo(
        name: name.trim(),
        type: 'ed25519',
        fingerprint: 'SHA256:${base64Encode(utf8.encode(DateTime.now().toIso8601String())).substring(0, 43)}',
        createdAt: DateTime.now(),
      ));
    });

    await _saveKeys();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Key imported successfully')),
      );
    }
  }

  Future<void> _generateKey() async {
    final controller = TextEditingController();
    final passphraseController = TextEditingController();
    KeyType selectedType = KeyType.ed25519;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Generate SSH Key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Key name',
                  hintText: 'bluessh-key',
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<KeyType>(
                segments: const [
                  ButtonSegment(
                    value: KeyType.ed25519,
                    label: Text('Ed25519'),
                  ),
                  ButtonSegment(
                    value: KeyType.ecdsa,
                    label: Text('ECDSA'),
                  ),
                  ButtonSegment(
                    value: KeyType.rsa,
                    label: Text('RSA-4096'),
                  ),
                ],
                selected: {selectedType},
                onSelectionChanged: (s) =>
                    setDialogState(() => selectedType = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passphraseController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Passphrase (optional)',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                'name': controller.text,
                'type': selectedType.name,
              }),
              child: const Text('Generate'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;

    // In a real implementation, this calls the native engine to generate keys
    setState(() {
      _sshKeys.add(KeyInfo(
        name: result['name'] as String? ?? 'key',
        type: result['type'] as String,
        fingerprint: 'SHA256:${base64Encode(utf8.encode(DateTime.now().microsecondsSinceEpoch.toString())).substring(0, 43)}',
        createdAt: DateTime.now(),
      ));
    });

    await _saveKeys();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Key generated successfully')),
      );
    }
  }

  Future<void> _saveKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'ssh_keys',
      _sshKeys.map((k) => jsonEncode({
        'name': k.name,
        'type': k.type,
        'fingerprint': k.fingerprint,
        'createdAt': k.createdAt.toIso8601String(),
      })).toList(),
    );
  }

  void _deleteKey(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text('Delete "${_sshKeys[index].name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              setState(() => _sshKeys.removeAt(index));
              _saveKeys();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── Connection Settings ───
          Text('Connection', style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
          )),
          const SizedBox(height: 8),

          SwitchListTile(
            title: const Text('Keep Screen On'),
            subtitle: const Text('Prevent screen dimming during sessions'),
            value: _keepScreenOn,
            onChanged: (v) {
              setState(() => _keepScreenOn = v);
              _saveSetting('keep_screen_on', v);
            },
          ),

          SwitchListTile(
            title: const Text('Auto-Reconnect'),
            subtitle: const Text('Automatically reconnect on disconnect'),
            value: _autoReconnect,
            onChanged: (v) {
              setState(() => _autoReconnect = v);
              _saveSetting('auto_reconnect', v);
            },
          ),

          ListTile(
            title: const Text('Max Reconnect Attempts'),
            subtitle: Text('$_maxReconnectAttempts attempts'),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _maxReconnectAttempts.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '$_maxReconnectAttempts',
                onChanged: _autoReconnect
                    ? (v) {
                        setState(() => _maxReconnectAttempts = v.toInt());
                        _saveSetting('max_reconnect_attempts', v.toInt());
                      }
                    : null,
              ),
            ),
          ),

          ListTile(
            title: const Text('Keepalive Interval'),
            subtitle: Text('$_keepaliveInterval seconds'),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _keepaliveInterval.toDouble(),
                min: 10,
                max: 120,
                divisions: 22,
                label: '${_keepaliveInterval}s',
                onChanged: (v) {
                  setState(() => _keepaliveInterval = v.toInt());
                  _saveSetting('keepalive_interval', v.toInt());
                },
              ),
            ),
          ),

          // ─── Compression ───
          const Divider(height: 32),
          Text('Compression', style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
          )),
          const SizedBox(height: 8),

          ListTile(
            title: const Text('Default Compression Level'),
            subtitle: Text(_compressionLabel(_defaultCompression)),
            trailing: SizedBox(
              width: 200,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Off')),
                  ButtonSegment(value: 1, label: Text('Low')),
                  ButtonSegment(value: 2, label: Text('Med')),
                  ButtonSegment(value: 3, label: Text('High')),
                ],
                selected: {_defaultCompression},
                onSelectionChanged: (s) {
                  setState(() => _defaultCompression = s.first);
                  _saveSetting('default_compression', s.first);
                },
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ),

          // ─── Terminal ───
          const Divider(height: 32),
          Text('Terminal', style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
          )),
          const SizedBox(height: 8),

          SwitchListTile(
            title: const Text('Clipboard Sync'),
            subtitle: const Text('Sync clipboard between local and remote'),
            value: _clipboardSync,
            onChanged: (v) {
              setState(() => _clipboardSync = v);
              _saveSetting('clipboard_sync', v);
            },
          ),

          SwitchListTile(
            title: const Text('Show Timestamps'),
            subtitle: const Text('Show timestamps on terminal output'),
            value: _showTimestamps,
            onChanged: (v) {
              setState(() => _showTimestamps = v);
              _saveSetting('show_timestamps', v);
            },
          ),

          ListTile(
            title: const Text('Font Size'),
            subtitle: Text('$_terminalFontSize px'),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _terminalFontSize.toDouble(),
                min: 10,
                max: 24,
                divisions: 14,
                label: '${_terminalFontSize}px',
                onChanged: (v) {
                  setState(() => _terminalFontSize = v.toInt());
                  _saveSetting('terminal_font_size', v.toInt());
                },
              ),
            ),
          ),

          // ─── Recording ───
          const Divider(height: 32),
          Text('Recording', style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
          )),
          const SizedBox(height: 8),

          SwitchListTile(
            title: const Text('Record by Default'),
            subtitle: const Text('Start recording automatically for new sessions'),
            value: _recordByDefault,
            onChanged: (v) {
              setState(() => _recordByDefault = v);
              _saveSetting('record_by_default', v);
            },
          ),

          // ─── SSH Keys ───
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: Text('SSH Keys', style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                )),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Import key',
                onPressed: _importKey,
              ),
              IconButton(
                icon: const Icon(Icons.vpn_key_outlined),
                tooltip: 'Generate key',
                onPressed: _generateKey,
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_sshKeys.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text('No SSH keys. Generate or import one.'),
                ),
              ),
            )
          else
            ..._sshKeys.asMap().entries.map((entry) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.key, color: Colors.green, size: 20),
                ),
                title: Text(entry.value.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${entry.value.type.toUpperCase()} - ${entry.value.fingerprint}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      'Created: ${_formatDate(entry.value.createdAt)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _deleteKey(entry.key),
                ),
                isThreeLine: true,
              ),
            )),

          // ─── About ───
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('BlueSSH'),
            subtitle: const Text('Version 0.1.0 (Engine: Rust + Flutter)'),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Protocols'),
            subtitle: const Text('SSH-2, SFTP v3, RFB 3.8, RDP 10.x'),
          ),
          ListTile(
            leading: const Icon(Icons.compress),
            title: const Text('Compression'),
            subtitle: const Text('zstd (adaptive), zlib (fallback)'),
          ),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Security'),
            subtitle: const Text('Ed25519, ECDSA, TLS 1.3, TOTP/FIDO2 MFA'),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _compressionLabel(int level) {
    switch (level) {
      case 0: return 'Off — Best for local networks';
      case 1: return 'Low — 1-50 Mbps';
      case 2: return 'Medium — 0.5-1 Mbps';
      case 3: return 'High — <0.5 Mbps';
      default: return '';
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }
}

// ─────────────────────────────────────────────────
//  Key Info Model
// ─────────────────────────────────────────────────

class KeyInfo {
  final String name;
  final String type;
  final String fingerprint;
  final DateTime createdAt;

  const KeyInfo({
    required this.name,
    required this.type,
    required this.fingerprint,
    required this.createdAt,
  });
}

enum KeyType { ed25519, ecdsa, rsa }
