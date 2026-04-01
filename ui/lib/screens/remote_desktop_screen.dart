/// Remote desktop screen — VNC/RDP graphical viewer.
///
/// Renders frames from a remote desktop session (VNC or RDP) using
/// CustomPainter, handles keyboard/mouse input, multi-monitor layout,
/// pinch-to-zoom, fullscreen mode, and session recording.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/host_profile.dart';
import '../services/session_service.dart';

class RemoteDesktopScreen extends ConsumerStatefulWidget {
  final int sessionId;
  final HostProfile profile;

  const RemoteDesktopScreen({
    super.key,
    required this.sessionId,
    required this.profile,
  });

  @override
  ConsumerState<RemoteDesktopScreen> createState() =>
      _RemoteDesktopScreenState();
}

class _RemoteDesktopScreenState extends ConsumerState<RemoteDesktopScreen> {
  // Frame buffer
  Uint8List? _frameBuffer;
  int _frameWidth = 1920;
  int _frameHeight = 1080;
  ui.Image? _currentImage;

  // Multi-monitor support
  final List<MonitorRect> _monitors = [const MonitorRect(0, 0, 1920, 1080)];
  int _activeMonitor = 0;

  // Input state
  final Set<LogicalKeyboardKey> _pressedKeys = {};
  Offset _pointerPosition = Offset.zero;
  int _pointerButtons = 0;

  // Performance tracking
  int _fps = 0;
  int _frameCount = 0;
  DateTime _lastFpsUpdate = DateTime.now();
  int _bytesReceived = 0;
  int _latencyMs = 0;

  // Connection state
  bool _isConnected = true;
  bool _isFullscreen = false;
  bool _showToolbar = true;
  bool _clipboardSync = true;
  bool _isRecording = false;

  // View transform
  double _scale = 1.0;
  Offset _panOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _listenForSessionEvents();
  }

  @override
  void dispose() {
    if (_isRecording) {
      ref.read(sessionServiceProvider).stopRecording(widget.sessionId);
    }
    ref.read(sessionServiceProvider).disconnect(widget.sessionId);
    _currentImage?.dispose();
    super.dispose();
  }

  void _listenForSessionEvents() {
    final sessionService = ref.read(sessionServiceProvider);

    // Listen for frame data (VNC/RDP)
    sessionService.events
        .where((e) => e.sessionId == widget.sessionId)
        .listen((event) {
      switch (event.type) {
        case 'frame_data':
          _updateFrame(event.data);
        case 'disconnected':
          setState(() => _isConnected = false);
        case 'reconnected':
          setState(() => _isConnected = true);
        case 'monitor_layout':
          _updateMonitorLayout(event.data);
      }
    });

    // Clipboard sync
    if (_clipboardSync) {
      sessionService.clipboardEvents
          .where((e) => e.sessionId == widget.sessionId)
          .listen((event) {
        final text = String.fromCharCodes(event.data);
        Clipboard.setData(ClipboardData(text: text));
      });
    }
  }

  void _updateFrame(Map<String, dynamic> data) {
    final frameData = data['frame'] as Uint8List?;
    final width = data['width'] as int? ?? _frameWidth;
    final height = data['height'] as int? ?? _frameHeight;

    if (frameData == null) return;

    setState(() {
      _frameBuffer = frameData;
      _frameWidth = width;
      _frameHeight = height;
      _bytesReceived += frameData.length;
      _frameCount++;

      final now = DateTime.now();
      final elapsed = now.difference(_lastFpsUpdate);
      if (elapsed.inSeconds >= 1) {
        _fps = _frameCount;
        _frameCount = 0;
        _lastFpsUpdate = now;
      }
    });

    _decodeFrame(frameData, width, height);
  }

  Future<void> _decodeFrame(Uint8List data, int width, int height) async {
    try {
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: width,
        targetHeight: height,
      );
      final frame = await codec.getNextFrame();
      if (_currentImage != null) {
        _currentImage!.dispose();
      }
      setState(() {
        _currentImage = frame.image;
      });
    } catch (e) {
      // Frame decode error — skip
    }
  }

  void _updateMonitorLayout(Map<String, dynamic> data) {
    final monitors = data['monitors'] as List?;
    if (monitors == null) return;

    setState(() {
      _monitors.clear();
      for (final m in monitors) {
        _monitors.add(MonitorRect(
          m['x'] as int,
          m['y'] as int,
          m['width'] as int,
          m['height'] as int,
        ));
      }
    });
  }

  /// Sends a key event to the remote session.
  ///
  /// System navigation keys (Back, Home, Recent Apps) are intentionally
  /// NOT forwarded so the Android system can handle them normally.
  void _sendKeyEvent(KeyEvent event) {
    // Let system navigation keys propagate to the OS — do not consume them.
    // This ensures Back, Home, and Recent buttons work as expected.
    // System navigation keys that must NOT be forwarded to the remote session.
    // Only Back and Escape actually reach Flutter on Android — Home and
    // Recent Apps are intercepted by the system before Flutter sees them.
    final systemKeys = <LogicalKeyboardKey>{
      LogicalKeyboardKey.goBack,    // Android Back button
      LogicalKeyboardKey.escape,    // Some devices map Escape → Back
    };
    if (systemKeys.contains(event.logicalKey)) {
      return; // Let Flutter / OS handle these keys
    }

    final sessionService = ref.read(sessionServiceProvider);
    final isDown = event is KeyDownEvent;

    if (isDown) {
      _pressedKeys.add(event.logicalKey);
    } else {
      _pressedKeys.remove(event.logicalKey);
    }

    // Build key event packet
    final keyData = Uint8List(8);
    final keyId = _mapKeyCode(event.logicalKey);
    keyData[0] = isDown ? 1 : 0; // event type
    keyData[1] = (keyId >> 24) & 0xFF;
    keyData[2] = (keyId >> 16) & 0xFF;
    keyData[3] = (keyId >> 8) & 0xFF;
    keyData[4] = keyId & 0xFF;

    sessionService.write(widget.sessionId, keyData);
  }

  void _sendPointerEvent(Offset position, int buttons) {
    final sessionService = ref.read(sessionServiceProvider);

    // Convert from widget coords to remote desktop coords
    final monitor = _monitors[_activeMonitor];
    final x = ((position.dx - _panOffset.dx) / _scale)
        .clamp(0.0, monitor.width.toDouble())
        .toInt();
    final y = ((position.dy - _panOffset.dy) / _scale)
        .clamp(0.0, monitor.height.toDouble())
        .toInt();

    final pointerData = Uint8List(8);
    pointerData[0] = buttons & 0xFF;
    pointerData[1] = (x >> 8) & 0xFF;
    pointerData[2] = x & 0xFF;
    pointerData[3] = (y >> 8) & 0xFF;
    pointerData[4] = y & 0xFF;

    sessionService.write(widget.sessionId, pointerData);
  }

  int _mapKeyCode(LogicalKeyboardKey key) {
    // X11 keysym mapping for VNC/RDP

    // Basic keys
    if (key == LogicalKeyboardKey.enter) return 0xFF0D;
    if (key == LogicalKeyboardKey.backspace) return 0xFF08;
    if (key == LogicalKeyboardKey.tab) return 0xFF09;
    if (key == LogicalKeyboardKey.escape) return 0xFF1B;
    if (key == LogicalKeyboardKey.delete) return 0xFFFF;
    if (key == LogicalKeyboardKey.insert) return 0xFF63;
    if (key == LogicalKeyboardKey.space) return 0x0020;

    // Arrow keys
    if (key == LogicalKeyboardKey.arrowUp) return 0xFF52;
    if (key == LogicalKeyboardKey.arrowDown) return 0xFF54;
    if (key == LogicalKeyboardKey.arrowLeft) return 0xFF51;
    if (key == LogicalKeyboardKey.arrowRight) return 0xFF53;

    // Navigation
    if (key == LogicalKeyboardKey.home) return 0xFF50;
    if (key == LogicalKeyboardKey.end) return 0xFF57;
    if (key == LogicalKeyboardKey.pageUp) return 0xFF55;
    if (key == LogicalKeyboardKey.pageDown) return 0xFF56;

    // Modifier keys
    if (key == LogicalKeyboardKey.shiftLeft || key == LogicalKeyboardKey.shiftRight) return 0xFFE1;
    if (key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight) return 0xFFE3;
    if (key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight) return 0xFFE9;
    if (key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight) return 0xFFEB;
    if (key == LogicalKeyboardKey.capsLock) return 0xFFE5;

    // Special combinations
    if (key == LogicalKeyboardKey.printScreen) return 0xFF61;
    if (key == LogicalKeyboardKey.scrollLock) return 0xFF14;
    if (key == LogicalKeyboardKey.pause) return 0xFF13;
    if (key == LogicalKeyboardKey.numLock) return 0xFF7F;

    // Function keys F1-F12
    if (key.keyId >= LogicalKeyboardKey.f1.keyId &&
        key.keyId <= LogicalKeyboardKey.f12.keyId) {
      return 0xFFBE + (key.keyId - LogicalKeyboardKey.f1.keyId);
    }

    // Function keys F13-F24
    if (key.keyId >= LogicalKeyboardKey.f13.keyId &&
        key.keyId <= LogicalKeyboardKey.f24.keyId) {
      return 0xFFC1 + (key.keyId - LogicalKeyboardKey.f13.keyId);
    }

    // Numpad
    if (key == LogicalKeyboardKey.numpad0) return 0xFFB0;
    if (key == LogicalKeyboardKey.numpad1) return 0xFFB1;
    if (key == LogicalKeyboardKey.numpad2) return 0xFFB2;
    if (key == LogicalKeyboardKey.numpad3) return 0xFFB3;
    if (key == LogicalKeyboardKey.numpad4) return 0xFFB4;
    if (key == LogicalKeyboardKey.numpad5) return 0xFFB5;
    if (key == LogicalKeyboardKey.numpad6) return 0xFFB6;
    if (key == LogicalKeyboardKey.numpad7) return 0xFFB7;
    if (key == LogicalKeyboardKey.numpad8) return 0xFFB8;
    if (key == LogicalKeyboardKey.numpad9) return 0xFFB9;
    if (key == LogicalKeyboardKey.numpadAdd) return 0xFFAB;
    if (key == LogicalKeyboardKey.numpadSubtract) return 0xFFAD;
    if (key == LogicalKeyboardKey.numpadMultiply) return 0xFFAA;
    if (key == LogicalKeyboardKey.numpadDivide) return 0xFFAF;
    if (key == LogicalKeyboardKey.numpadDecimal) return 0xFFAE;
    if (key == LogicalKeyboardKey.numpadEnter) return 0xFF8D;

    // Printable characters
    final char = key.keyLabel;
    if (char.length == 1) {
      return char.codeUnitAt(0);
    }

    return 0;
  }

  Future<void> _toggleRecording() async {
    final sessionService = ref.read(sessionServiceProvider);
    if (_isRecording) {
      await sessionService.stopRecording(widget.sessionId);
      setState(() => _isRecording = false);
    } else {
      final appDir = await sessionService.getAppDir();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ext = widget.profile.protocol == ProtocolType.vnc ? 'vnc-rec' : 'rdp-rec';
      final path = '$appDir/recordings/${widget.sessionId}_$ts.$ext';
      await sessionService.startRecording(widget.sessionId, path);
      setState(() => _isRecording = true);
    }
  }

  void _resetView() {
    setState(() {
      _scale = 1.0;
      _panOffset = Offset.zero;
    });
  }

  Future<void> _pasteToRemote() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      final bytes = Uint8List.fromList(data!.text!.codeUnits);
      await ref.read(sessionServiceProvider).clipboardSet(
            widget.sessionId,
            bytes,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pasted to remote'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  void _fitToScreen() {
    final screenSize = MediaQuery.of(context).size;
    final monitor = _monitors[_activeMonitor];
    final scaleX = screenSize.width / monitor.width;
    final scaleY = screenSize.height / monitor.height;
    setState(() {
      _scale = scaleX < scaleY ? scaleX : scaleY;
      _panOffset = Offset(
        (screenSize.width - monitor.width * _scale) / 2,
        (screenSize.height - monitor.height * _scale) / 2,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monitor = _monitors[_activeMonitor];

    return Scaffold(
      appBar: _showToolbar
          ? AppBar(
              title: Text(widget.profile.name),
              actions: [
                // FPS / stats
                Chip(
                  avatar: Icon(
                    _isConnected ? Icons.check_circle : Icons.error,
                    size: 16,
                    color: _isConnected ? Colors.green : Colors.red,
                  ),
                  label: Text(
                    '${_fps}fps ${_formatBytes(_bytesReceived)}',
                    style: theme.textTheme.labelSmall,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),

                // Multi-monitor selector
                if (_monitors.length > 1)
                  PopupMenuButton<int>(
                    icon: const Icon(Icons.monitor),
                    onSelected: (i) => setState(() => _activeMonitor = i),
                    itemBuilder: (_) => [
                      for (int i = 0; i < _monitors.length; i++)
                        PopupMenuItem(
                          value: i,
                          child: Text('Monitor ${i + 1} '
                              '(${_monitors[i].width}x${_monitors[i].height})'),
                        ),
                    ],
                  ),

                // View controls
                IconButton(
                  icon: const Icon(Icons.fit_screen),
                  tooltip: 'Fit to screen',
                  onPressed: _fitToScreen,
                ),
                IconButton(
                  icon: const Icon(Icons.zoom_in_map),
                  tooltip: 'Reset zoom',
                  onPressed: _resetView,
                ),

                // Clipboard sync toggle
                IconButton(
                  icon: Icon(
                    _clipboardSync ? Icons.content_paste : Icons.content_paste_off,
                  ),
                  tooltip: _clipboardSync ? 'Clipboard sync on' : 'Clipboard sync off',
                  onPressed: () =>
                      setState(() => _clipboardSync = !_clipboardSync),
                ),

                // Paste local clipboard to remote
                IconButton(
                  icon: const Icon(Icons.paste),
                  tooltip: 'Paste to remote',
                  onPressed: _pasteToRemote,
                ),

                // Recording
                IconButton(
                  icon: Icon(
                    _isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
                    color: _isRecording ? Colors.red : null,
                  ),
                  tooltip: _isRecording ? 'Stop recording' : 'Start recording',
                  onPressed: _toggleRecording,
                ),

                // Fullscreen
                IconButton(
                  icon: Icon(
                    _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  ),
                  onPressed: () {
                    setState(() => _isFullscreen = !_isFullscreen);
                    // Always keep system navigation buttons visible.
                    // edgeToEdge shows status bar + navigation bar with
                    // content drawn behind them (preferred over immersive
                    // which hides the navigation bar entirely).
                    SystemChrome.setEnabledSystemUIMode(
                      SystemUiMode.edgeToEdge,
                    );
                  },
                ),
              ],
            )
          : null,
      body: KeyboardListener(
        focusNode: FocusNode(),
        autofocus: true,
        onKeyEvent: _sendKeyEvent,
        child: GestureDetector(
          // Pan
          onScaleUpdate: (details) {
            if (details.scale == 1.0) {
              // Pan
              setState(() {
                _panOffset += details.focalPointDelta;
              });
            } else {
              // Zoom
              setState(() {
                _scale = (_scale * details.scale).clamp(0.25, 4.0);
              });
            }
          },
          // Mouse / touch input
          onTapDown: (details) {
            _sendPointerEvent(details.localPosition, 1);
          },
          onTapUp: (details) {
            _sendPointerEvent(details.localPosition, 0);
          },
          onSecondaryTapDown: (details) {
            _sendPointerEvent(details.localPosition, 4);
          },
          onSecondaryTapUp: (details) {
            _sendPointerEvent(details.localPosition, 0);
          },
          onDoubleTap: () {
            // Double click
            _sendPointerEvent(_pointerPosition, 1);
            _sendPointerEvent(_pointerPosition, 0);
            _sendPointerEvent(_pointerPosition, 1);
            _sendPointerEvent(_pointerPosition, 0);
          },
          onLongPressStart: (details) {
            // Right click on mobile
            _sendPointerEvent(details.localPosition, 4);
          },
          onLongPressEnd: (_) {
            _sendPointerEvent(_pointerPosition, 0);
          },
          child: ClipRect(
            child: Transform(
              transform: Matrix4.identity()
                ..translate(_panOffset.dx, _panOffset.dy)
                ..scale(_scale),
              child: CustomPaint(
                painter: _RemoteDesktopPainter(
                  image: _currentImage,
                  width: monitor.width,
                  height: monitor.height,
                  isConnected: _isConnected,
                ),
                size: Size(
                  monitor.width.toDouble(),
                  monitor.height.toDouble(),
                ),
                child: SizedBox(
                  width: monitor.width.toDouble(),
                  height: monitor.height.toDouble(),
                ),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => setState(() => _showToolbar = !_showToolbar),
        child: Icon(_showToolbar ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ─────────────────────────────────────────────────
//  Monitor Rectangle
// ─────────────────────────────────────────────────

class MonitorRect {
  final int x;
  final int y;
  final int width;
  final int height;

  const MonitorRect(this.x, this.y, this.width, this.height);
}

// ─────────────────────────────────────────────────
//  Remote Desktop Painter
// ─────────────────────────────────────────────────

class _RemoteDesktopPainter extends CustomPainter {
  final ui.Image? image;
  final int width;
  final int height;
  final bool isConnected;

  _RemoteDesktopPainter({
    required this.image,
    required this.width,
    required this.height,
    required this.isConnected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF1A1A2E),
    );

    if (image != null) {
      final src = Rect.fromLTWH(
        0, 0,
        image!.width.toDouble(),
        image!.height.toDouble(),
      );
      final dst = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      canvas.drawImageRect(image!, src, dst, Paint());
    } else if (!isConnected) {
      // Disconnected overlay
      final textPainter = TextPainter(
        text: const TextSpan(
          text: 'Disconnected',
          style: TextStyle(
            color: Colors.red,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(
          (width - textPainter.width) / 2,
          (height - textPainter.height) / 2,
        ),
      );
    } else {
      // Connecting spinner placeholder
      final textPainter = TextPainter(
        text: const TextSpan(
          text: 'Waiting for remote desktop...',
          style: TextStyle(color: Colors.white54, fontSize: 18),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(
          (width - textPainter.width) / 2,
          (height - textPainter.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RemoteDesktopPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.isConnected != isConnected;
  }
}

// Extension needed at file scope
extension on _RemoteDesktopScreenState {}
