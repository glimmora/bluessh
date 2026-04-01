/// SFTP file manager screen — remote file browser.
///
/// Provides directory navigation, file upload/download, rename, delete,
/// and mkdir operations over an existing SSH session.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/host_profile.dart';
import '../models/session_state.dart';
import '../services/session_service.dart';

class FileManagerScreen extends ConsumerStatefulWidget {
  final int sessionId;
  final HostProfile profile;

  const FileManagerScreen({
    super.key,
    required this.sessionId,
    required this.profile,
  });

  @override
  ConsumerState<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends ConsumerState<FileManagerScreen> {
  final _pathController = TextEditingController();
  List<SftpFileEntry> _entries = [];
  bool _isLoading = true;
  String _currentPath = '/';
  final _selectedItems = <String>{};
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _pathController.text = '/';
    _loadDirectory('/');
  }

  @override
  void dispose() {
    _pathController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _selectedItems.clear();
    });

    final sessionService = ref.read(sessionServiceProvider);
    final entries = await sessionService.sftpList(widget.sessionId, path);

    if (!mounted) return;

    setState(() {
      _currentPath = path;
      _pathController.text = path;
      _entries = entries
        ..sort((a, b) {
          if (a.isDirectory && !b.isDirectory) return -1;
          if (!a.isDirectory && b.isDirectory) return 1;
          return a.name.compareTo(b.name);
        });
      _isLoading = false;
    });
  }

  void _navigateUp() {
    if (_currentPath == '/') return;
    final parts = _currentPath.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) {
      _loadDirectory('/');
    } else {
      parts.removeLast();
      _loadDirectory('/${parts.join('/')}');
    }
  }

  void _navigateToDirectory(SftpFileEntry entry) {
    if (entry.isDirectory) {
      _loadDirectory(entry.path);
    }
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedItems.contains(path)) {
        _selectedItems.remove(path);
      } else {
        _selectedItems.add(path);
      }
    });
  }

  Future<void> _uploadFile() async {
    // In a real implementation, use file_picker
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Select file to upload...')),
    );
  }

  Future<void> _downloadFile(SftpFileEntry entry) async {
    if (entry.isDirectory) return;

    final sessionService = ref.read(sessionServiceProvider);
    final appDir = await sessionService.getAppDir();
    final localPath = '$appDir/downloads/${entry.name}';

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Downloading...'),
          ],
        ),
      ),
    );

    await sessionService.sftpDownload(
      widget.sessionId,
      entry.path,
      localPath,
    );

    if (!mounted) return;
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Downloaded to $localPath')),
    );
  }

  Future<void> _createDirectory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Directory'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Directory name',
            hintText: 'my-folder',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty) return;

    final newPath = '$_currentPath${_currentPath.endsWith('/') ? '' : '/'}'
        '${name.trim()}';
    final sessionService = ref.read(sessionServiceProvider);
    await sessionService.sftpMkdir(widget.sessionId, newPath);

    if (mounted) {
      _loadDirectory(_currentPath);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Created directory: $name')),
      );
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedItems.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete'),
        content: Text(
          'Delete ${_selectedItems.length} item(s)?',
        ),
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

    final sessionService = ref.read(sessionServiceProvider);
    for (final path in _selectedItems) {
      await sessionService.sftpDelete(widget.sessionId, path);
    }

    if (mounted) {
      _loadDirectory(_currentPath);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted selected items')),
      );
    }
  }

  Future<void> _renameItem(SftpFileEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newName == null || newName.trim().isEmpty) return;

    final parentPath = _currentPath.endsWith('/')
        ? _currentPath.substring(0, _currentPath.length - 1)
        : _currentPath;
    final lastSlash = parentPath.lastIndexOf('/');
    final newPath = '${parentPath.substring(0, lastSlash + 1)}${newName.trim()}';

    final sessionService = ref.read(sessionServiceProvider);
    await sessionService.sftpRename(widget.sessionId, entry.path, newPath);

    if (mounted) _loadDirectory(_currentPath);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SFTP File Manager'),
        actions: [
          if (_selectedItems.isNotEmpty) ...[
            Chip(
              label: Text('${_selectedItems.length} selected'),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteSelected,
              tooltip: 'Delete selected',
            ),
          ],
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _createDirectory,
            tooltip: 'New directory',
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: _uploadFile,
            tooltip: 'Upload file',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadDirectory(_currentPath),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Path bar
          Container(
            padding: const EdgeInsets.all(8),
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _currentPath != '/' ? _navigateUp : null,
                  tooltip: 'Go up',
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: TextField(
                    controller: _pathController,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.folder, size: 18),
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'JetBrainsMono',
                    ),
                    onSubmitted: _loadDirectory,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.home),
                  onPressed: () => _loadDirectory('/'),
                  tooltip: 'Home',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          // Transfer progress
          Consumer(
            builder: (context, ref, _) {
              final transfers = ref.watch(transferProgressProvider);
              if (transfers.isEmpty) return const SizedBox.shrink();
              return Column(
                children: transfers.values.map((t) => _TransferBar(transfer: t)).toList(),
              );
            },
          ),

          // File listing
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.folder_open,
                                size: 64, color: theme.colorScheme.outline),
                            const SizedBox(height: 16),
                            Text('Empty directory',
                                style: theme.textTheme.titleMedium),
                          ],
                        ),
                      )
                    : Scrollbar(
                        controller: _scrollController,
                        child: ListView.builder(
                          controller: _scrollController,
                          itemCount: _entries.length,
                          itemBuilder: (ctx, i) {
                            final entry = _entries[i];
                            return _FileListItem(
                              entry: entry,
                              isSelected: _selectedItems.contains(entry.path),
                              onTap: () {
                                if (_selectedItems.isNotEmpty) {
                                  _toggleSelection(entry.path);
                                } else if (entry.isDirectory) {
                                  _navigateToDirectory(entry);
                                } else {
                                  _downloadFile(entry);
                                }
                              },
                              onLongPress: () => _toggleSelection(entry.path),
                              onDownload: entry.isDirectory ? null : () => _downloadFile(entry),
                              onRename: () => _renameItem(entry),
                              onDelete: () async {
                                final sessionService = ref.read(sessionServiceProvider);
                                await sessionService.sftpDelete(
                                    widget.sessionId, entry.path);
                                _loadDirectory(_currentPath);
                              },
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
//  File List Item
// ─────────────────────────────────────────────────

class _FileListItem extends StatelessWidget {
  final SftpFileEntry entry;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onDownload;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _FileListItem({
    required this.entry,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  IconData _fileIcon() {
    if (entry.isDirectory) return Icons.folder;
    final ext = entry.name.contains('.')
        ? entry.name.split('.').last.toLowerCase()
        : '';
    switch (ext) {
      case 'py':
        return Icons.code;
      case 'js':
      case 'ts':
        return Icons.javascript;
      case 'sh':
      case 'bash':
        return Icons.terminal;
      case 'txt':
      case 'md':
        return Icons.description;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image;
      case 'zip':
      case 'tar':
      case 'gz':
        return Icons.archive;
      case 'json':
      case 'yaml':
      case 'toml':
        return Icons.data_object;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _fileColor() {
    if (entry.isDirectory) return Colors.amber;
    final ext = entry.name.contains('.')
        ? entry.name.split('.').last.toLowerCase()
        : '';
    switch (ext) {
      case 'py':
        return Colors.blue;
      case 'js':
      case 'ts':
        return Colors.yellow;
      case 'sh':
      case 'bash':
        return Colors.green;
      case 'jpg':
      case 'jpeg':
      case 'png':
        return Colors.purple;
      case 'zip':
      case 'tar':
      case 'gz':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _fileColor().withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(_fileIcon(), color: _fileColor(), size: 20),
      ),
      title: Text(
        entry.name,
        style: TextStyle(
          fontWeight: entry.isDirectory ? FontWeight.w600 : FontWeight.normal,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${entry.sizeText}  ${entry.permissionsText}  '
        '${entry.modifiedTime != null ? _formatDate(entry.modifiedTime!) : ''}',
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
        ),
      ),
      trailing: isSelected
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'download':
                    onDownload?.call();
                    break;
                  case 'rename':
                    onRename();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (_) => [
                if (onDownload != null)
                  const PopupMenuItem(
                    value: 'download',
                    child: ListTile(
                      leading: Icon(Icons.download),
                      title: Text('Download'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    leading: Icon(Icons.edit),
                    title: Text('Rename'),
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
      selected: isSelected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ─────────────────────────────────────────────────
//  Transfer Progress Bar
// ─────────────────────────────────────────────────

class _TransferBar extends StatelessWidget {
  final TransferProgress transfer;

  const _TransferBar({required this.transfer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(
            transfer.isUpload ? Icons.upload : Icons.download,
            size: 16,
            color: transfer.isComplete
                ? Colors.green
                : transfer.error != null
                    ? Colors.red
                    : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transfer.fileName,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: transfer.progress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            transfer.speedText,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
