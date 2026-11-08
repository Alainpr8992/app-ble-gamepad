import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:gamepads/gamepads.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    home: RobotFutbolGateway(),
    debugShowCheckedModeBanner: false,
  ));
}

class RobotFutbolGateway extends StatefulWidget {
  const RobotFutbolGateway({super.key});

  @override
  State<RobotFutbolGateway> createState() => _RobotFutbolGatewayState();
}

class _RobotFutbolGatewayState extends State<RobotFutbolGateway> {
  // UUIDs oficiales Nordic UART Service (NUS)
  final String serviceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  final String rxUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";

  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? rxCharacteristic;
  bool isConnected = false;
  bool isScanning = false;

  // Telemetría Joysticks (-100 a 100)
  int _lx = 0, _ly = 0, _rx = 0, _ry = 0;
  
  // Conjunto de botones activos (digitales)
  final Set<String> activeButtons = <String>{};

  StreamSubscription? _gamepadSub;
  Timer? _telemetryTimer;
  String _lastSentFrame = "Esperando conexión...";

  @override
  void initState() {
    super.initState();
    _initGamepadListener();
    // Bucle de telemetría constante a 30 Hz (cada 33 ms) hacia el ESP32
    _telemetryTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _sendTelemetry();
    });
  }

  @override
  void dispose() {
    _gamepadSub?.cancel();
    _telemetryTimer?.cancel();
    targetDevice?.disconnect();
    super.dispose();
  }

  // Escucha del plugin gamepads para ejes de sticks y gatillos
  void _initGamepadListener() {
    _gamepadSub = Gamepads.events.listen((event) {
      final key = event.key.toLowerCase();
      final val = event.value;

      setState(() {
        // --- JOYSTICKS ---
        if (key.contains('x') && !key.contains('rx')) {
          _lx = (val * 100).clamp(-100.0, 100.0).round();
        } else if (key.contains('y') && !key.contains('ry')) {
          _ly = (val * 100).clamp(-100.0, 100.0).round();
        } else if (key.contains('rx') || key.contains('z') && !key.contains('rz')) {
          _rx = (val * 100).clamp(-100.0, 100.0).round();
        } else if (key.contains('ry') || key.contains('rz')) {
          _ry = (val * 100).clamp(-100.0, 100.0).round();
        }

        // --- GATILLOS COMO BOTONES DIGITALES POR EJE O NOMBRE ---
        // Gatillo Izquierdo (LT / L2 / Brake / Axis 17 o 23)
        if (key.contains('brake') || key.contains('ltrigger') || key == '17' || key == '23' || key.contains('trigger_l')) {
          if (val > 0.25) {
            activeButtons.add("LT");
          } else {
            activeButtons.remove("LT");
          }
        }
        // Gatillo Derecho (RT / R2 / Gas / Axis 18 o 22)
        if (key.contains('gas') || key.contains('rtrigger') || key == '18' || key == '22' || key.contains('trigger_r')) {
          if (val > 0.25) {
            activeButtons.add("RT");
          } else {
            activeButtons.remove("RT");
          }
        }

        // Si el plugin reporta L2/R2 como botones digitales
        if (key.contains('l2') || key == 'button_l2' || key == 'lt') {
          if (val > 0.5) {
            activeButtons.add("LT");
          } else {
            activeButtons.remove("LT");
          }
        }
        if (key.contains('r2') || key == 'button_r2' || key == 'rt') {
          if (val > 0.5) {
            activeButtons.add("RT");
          } else {
            activeButtons.remove("RT");
          }
        }
      });
    });
  }

  // Intercepción global de botones físicos de Android (KeyCodes)
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final isDown = event is KeyDownEvent || event is KeyRepeatEvent;
    final name = (event.logicalKey.debugName ?? '').toLowerCase();
    final label = event.logicalKey.keyLabel.toLowerCase();
    final id = event.logicalKey.keyId;

    String? btn;

    // Botones de acción
    if (name.contains('button a') || label == 'a') { btn = "A"; }
    else if (name.contains('button b') || label == 'b') { btn = "B"; }
    else if (name.contains('button x') || label == 'x') { btn = "X"; }
    else if (name.contains('button y') || label == 'y') { btn = "Y"; }
    // Bumpers
    else if (name.contains('l1') || name.contains('bumper_l') || name.contains('left bumper')) { btn = "LB"; }
    else if (name.contains('r1') || name.contains('bumper_r') || name.contains('right bumper')) { btn = "RB"; }
    // Gatillos físicos por KeyCode (104 = L2, 105 = R2) o nombres
    else if (name.contains('l2') || label.contains('l2') || name.contains('trigger_l') || id == 104 || id == 0x100000068) {
      btn = "LT";
    }
    else if (name.contains('r2') || label.contains('r2') || name.contains('trigger_r') || id == 105 || id == 0x100000069) {
      btn = "RT";
    }
    // D-Pad (Cruceta)
    else if (name.contains('dpad up') || name.contains('arrow up')) { btn = "D_UP"; }
    else if (name.contains('dpad down') || name.contains('arrow down')) { btn = "D_DOWN"; }
    else if (name.contains('dpad left') || name.contains('arrow left')) { btn = "D_LEFT"; }
    else if (name.contains('dpad right') || name.contains('arrow right')) { btn = "D_RIGHT"; }
    // Sticks clickeables
    else if (name.contains('thumbl') || name.contains('thumb left')) { btn = "THUMB_L"; }
    else if (name.contains('thumbr') || name.contains('thumb right')) { btn = "THUMB_R"; }
    // Start / Select
    else if (name.contains('start') || name.contains('menu')) { btn = "START"; }
    else if (name.contains('select') || name.contains('back')) { btn = "SELECT"; }

    if (btn != null) {
      setState(() {
        if (isDown) {
          activeButtons.add(btn!);
        } else {
          activeButtons.remove(btn);
        }
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Envío BLE con formato: LX,LY,RX,RY,LT,RT,BOTONES\n
  Future<void> _sendTelemetry() async {
    if (rxCharacteristic == null || !isConnected) return;

    final ltVal = activeButtons.contains("LT") ? 1 : 0;
    final rtVal = activeButtons.contains("RT") ? 1 : 0;
    final btnPayload = activeButtons.isEmpty ? "NONE" : activeButtons.join("+");

    final frame = "$_lx,$_ly,$_rx,$_ry,$ltVal,$rtVal,$btnPayload\n";

    try {
      await rxCharacteristic!.write(utf8.encode(frame), withoutResponse: true);
      setState(() {
        _lastSentFrame = frame.trim();
      });
    } catch (_) {}
  }

  // Conexión BLE al robot
  Future<void> _scanAndConnect() async {
    setState(() => isScanning = true);

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.platformName.contains("ROBOT_FUTBOL") || r.device.advName.contains("ROBOT_FUTBOL")) {
          await FlutterBluePlus.stopScan();
          setState(() {
            targetDevice = r.device;
            isScanning = false;
          });

          await targetDevice!.connect(autoConnect: false);
          List<BluetoothService> services = await targetDevice!.discoverServices();
          for (var s in services) {
            if (s.uuid.toString().toLowerCase() == serviceUuid) {
              for (var c in s.characteristics) {
                if (c.uuid.toString().toLowerCase() == rxUuid) {
                  rxCharacteristic = c;
                  setState(() => isConnected = true);
                  break;
                }
              }
            }
          }
          break;
        }
      }
    });

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && isScanning) {
        setState(() => isScanning = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          title: const Text('UPIIH Robot-Fútbol Gateway', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          backgroundColor: const Color(0xFF7A003C), // Guinda Politécnico
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Icon(
                isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: isConnected ? Colors.greenAccent : Colors.redAccent,
              ),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Barra de conexión
              ElevatedButton.icon(
                focusNode: FocusNode(canRequestFocus: false),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected ? Colors.teal : const Color(0xFF7A003C),
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: isScanning ? null : _scanAndConnect,
                icon: Icon(isScanning ? Icons.sync : Icons.bluetooth_searching),
                label: Text(
                  isConnected
                      ? "CONECTADO A ROBOT"
                      : (isScanning ? "Buscando Robot..." : "BUSCAR Y VINCULAR ROBOT"),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),

              // Monitor de Gatillos Digitales
              Row(
                children: [
                  Expanded(
                    child: _buildTriggerCard("Gatillo LT (Freno)", activeButtons.contains("LT"), Colors.redAccent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTriggerCard("Gatillo RT (Turbo)", activeButtons.contains("RT"), Colors.amberAccent),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Monitor de Joysticks
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Text("L-Stick: X:$_lx Y:$_ly", style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                    Text("R-Stick: X:$_rx Y:$_ry", style: const TextStyle(color: Colors.lightGreenAccent, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Botones presionados
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("BOTONES ACTIVOS:", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: activeButtons.isEmpty
                            ? const Center(child: Text("Presiona botones en el control EasySMX", style: TextStyle(color: Colors.white38)))
                            : Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: activeButtons.map((btn) => Chip(
                                  backgroundColor: btn == "LT" ? Colors.red.shade900 : (btn == "RT" ? Colors.orange.shade900 : const Color(0xFF7A003C)),
                                  label: Text(btn, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                )).toList(),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Trama enviada al ESP32
              Text(
                "Trama BLE: $_lastSentFrame",
                style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTriggerCard(String title, bool isPressed, Color activeColor) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: isPressed ? activeColor.withValues(alpha: 0.25) : const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isPressed ? activeColor : Colors.white24, width: 2),
      ),
      child: Column(
        children: [
          Text(title, style: TextStyle(color: isPressed ? activeColor : Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
            isPressed ? "PRESIONADO" : "LIBRE",
            style: TextStyle(
              color: isPressed ? activeColor : Colors.white38,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}