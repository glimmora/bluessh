/// Port forwarding configuration screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/host_profile.dart';
import '../services/session_service.dart';

class ForwardingScreen extends ConsumerStatefulWidget {
  final HostProfile profile;

  const ForwardingScreen({super.key, required this.profile});

  @override
  ConsumerState<ForwardingScreen> createState() => _ForwardingScreenState();
}

class _ForwardingScreenState extends ConsumerState<ForwardingScreen> {
  late List<PortForward> _forwards;

  @override
  void initState() {
    super.initState();
    _forwards = List.from(widget.profile.portForwards);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Port Forwarding')),
      body: _forwards.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swap_horiz, size: 64, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text('No port forwards configured',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Add a tunnel to access remote services locally',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _forwards.length,
              itemBuilder: (ctx, i) {
                final fwd = _forwards[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _typeColor(fwd.type).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        _typeIcon(fwd.type),
                        color: _typeColor(fwd.type),
                        size: 20,
                      ),
                    ),
                    title: Text(
                      '${fwd.type.label}: localhost:${fwd.localPort} \u2192 '
                      '${fwd.remoteHost}:${fwd.remotePort}',
                      style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
                    ),
                    subtitle: Text(fwd.type.description),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: fwd.enabled,
                          onChanged: (v) => _toggleForward(i, v),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: () => _removeForward(i),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addForward,
        child: const Icon(Icons.add),
      ),
    );
  }

  IconData _typeIcon(ForwardType type) {
    switch (type) {
      case ForwardType.local:
        return Icons.arrow_forward;
      case ForwardType.remote:
        return Icons.arrow_back;
      case ForwardType.dynamic:
        return Icons.swap_horiz;
    }
  }

  Color _typeColor(ForwardType type) {
    switch (type) {
      case ForwardType.local:
        return Colors.green;
      case ForwardType.remote:
        return Colors.blue;
      case ForwardType.dynamic:
        return Colors.purple;
    }
  }

  void _toggleForward(int index, bool enabled) {
    setState(() {
      _forwards[index] = _forwards[index].copyWith(enabled: enabled);
    });
  }

  void _removeForward(int index) {
    setState(() {
      _forwards.removeAt(index);
    });
  }

  void _addForward() {
    final localPortController = TextEditingController();
    final remoteHostController = TextEditingController(text: '127.0.0.1');
    final remotePortController = TextEditingController();
    ForwardType selectedType = ForwardType.local;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Port Forward'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<ForwardType>(
                segments: ForwardType.values
                    .map((t) => ButtonSegment(
                          value: t,
                          label: Text(t.label),
                        ))
                    .toList(),
                selected: {selectedType},
                onSelectionChanged: (s) =>
                    setDialogState(() => selectedType = s.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: localPortController,
                decoration: const InputDecoration(
                  labelText: 'Local Port',
                  hintText: '8080',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              if (selectedType != ForwardType.dynamic) ...[
                TextField(
                  controller: remoteHostController,
                  decoration: const InputDecoration(
                    labelText: 'Remote Host',
                    hintText: '127.0.0.1',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: remotePortController,
                  decoration: const InputDecoration(
                    labelText: 'Remote Port',
                    hintText: '80',
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final localPort = int.tryParse(localPortController.text) ?? 0;
                final remotePort = int.tryParse(remotePortController.text) ?? 0;
                if (localPort < 1 || localPort > 65535) return;

                setState(() {
                  _forwards.add(PortForward(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    type: selectedType,
                    localPort: localPort,
                    remoteHost: remoteHostController.text.trim().isEmpty
                        ? '127.0.0.1'
                        : remoteHostController.text.trim(),
                    remotePort: remotePort,
                  ));
                });
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}
