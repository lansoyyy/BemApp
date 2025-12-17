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
  bool isSimulating = false;
  final String userName = "User ${DateTime.now().second}"; // Simple random name

  // Game State
  ButtonState _myState = ButtonState.red;
  bool _peerHasPressed = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
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
      appBar: AppBar(
        title: const Text("Light Signal App"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetGame,
            tooltip: "Reset Game",
          )
        ],
      ),
      body: connectedEndpointId != null
          ? Center(
              child: _buildMainButton(),
            )
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  // Status Section
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        children: [
                          Text("Status: $connectionStatus",
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          if (connectedEndpointId == null && !isSimulating) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                ElevatedButton(
                                  onPressed:
                                      isAdvertising ? null : _startAdvertising,
                                  child: Text(isAdvertising
                                      ? "Advertising..."
                                      : "Host (Advertise)"),
                                ),
                                ElevatedButton(
                                  onPressed:
                                      isDiscovering ? null : _startDiscovery,
                                  child: Text(isDiscovering
                                      ? "Discovering..."
                                      : "Join (Discover)"),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _toggleSimulation,
                              icon: const Icon(Icons.bug_report),
                              label: const Text("Test Mode (Simulate)"),
                            ),
                            if (isAdvertising || isDiscovering)
                              TextButton(
                                onPressed: _stopAll,
                                child: const Text("Stop Searching/Advertising"),
                              )
                          ] else
                            ElevatedButton.icon(
                              onPressed: _disconnect,
                              icon: const Icon(Icons.close),
                              label: Text(isSimulating
                                  ? "Exit Simulation"
                                  : "Disconnect"),
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  foregroundColor: Colors.white),
                            ),
                        ],
                      ),
                    ),
                  ),

                  const Divider(height: 32),

                  // Control Section
                  Expanded(
                    child: connectedEndpointId == null && !isSimulating
                        ? const Center(
                            child: Text("Connect to another device to start."))
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_myState == ButtonState.green)
                                const Text("MATCH FOUND!",
                                    style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green))
                              else if (_myState == ButtonState.orange)
                                const Text("Waiting for other device...",
                                    style: TextStyle(
                                        fontSize: 18, color: Colors.orange))
                              else
                                const Text("Tap the button!",
                                    style: TextStyle(fontSize: 18)),
                              const SizedBox(height: 24),
                              _buildMainButton(),
                              if (isSimulating) ...[
                                const Divider(height: 40),
                                const Text("Debug: Simulate Remote Actions",
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    ElevatedButton(
                                      onPressed: () =>
                                          _simulateReceive("PRESSED"),
                                      child: const Text("Simulate 'PRESSED'"),
                                    ),
                                    ElevatedButton(
                                      onPressed: () =>
                                          _simulateReceive("RESET"),
                                      child: const Text("Simulate 'RESET'"),
                                    ),
                                  ],
                                )
                              ]
                            ],
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildMainButton() {
    Color color;
    String text;

    switch (_myState) {
      case ButtonState.red:
        color = Colors.red;
        text = "PRESS ME";
        break;
      case ButtonState.orange:
        color = Colors.orange;
        text = "WAITING...";
        break;
      case ButtonState.green:
        color = Colors.green;
        text = "MATCHED!";
        break;
    }

    return SizedBox(
      width: 200,
      height: 200,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          elevation: 10,
        ),
        onPressed: _handleButtonClick,
        child: Text(text,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _handleButtonClick() {
    if (connectedEndpointId == null && !isSimulating) return;

    if (_myState == ButtonState.red) {
      // I am pressing the button
      if (_peerHasPressed) {
        // The other person already pressed! Match!
        setState(() {
          _myState = ButtonState.green;
        });
        _sendMessage("PRESSED"); // Tell them I pressed (so they go green)
        _showMatchNotification();
      } else {
        // First to press
        setState(() {
          _myState = ButtonState.orange;
        });
        _sendMessage("PRESSED"); // Tell them I pressed (so they know)
      }
    } else if (_myState == ButtonState.green) {
      // Already matched, maybe do nothing or reset?
      // User didn't specify.
    } else if (_myState == ButtonState.orange) {
      // Already waiting. Do nothing.
    }
  }

  void _resetGame() {
    setState(() {
      _myState = ButtonState.red;
      _peerHasPressed = false;
    });
    _sendMessage("RESET");
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
      _peerHasPressed = false;
    });
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
    if (isSimulating) {
      setState(() {
        isSimulating = false;
        connectionStatus = "Disconnected";
        _myState = ButtonState.red;
        _peerHasPressed = false;
      });
      return;
    }
    if (connectedEndpointId != null) {
      await Nearby().disconnectFromEndpoint(connectedEndpointId!);
      setState(() {
        connectedEndpointId = null;
        connectionStatus = "Disconnected";
        _myState = ButtonState.red;
        _peerHasPressed = false;
      });
    }
  }

  void _toggleSimulation() {
    setState(() {
      isSimulating = true;
      connectionStatus = "Connected (Simulated)";
    });
  }

  // Send & Receive Logic

  void _sendMessage(String message) async {
    if (isSimulating) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Simulated Sending: $message"),
            backgroundColor: Colors.grey,
            duration: const Duration(milliseconds: 500)),
      );
      return;
    }

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

  void _simulateReceive(String message) {
    // Create a fake payload to reuse the logic
    final payload = Payload(
        type: PayloadType.BYTES,
        bytes: Uint8List.fromList(utf8.encode(message)),
        id: 0);
    _onPayloadReceived("simulated_id", payload);
  }

  void _onPayloadReceived(String id, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      String message = utf8.decode(payload.bytes!);
      debugPrint("Received message: $message");

      if (message == "PRESSED") {
        setState(() {
          _peerHasPressed = true;
          if (_myState == ButtonState.orange) {
            // We were waiting, and they pressed! Match!
            _myState = ButtonState.green;
            _showMatchNotification();
          }
          // If I am Red, I stay Red, but now I know they pressed.
        });
      } else if (message == "RESET") {
        setState(() {
          _myState = ButtonState.red;
          _peerHasPressed = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Game Reset by peer")),
        );
      }
    }
  }
}
