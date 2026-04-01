/// Home screen — connection manager and host list.
///
/// Displays saved host profiles, active sessions, and provides
/// navigation to terminal, file manager, and remote desktop screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host_profile.dart';
import '../models/session_state.dart';
import '../services/session_service.dart';
import 'terminal_screen.dart';
import 'file_manager_screen.dart';
import 'remote_desktop_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  List<HostProfile> _profiles = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('host_profiles') ?? [];
    setState(() {
      _profiles = raw.map((e) => HostProfile.fromJsonString(e)).toList()
        ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
      _isLoading = false;
    });
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'host_profiles',
      _profiles.map((e) => e.toJsonString()).toList(),
    );
  }

  Future<void> _connectToHost(HostProfile profile) async {
    final sessionService = ref.read(sessionServiceProvider);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Connecting...'),
          ],
        ),
      ),
    );

    final sessionId = await sessionService.connect(profile);

    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss connecting dialog

    if (sessionId <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection failed')),
      );
      return;
    }

    // Authenticate
    final authResult = await sessionService.authenticate(sessionId, profile);

    if (authResult == 0) {
      // Update profile usage
      final idx = _profiles.indexWhere((p) => p.id == profile.id);
      if (idx >= 0) {
        _profiles[idx] = profile.copyWith(
          lastUsed: DateTime.now(),
          connectionCount: profile.connectionCount + 1,
        );
        _saveProfiles();
      }

      // Navigate to appropriate screen
      if (!mounted) return;
      Widget screen;
      switch (profile.protocol) {
        case ProtocolType.ssh:
        case ProtocolType.sftp:
          screen = TerminalScreen(
            sessionId: sessionId,
            profile: profile,
          );
          break;
        case ProtocolType.vnc:
        case ProtocolType.rdp:
          screen = RemoteDesktopScreen(
            sessionId: sessionId,
            profile: profile,
          );
          break;
      }

      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => screen),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication failed')),
      );
      await sessionService.disconnect(sessionId);
    }
  }

  void _showAddHostDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _AddHostSheet(
        onAdd: (profile) {
          setState(() {
            _profiles.insert(0, profile);
          });
          _saveProfiles();
        },
      ),
    );
  }

  void _showEditHostDialog(HostProfile profile) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _AddHostSheet(
        existingProfile: profile,
        onAdd: (updated) {
          setState(() {
            final idx = _profiles.indexWhere((p) => p.id == profile.id);
            if (idx >= 0) _profiles[idx] = updated;
          });
          _saveProfiles();
        },
      ),
    );
  }

  void _deleteProfile(HostProfile profile) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Host'),
        content: Text('Remove "${profile.name}" from saved hosts?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _profiles.removeWhere((p) => p.id == profile.id);
              });
              _saveProfiles();
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

  List<HostProfile> get _filteredProfiles {
    if (_searchQuery.isEmpty) return _profiles;
    final q = _searchQuery.toLowerCase();
    return _profiles.where((p) =>
        p.name.toLowerCase().contains(q) ||
        p.host.toLowerCase().contains(q) ||
        p.username.toLowerCase().contains(q) ||
        p.protocol.label.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeSessions = ref.watch(activeSessionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2196F3), Color(0xFF1565C0)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.terminal, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Text('BlueSSH'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search hosts...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),

          // Active sessions
          if (activeSessions.isNotEmpty)
            Container(
              height: 80,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Active Sessions', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: activeSessions.length,
                      itemBuilder: (ctx, i) {
                        final entry = activeSessions.entries.elementAt(i);
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Chip(
                            avatar: Icon(
                              entry.value.status == SessionStatus.connected
                                  ? Icons.check_circle
                                  : Icons.sync,
                              size: 18,
                              color: entry.value.status == SessionStatus.connected
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                            label: Text('Session ${entry.key}'),
                            onDeleted: () {
                              ref
                                  .read(sessionServiceProvider)
                                  .disconnect(entry.key);
                              ref
                                  .read(activeSessionsProvider.notifier)
                                  .removeSession(entry.key);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

          // Host list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredProfiles.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  _searchQuery.isNotEmpty
                                      ? Icons.search_off
                                      : Icons.cloud_outlined,
                                  size: 48,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                _searchQuery.isNotEmpty
                                    ? 'No matching hosts'
                                    : 'Welcome to BlueSSH',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _searchQuery.isNotEmpty
                                    ? 'Try a different search term'
                                    : 'Add a host to get started with\nSSH, SFTP, VNC, or RDP connections',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.outline,
                                  height: 1.5,
                                ),
                              ),
                              if (_searchQuery.isEmpty) ...[
                                const SizedBox(height: 32),
                                FilledButton.icon(
                                  onPressed: _showAddHostDialog,
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add First Host'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _filteredProfiles.length,
                        itemBuilder: (ctx, i) {
                          final profile = _filteredProfiles[i];
                          return _HostCard(
                            profile: profile,
                            isConnected: activeSessions.values.any(
                              (s) => s.status == SessionStatus.connected,
                            ),
                            onConnect: () => _connectToHost(profile),
                            onEdit: () => _showEditHostDialog(profile),
                            onDelete: () => _deleteProfile(profile),
                            onFileManager: () => _openFileManager(profile),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddHostDialog,
        icon: const Icon(Icons.add),
        label: const Text('New Host'),
      ),
    );
  }

  void _openFileManager(HostProfile profile) async {
    final sessionService = ref.read(sessionServiceProvider);
    final sshProfile = profile.copyWith(protocol: ProtocolType.ssh);
    final sessionId = await sessionService.connect(sshProfile);

    if (sessionId <= 0 || !mounted) return;

    final authResult = await sessionService.authenticate(sessionId, sshProfile);
    if (authResult != 0 || !mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileManagerScreen(
          sessionId: sessionId,
          profile: sshProfile,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
//  Host Card Widget
// ─────────────────────────────────────────────────

class _HostCard extends StatelessWidget {
  final HostProfile profile;
  final bool isConnected;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onFileManager;

  const _HostCard({
    required this.profile,
    required this.isConnected,
    required this.onConnect,
    required this.onEdit,
    required this.onDelete,
    required this.onFileManager,
  });

  IconData _protocolIcon(ProtocolType p) {
    switch (p) {
      case ProtocolType.ssh:
        return Icons.terminal;
      case ProtocolType.sftp:
        return Icons.folder_outlined;
      case ProtocolType.vnc:
        return Icons.desktop_windows;
      case ProtocolType.rdp:
        return Icons.monitor;
    }
  }

  Color _protocolColor(ProtocolType p) {
    switch (p) {
      case ProtocolType.ssh:
        return Colors.green;
      case ProtocolType.sftp:
        return Colors.orange;
      case ProtocolType.vnc:
        return Colors.blue;
      case ProtocolType.rdp:
        return Colors.purple;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onConnect,
        child: Row(
          children: [
            // Left accent bar
            Container(
              width: 5,
              height: 80,
              color: _protocolColor(profile.protocol),
            ),
            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    // Protocol icon
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _protocolColor(profile.protocol).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        _protocolIcon(profile.protocol),
                        color: _protocolColor(profile.protocol),
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),

                    const SizedBox(width: 14),

                    // Host info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.name,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${profile.username.isNotEmpty ? "${profile.username}@" : ""}'
                            '${profile.host}:${profile.port}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _protocolColor(profile.protocol)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  profile.protocol.label,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: _protocolColor(profile.protocol),
                                  ),
                                ),
                              ),
                              if (profile.compressionLevel > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.teal.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'zstd L${profile.compressionLevel}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.teal,
                                    ),
                                  ),
                                ),
                              if (profile.keyPath != null)
                                Icon(Icons.key, size: 14, color: theme.colorScheme.outline),
                              if (profile.useMfa)
                                Icon(Icons.shield, size: 14, color: Colors.amber),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Actions
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        switch (v) {
                          case 'connect':
                            onConnect();
                            break;
                          case 'files':
                            onFileManager();
                            break;
                          case 'edit':
                            onEdit();
                            break;
                          case 'delete':
                            onDelete();
                            break;
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'connect',
                          child: ListTile(
                            leading: Icon(Icons.play_arrow),
                            title: Text('Connect'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        if (profile.protocol == ProtocolType.ssh)
                          const PopupMenuItem(
                            value: 'files',
                            child: ListTile(
                              leading: Icon(Icons.folder_outlined),
                              title: Text('File Manager'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'edit',
                          child: ListTile(
                            leading: Icon(Icons.edit_outlined),
                            title: Text('Edit'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline, color: Colors.red),
                            title: Text('Delete', style: TextStyle(color: Colors.red)),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                  ],
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
//  Add/Edit Host Bottom Sheet
// ─────────────────────────────────────────────────

class _AddHostSheet extends StatefulWidget {
  final HostProfile? existingProfile;
  final ValueChanged<HostProfile> onAdd;

  const _AddHostSheet({this.existingProfile, required this.onAdd});

  @override
  State<_AddHostSheet> createState() => _AddHostSheetState();
}

class _AddHostSheetState extends State<_AddHostSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _keyPathController;
  ProtocolType _protocol = ProtocolType.ssh;
  int _compressionLevel = 2;
  bool _recordSession = false;
  bool _useMfa = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final p = widget.existingProfile;
    _nameController = TextEditingController(text: p?.name ?? '');
    _hostController = TextEditingController(text: p?.host ?? '');
    _portController = TextEditingController(text: (p?.port ?? 22).toString());
    _usernameController = TextEditingController(text: p?.username ?? '');
    _passwordController = TextEditingController(text: p?.password ?? '');
    _keyPathController = TextEditingController(text: p?.keyPath ?? '');
    if (p != null) {
      _protocol = p.protocol;
      _compressionLevel = p.compressionLevel;
      _recordSession = p.recordSession;
      _useMfa = p.useMfa;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _keyPathController.dispose();
    super.dispose();
  }

  int _defaultPort(ProtocolType p) {
    switch (p) {
      case ProtocolType.ssh:
      case ProtocolType.sftp:
        return 22;
      case ProtocolType.vnc:
        return 5900;
      case ProtocolType.rdp:
        return 3389;
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final profile = HostProfile(
      id: widget.existingProfile?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text) ?? _defaultPort(_protocol),
      protocol: _protocol,
      username: _usernameController.text.trim(),
      password: _passwordController.text.isNotEmpty
          ? _passwordController.text
          : null,
      keyPath: _keyPathController.text.isNotEmpty
          ? _keyPathController.text
          : null,
      compressionLevel: _compressionLevel,
      recordSession: _recordSession,
      useMfa: _useMfa,
      lastUsed: widget.existingProfile?.lastUsed ?? DateTime.now(),
      connectionCount: widget.existingProfile?.connectionCount ?? 0,
    );

    widget.onAdd(profile);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEdit = widget.existingProfile != null;

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isEdit ? 'Edit Host' : 'New Host',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),

              // Protocol selector
              SegmentedButton<ProtocolType>(
                segments: const [
                  ButtonSegment(value: ProtocolType.ssh, label: Text('SSH'), icon: Icon(Icons.terminal)),
                  ButtonSegment(value: ProtocolType.vnc, label: Text('VNC'), icon: Icon(Icons.desktop_windows)),
                  ButtonSegment(value: ProtocolType.rdp, label: Text('RDP'), icon: Icon(Icons.monitor)),
                ],
                selected: {_protocol},
                onSelectionChanged: (s) {
                  setState(() {
                    _protocol = s.first;
                    _portController.text = _defaultPort(_protocol).toString();
                  });
                },
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'My Server',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name is required' : null,
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _hostController,
                      decoration: const InputDecoration(
                        labelText: 'Host',
                        hintText: '192.168.1.100',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Host is required' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _portController,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final p = int.tryParse(v ?? '');
                        if (p == null || p < 1 || p > 65535) return 'Invalid';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (_protocol != ProtocolType.vnc)
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
              if (_protocol != ProtocolType.vnc) const SizedBox(height: 12),

              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: _protocol == ProtocolType.vnc ? 'VNC Password' : 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              if (_protocol == ProtocolType.ssh) ...[
                TextFormField(
                  controller: _keyPathController,
                  decoration: const InputDecoration(
                    labelText: 'SSH Key Path (optional)',
                    hintText: '/path/to/id_ed25519',
                    prefixIcon: Icon(Icons.key),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Compression level
              Row(
                children: [
                  const Icon(Icons.compress, size: 20),
                  const SizedBox(width: 12),
                  Text('Compression', style: theme.textTheme.bodyMedium),
                  const Spacer(),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('Off')),
                      ButtonSegment(value: 1, label: Text('Low')),
                      ButtonSegment(value: 2, label: Text('Med')),
                      ButtonSegment(value: 3, label: Text('High')),
                    ],
                    selected: {_compressionLevel},
                    onSelectionChanged: (s) =>
                        setState(() => _compressionLevel = s.first),
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(
                        theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Options
              SwitchListTile(
                title: const Text('Record Session'),
                subtitle: const Text('Save terminal output to file'),
                value: _recordSession,
                onChanged: (v) => setState(() => _recordSession = v),
                contentPadding: EdgeInsets.zero,
              ),

              if (_protocol == ProtocolType.ssh)
                SwitchListTile(
                  title: const Text('MFA (TOTP)'),
                  subtitle: const Text('Use two-factor authentication'),
                  value: _useMfa,
                  onChanged: (v) => setState(() => _useMfa = v),
                  contentPadding: EdgeInsets.zero,
                ),

              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _save,
                icon: Icon(isEdit ? Icons.save : Icons.add),
                label: Text(isEdit ? 'Save Changes' : 'Add Host'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
