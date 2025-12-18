import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

enum ButtonState { red, orange, green }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
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
    setState(() {
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
    setState(() {
      _myState = ButtonState.green;
      _clearRequests();
    });
    _expiryTimer?.cancel();
    _sendControlMessage({"t": "ACCEPT"});
    _showMatchNotification();
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
              Text(
                connectionStatus,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
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

    return SizedBox(
      width: 260,
      height: 260,
      child: InkWell(
        onTap: () => _handleButtonClick(),
        borderRadius: BorderRadius.circular(999),
        child: Image.asset(
          assetPath,
          fit: BoxFit.contain,
        ),
      ),
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
    setState(() {
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
        // Stop advertising/discovery once connected to save battery/logic
        Nearby().stopAdvertising();
        Nearby().stopDiscovery();
        isAdvertising = false;
        isDiscovering = false;
      } else {
        connectionStatus = "Connection Failed: $status";
      }
    });
  }

  void _onDisconnected(String id) {
    setState(() {
      connectedEndpointId = null;
      connectionStatus = "Disconnected";
      _myState = ButtonState.red;
      _clearRequests();
    });
    _expiryTimer?.cancel();
  }

  void _stopAll() async {
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
          setState(() {
            _myState = ButtonState.green;
            _clearRequests();
          });
          _expiryTimer?.cancel();
          _showMatchNotification();
          return;
        }

        if (type == "RESET") {
          setState(() {
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
        setState(() {
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
