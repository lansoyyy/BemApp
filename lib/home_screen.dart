import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';

enum ButtonState { red, orange, green }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final Strategy strategy = Strategy.P2P_STAR;
  String? connectedEndpointId;
  String connectionStatus = "Disconnected";
  bool isAdvertising = false;
  bool isDiscovering = false;
  final String userName = "User ${DateTime.now().second}"; // Simple random name

  // Game State
  ButtonState _myState = ButtonState.red;
  DateTime? _outgoingRequestExpiresAt;
  DateTime? _incomingRequestExpiresAt;
  Timer? _expiryTimer;

  // Connection Health Monitoring (Disabled for stability)
  Timer? _heartbeatTimer;
  DateTime? _lastHeartbeatReceived;
  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const Duration _connectionTimeout = Duration(seconds: 120);

  // Animation Controllers
  late AnimationController _buttonScaleController;
  late AnimationController _buttonFadeController;
  late AnimationController _statusPulseController;
  late AnimationController _celebrationController;
  late Animation<double> _buttonScaleAnimation;
  late Animation<double> _buttonFadeAnimation;
  late Animation<double> _statusPulseAnimation;
  late Animation<double> _celebrationAnimation;

  // Audio Player
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _initAnimations();
  }

  void _initAnimations() {
    // Button scale animation for press effect
    _buttonScaleController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _buttonScaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _buttonScaleController, curve: Curves.easeInOut),
    );

    // Button fade animation for state changes
    _buttonFadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _buttonFadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _buttonFadeController, curve: Curves.easeInOut),
    );

    // Status pulse animation
    _statusPulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    _statusPulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _statusPulseController, curve: Curves.easeInOut),
    );

    // Celebration animation
    _celebrationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _celebrationAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _celebrationController, curve: Curves.elasticOut),
    );
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _heartbeatTimer?.cancel();
    _buttonScaleController.dispose();
    _buttonFadeController.dispose();
    _statusPulseController.dispose();
    _celebrationController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  // Sound Effects

  Future<void> _playSound(String soundPath) async {
    try {
      await _audioPlayer.play(AssetSource(soundPath));
    } catch (e) {
      debugPrint("Error playing sound: $e");
    }
  }

  void _playButtonClick() {
    _playSound('sounds/button_click.wav');
  }

  void _playMatchSuccess() {
    _playSound('sounds/match_success.wav');
  }

  void _playConnectionSuccess() {
    _playSound('sounds/connection_success.wav');
  }

  void _playReset() {
    _playSound('sounds/reset.wav');
  }

  bool _isValidUntil(DateTime? expiresAt) {
    if (expiresAt == null) return false;
    return DateTime.now().isBefore(expiresAt);
  }

  bool get _hasIncomingRequest => _isValidUntil(_incomingRequestExpiresAt);

  void _clearRequests() {
    _outgoingRequestExpiresAt = null;
    _incomingRequestExpiresAt = null;
  }

  // Heartbeat & Connection Health Methods

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _sendHeartbeat();
      _checkConnectionHealth();
    });
    _lastHeartbeatReceived = DateTime.now();
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastHeartbeatReceived = null;
  }

  void _sendHeartbeat() {
    _sendControlMessage(
        {"t": "PING", "ts": DateTime.now().millisecondsSinceEpoch});
  }

  void _checkConnectionHealth() {
    // Disabled aggressive timeout checking for stable connections
    // Only log warnings, don't disconnect
    if (_lastHeartbeatReceived == null) return;

    final timeSinceLastHeartbeat =
        DateTime.now().difference(_lastHeartbeatReceived!);
    if (timeSinceLastHeartbeat > _connectionTimeout) {
      debugPrint(
          "Warning: No heartbeat received for ${timeSinceLastHeartbeat.inMinutes} minutes");
      // Don't automatically disconnect - let nearby_connections handle it naturally
    }
  }

  void _scheduleExpiryTimer() {
    _expiryTimer?.cancel();

    final now = DateTime.now();
    final candidates = <DateTime?>[
      _outgoingRequestExpiresAt,
      _incomingRequestExpiresAt
    ].whereType<DateTime>().where((t) => t.isAfter(now)).toList();

    if (candidates.isEmpty) return;
    candidates.sort();
    final next = candidates.first;

    _expiryTimer = Timer(next.difference(now), () {
      if (!mounted) return;
      _handleExpiryIfNeeded();
    });
  }

  void _handleExpiryIfNeeded() {
    final now = DateTime.now();

    if (_myState == ButtonState.orange) {
      final out = _outgoingRequestExpiresAt;
      if (out != null && !now.isBefore(out)) {
        setState(() {
          _myState = ButtonState.red;
          _outgoingRequestExpiresAt = null;
        });
        _sendControlMessage({"t": "RESET"});
      }
    }

    final inc = _incomingRequestExpiresAt;
    if (inc != null && !now.isBefore(inc) && _myState != ButtonState.green) {
      setState(() {
        _incomingRequestExpiresAt = null;
      });
    }

    _scheduleExpiryTimer();
  }

  void _startOutgoingRequest(Duration duration) {
    final expiresAt = DateTime.now().add(duration);
    _playButtonClick();
    _animateButtonStateChange(() {
      _myState = ButtonState.orange;
      _outgoingRequestExpiresAt = expiresAt;
    });
    _sendControlMessage({
      "t": "REQUEST",
      "exp": expiresAt.millisecondsSinceEpoch,
    });
    _scheduleExpiryTimer();
  }

  void _acceptIncomingRequest() {
    _playButtonClick();
    _animateButtonStateChange(() {
      _myState = ButtonState.green;
      _clearRequests();
    });
    _expiryTimer?.cancel();
    _sendControlMessage({"t": "ACCEPT"});
    _showMatchNotification();
    _playMatchSuccess();
    _triggerCelebration();
  }

  void _animateButtonStateChange(VoidCallback onChange) {
    _buttonFadeController.forward(from: 0.0).then((_) {
      if (!mounted) return;
      setState(() {
        onChange();
      });
      if (!mounted) return;
      _buttonFadeController.reverse(from: 1.0);
    });
  }

  void _triggerCelebration() {
    _celebrationController.forward().then((_) {
      _celebrationController.reverse();
    });
  }

  Future<void> _checkPermissions() async {
    // Request multiple permissions at once
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
    ].request();

    if (statuses.values.any((status) => status.isDenied)) {
      debugPrint("Some permissions were denied");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: connectedEndpointId != null
            ? IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _disconnect,
                tooltip: "Disconnect",
              )
            : null,
        actions: [
          if (connectedEndpointId != null)
            IconButton(
              icon: Image.asset(
                "assets/Reset lips.png",
                width: 32,
                height: 32,
              ),
              onPressed: _resetGame,
              tooltip: "Reset",
            )
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            "assets/app background.png",
            fit: BoxFit.cover,
          ),
          SafeArea(
            child: connectedEndpointId != null
                ? Center(
                    child: _buildMainButton(),
                  )
                : _buildLanding(),
          ),
        ],
      ),
    );
  }

  Widget _buildLanding() {
    final bool busy = isAdvertising || isDiscovering;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              "assets/new.png",
              width: 180,
            ),
            const SizedBox(height: 28),
            if (!busy) ...[
              _landingButton(
                label: "CREATE ROOM",
                backgroundColor: const Color(0xFFF2A14A),
                icon: Icons.add,
                onPressed: _startAdvertising,
              ),
              const SizedBox(height: 16),
              _landingButton(
                label: "JOIN ROOM",
                backgroundColor: const Color(0xFF5CB5F7),
                icon: Icons.search,
                onPressed: _startDiscovery,
              ),
            ] else ...[
              _buildConnectionStatus(),
              const SizedBox(height: 16),
              _landingButton(
                label: "STOP",
                backgroundColor: Colors.black54,
                icon: Icons.stop,
                onPressed: _stopAll,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _landingButton({
    required String label,
    required Color backgroundColor,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: Colors.white,
          elevation: 10,
          shadowColor: Colors.black45,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionStatus() {
    Color statusColor;
    IconData statusIcon;
    bool shouldPulse = connectionStatus.contains("Reconnecting") ||
        connectionStatus.contains("Advertising") ||
        connectionStatus.contains("Discovering");

    if (connectionStatus.contains("Connected")) {
      statusColor = Colors.green;
      statusIcon = Icons.wifi;
    } else if (connectionStatus.contains("Reconnecting")) {
      statusColor = Colors.orange;
      statusIcon = Icons.sync;
    } else if (connectionStatus.contains("Error") ||
        connectionStatus.contains("Failed")) {
      statusColor = Colors.red;
      statusIcon = Icons.error_outline;
    } else {
      statusColor = Colors.white;
      statusIcon = Icons.info_outline;
    }

    return AnimatedBuilder(
      animation: _statusPulseController,
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: shouldPulse
                ? Border.all(
                    color: statusColor.withOpacity(_statusPulseAnimation.value),
                    width: 2,
                  )
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                statusIcon,
                color: statusColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                connectionStatus,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMainButton() {
    String assetPath;
    switch (_myState) {
      case ButtonState.red:
        assetPath = "assets/Red Button.png";
        break;
      case ButtonState.orange:
        assetPath = "assets/Yellow Button.png";
        break;
      case ButtonState.green:
        assetPath = "assets/Green Button.png";
        break;
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        _buttonScaleController,
        _buttonFadeController,
        _celebrationController
      ]),
      builder: (context, child) {
        return Transform.scale(
          scale: _buttonScaleAnimation.value *
              (1 + _celebrationAnimation.value * 0.3),
          child: Opacity(
            opacity: _buttonFadeAnimation.value,
            child: SizedBox(
              width: 260,
              height: 260,
              child: GestureDetector(
                onTapDown: (_) {
                  _buttonScaleController.forward();
                },
                onTapUp: (_) {
                  _buttonScaleController.reverse();
                  _handleButtonClick();
                },
                onTapCancel: () {
                  _buttonScaleController.reverse();
                },
                child: Image.asset(
                  assetPath,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleButtonClick() async {
    if (connectedEndpointId == null) return;

    if (_myState == ButtonState.red) {
      if (_hasIncomingRequest) {
        _acceptIncomingRequest();
        return;
      }

      final duration = await _pickRequestDuration();
      if (duration == null) return;
      _startOutgoingRequest(duration);
      return;
    }
  }

  Future<Duration?> _pickRequestDuration() async {
    const options = <({String label, Duration duration})>[
      (label: "30 minutes", duration: Duration(minutes: 30)),
      (label: "1 hour", duration: Duration(hours: 1)),
      (label: "6 hours", duration: Duration(hours: 6)),
      (label: "12 hours", duration: Duration(hours: 12)),
      (label: "24 hours", duration: Duration(hours: 24)),
    ];

    return showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      builder: (context) {
        return SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Material(
                color: Colors.white.withOpacity(0.22),
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final opt in options) ...[
                        SizedBox(
                          width: double.infinity,
                          height: 46,
                          child: ElevatedButton(
                            onPressed: () =>
                                Navigator.pop(context, opt.duration),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.85),
                              foregroundColor: Colors.black87,
                              elevation: 0,
                              shape: const StadiumBorder(),
                            ),
                            child: Text(
                              opt.label,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          "Cancel",
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _resetGame() {
    _playReset();
    _animateButtonStateChange(() {
      _myState = ButtonState.red;
      _clearRequests();
    });
    _expiryTimer?.cancel();
    _sendControlMessage({"t": "RESET"});
  }

  void _showMatchNotification() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("It's a Match! Both buttons are Green!"),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  // P2P Logic

  void _startAdvertising() async {
    try {
      bool result = await Nearby().startAdvertising(
        userName,
        strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: "com.example.lightsapp",
      );
      setState(() {
        isAdvertising = result;
        connectionStatus = result ? "Advertising..." : "Failed to Advertise";
      });
    } catch (e) {
      setState(() {
        connectionStatus = "Error: $e";
      });
    }
  }

  void _startDiscovery() async {
    try {
      bool result = await Nearby().startDiscovery(
        userName,
        strategy,
        onEndpointFound: (id, name, serviceId) {
          // Auto connect to found endpoint for simplicity, or show list
          // For this request, let's show a dialog or snackbar to confirm connection
          _showFoundDeviceDialog(id, name);
        },
        onEndpointLost: (id) {
          debugPrint("Endpoint lost: $id");
        },
        serviceId: "com.example.lightsapp",
      );
      setState(() {
        isDiscovering = result;
        connectionStatus = result ? "Discovering..." : "Failed to Discover";
      });
    } catch (e) {
      setState(() {
        connectionStatus = "Error: $e";
      });
    }
  }

  void _showFoundDeviceDialog(String id, String name) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Device Found"),
        content: Text("Connect to $name?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _requestConnection(id, name);
            },
            child: const Text("Connect"),
          ),
        ],
      ),
    );
  }

  void _requestConnection(String id, String name) async {
    try {
      Nearby().requestConnection(
        userName,
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      setState(() {
        connectionStatus = "Connecting to $name...";
      });
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Connection Request"),
        content: Text(
            "${info.endpointName} wants to connect. Token: ${info.authenticationToken}"),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await Nearby().rejectConnection(id);
            },
            child: const Text("Reject"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await Nearby()
                  .acceptConnection(id, onPayLoadRecieved: _onPayloadReceived);
            },
            child: const Text("Accept"),
          ),
        ],
      ),
    );
  }

  void _onConnectionResult(String id, Status status) {
    setState(() {
      if (status == Status.CONNECTED) {
        connectedEndpointId = id;
        connectionStatus = "Connected";
        _myState = ButtonState.red;
        _clearRequests();
        _expiryTimer?.cancel();

        // Start heartbeat for connection health monitoring (non-intrusive)
        _startHeartbeat();

        // Stop advertising/discovery once connected to save battery/logic
        Nearby().stopAdvertising();
        Nearby().stopDiscovery();
        isAdvertising = false;
        isDiscovering = false;

        // Play connection success sound
        _playConnectionSuccess();
      } else {
        connectionStatus = "Connection Failed: $status";
      }
    });
  }

  void _onDisconnected(String id) {
    _stopHeartbeat();

    setState(() {
      connectedEndpointId = null;
      connectionStatus = "Disconnected";
      _myState = ButtonState.red;
      _clearRequests();
    });
    _expiryTimer?.cancel();
  }

  void _stopAll() async {
    _stopHeartbeat();

    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();
    setState(() {
      isAdvertising = false;
      isDiscovering = false;
      connectionStatus = "Idle";
    });
  }

  void _disconnect() async {
    if (connectedEndpointId != null) {
      _stopHeartbeat();

      await Nearby().disconnectFromEndpoint(connectedEndpointId!);
      setState(() {
        connectedEndpointId = null;
        connectionStatus = "Disconnected";
        _myState = ButtonState.red;
        _clearRequests();
      });
      _expiryTimer?.cancel();
    }
  }

  // Send & Receive Logic

  void _sendControlMessage(Map<String, Object?> data) {
    _sendMessage(jsonEncode(data));
  }

  void _sendMessage(String message) async {
    if (connectedEndpointId == null) return;

    try {
      await Nearby().sendBytesPayload(
        connectedEndpointId!,
        Uint8List.fromList(utf8.encode(message)),
      );
    } catch (e) {
      debugPrint("Error sending payload: $e");
    }
  }

  void _onPayloadReceived(String id, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      String message = utf8.decode(payload.bytes!);
      debugPrint("Received message: $message");

      Map<String, Object?>? data;
      try {
        final decoded = jsonDecode(message);
        if (decoded is Map) {
          data = decoded.cast<String, Object?>();
        }
      } catch (_) {
        data = null;
      }

      if (data != null && data["t"] is String) {
        final type = data["t"] as String;

        // Handle heartbeat messages
        if (type == "PING") {
          _lastHeartbeatReceived = DateTime.now();
          _sendControlMessage(
              {"t": "PONG", "ts": DateTime.now().millisecondsSinceEpoch});
          return;
        }

        if (type == "PONG") {
          _lastHeartbeatReceived = DateTime.now();
          return;
        }

        if (type == "REQUEST") {
          final expRaw = data["exp"];
          final expMillis = expRaw is int
              ? expRaw
              : expRaw is num
                  ? expRaw.toInt()
                  : null;
          final expiresAt = expMillis == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(expMillis);

          if (expiresAt != null && DateTime.now().isBefore(expiresAt)) {
            if (_myState == ButtonState.orange &&
                _isValidUntil(_outgoingRequestExpiresAt)) {
              setState(() {
                _myState = ButtonState.green;
                _clearRequests();
              });
              _expiryTimer?.cancel();
              _sendControlMessage({"t": "ACCEPT"});
              _showMatchNotification();
              return;
            }

            setState(() {
              _incomingRequestExpiresAt = expiresAt;
            });
            _scheduleExpiryTimer();
          }
          return;
        }

        if (type == "ACCEPT") {
          _playMatchSuccess();
          _animateButtonStateChange(() {
            _myState = ButtonState.green;
            _clearRequests();
          });
          _expiryTimer?.cancel();
          _showMatchNotification();
          _triggerCelebration();
          return;
        }

        if (type == "RESET") {
          _playReset();
          _animateButtonStateChange(() {
            _myState = ButtonState.red;
            _clearRequests();
          });
          _expiryTimer?.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Game Reset by peer")),
          );
          return;
        }
      }

      if (message == "RESET") {
        _playReset();
        _animateButtonStateChange(() {
          _myState = ButtonState.red;
          _clearRequests();
        });
        _expiryTimer?.cancel();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Game Reset by peer")),
        );
      }
    }
  }
}
