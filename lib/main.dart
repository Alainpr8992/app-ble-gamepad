import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:gamepads/gamepads.dart';

const String serviceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
const String characteristicRxUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";

void main() {
  runApp(const RobotFutbolApp());
}

class RobotFutbolApp extends StatelessWidget {
  const RobotFutbolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UPIIH Robot-Fútbol Universal',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF0EA5E9),
          secondary: Color(0xFF10B981),
        ),
      ),
      home: const BridgeDashboard(),
    );
  }
}

class BridgeDashboard extends StatefulWidget {
  const BridgeDashboard({super.key});

  @override
  State<BridgeDashboard> createState() => _BridgeDashboardState();
}

class _BridgeDashboardState extends State<BridgeDashboard> {
  // 6 EJES ANALÓGICOS DEL CONTROL (100% CAPTURADOS)
  double lx = 0.0;
  double ly = 0.0;
  double rx = 0.0;
  double ry = 0.0;
  double lt = 0.0;
  double rt = 0.0;

  // CONJUNTO DE TODOS LOS BOTONES ACTIVOS SIMULTÁNEAMENTE
  final Set<String> activeButtons = {};

  StreamSubscription<GamepadEvent>? _gamepadSubscription;

  BluetoothDevice? connectedEsp32;
  BluetoothCharacteristic? rxCharacteristic;
  List<ScanResult> scanResults = [];
  bool isScanning = false;
  String espStatus = "Desconectado";

  Timer? _telemetryTimer;
  final FocusNode _gamepadFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _initGamepadListener();
    _startTelemetryLoop();
  }

  @override
  void dispose() {
    _gamepadSubscription?.cancel();
    _telemetryTimer?.cancel();
    _gamepadFocusNode.dispose();
    connectedEsp32?.disconnect();
    super.dispose();
  }

  // TRADUCTOR UNIVERSAL DE BOTONES
  String _parseKeyName(LogicalKeyboardKey key) {
    String name = key.debugName ?? key.keyLabel;
    String upper = name.toUpperCase();

    if (upper.contains("BUTTON A")) return "A";
    if (upper.contains("BUTTON B")) return "B";
    if (upper.contains("BUTTON X")) return "X";
    if (upper.contains("BUTTON Y")) return "Y";

    if (upper.contains("LEFT 1") || upper.contains("L1")) return "LB";
    if (upper.contains("RIGHT 1") || upper.contains("R1")) return "RB";
    if (upper.contains("LEFT 2") || upper.contains("L2")) return "LT";
    if (upper.contains("RIGHT 2") || upper.contains("R2")) return "RT";

    if (upper.contains("THUMB LEFT") || upper.contains("THUMB L")) return "L3";
    if (upper.contains("THUMB RIGHT") || upper.contains("THUMB R")) return "R3";

    if (upper.contains("START")) return "START";
    if (upper.contains("SELECT") || upper.contains("BACK")) return "SELECT";
    if (upper.contains("MODE") || upper.contains("HOME")) return "HOME";

    if (upper.contains("ARROW UP") || upper == "UP") return "DPAD_ARRIBA";
    if (upper.contains("ARROW DOWN") || upper == "DOWN") return "DPAD_ABAJO";
    if (upper.contains("ARROW LEFT") || upper == "LEFT")
      return "DPAD_IZQUIERDA";
    if (upper.contains("ARROW RIGHT") || upper == "RIGHT")
      return "DPAD_DERECHA";

    return upper.replaceAll("GAME BUTTON ", "").replaceAll("KEY ", "").trim();
  }

  // CAPTURA NATIVA DE TECLADO / D-PAD
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final keyName = _parseKeyName(event.logicalKey);

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      setState(() {
        activeButtons.add(keyName);

        // Control por cruceta como respaldo
        if (keyName == "DPAD_ARRIBA") ly = 1.0;
        if (keyName == "DPAD_ABAJO") ly = -1.0;
        if (keyName == "DPAD_IZQUIERDA") lx = -1.0;
        if (keyName == "DPAD_DERECHA") lx = 1.0;
      });
      return KeyEventResult.handled;
    } else if (event is KeyUpEvent) {
      setState(() {
        activeButtons.remove(keyName);
        if (keyName.startsWith("DPAD")) {
          lx = 0.0;
          ly = 0.0;
        }
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // CAPTURA DE TODOS LOS EJES ANALÓGICOS (PLUGIN GAMEPADS)
  void _initGamepadListener() {
    _gamepadSubscription = Gamepads.events.listen((event) {
      setState(() {
        final k = event.key.toLowerCase();
        final v = event.value;

        // Stick Izquierdo
        if (k == 'stick_left_x' || k == 'axis_0') lx = v;
        if (k == 'stick_left_y' || k == 'axis_1') ly = -v;

        // Stick Derecho
        if (k == 'stick_right_x' || k == 'axis_2' || k == 'axis_z') rx = v;
        if (k == 'stick_right_y' || k == 'axis_3' || k == 'axis_rz') ry = -v;

        // Gatillos analógicos (0.0 a 1.0)
        if (k == 'trigger_left' || k == 'axis_4' || k == 'brake')
          lt = v.clamp(0.0, 1.0);
        if (k == 'trigger_right' || k == 'axis_5' || k == 'throttle')
          rt = v.clamp(0.0, 1.0);

        // Botones del plugin
        if (k.startsWith('button_')) {
          String btn = k.toUpperCase().replaceAll('BUTTON_', '');
          if (v > 0.5) {
            activeButtons.add(btn);
          } else {
            activeButtons.remove(btn);
          }
        }
      });
    });
  }

  // TRANSMISIÓN TELEMÉTRICA 100% COMPLETA (30 HZ)
  void _startTelemetryLoop() {
    _telemetryTimer = Timer.periodic(const Duration(milliseconds: 35), (timer) {
      if (rxCharacteristic != null && connectedEsp32 != null) {
        // Conversión de ejes a escala entera estándar (-255 a +255)
        int iLx = (lx * 255).toInt().clamp(-255, 255);
        int iLy = (ly * 255).toInt().clamp(-255, 255);
        int iRx = (rx * 255).toInt().clamp(-255, 255);
        int iRy = (ry * 255).toInt().clamp(-255, 255);

        // Gatillos de 0 a 255
        int iLt = (lt * 255).toInt().clamp(0, 255);
        int iRt = (rt * 255).toInt().clamp(0, 255);

        // Zona muerta
        if (iLx.abs() < 25) iLx = 0;
        if (iLy.abs() < 25) iLy = 0;
        if (iRx.abs() < 25) iRx = 0;
        if (iRy.abs() < 25) iRy = 0;

        // Lista de botones activos separados por '+' (ej: "A+RB")
        String btnPayload =
            activeButtons.isEmpty ? "NONE" : activeButtons.join("+");

        // TRAMA UNIVERSAL TOTAL
        String payload = "$iLx,$iLy,$iRx,$iRy,$iLt,$iRt,$btnPayload\n";

        try {
          rxCharacteristic!.write(utf8.encode(payload), withoutResponse: true);
        } catch (_) {}
      }
    });
  }

  void _startBleScan() async {
    setState(() {
      scanResults.clear();
      isScanning = true;
    });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        scanResults =
            results.where((r) => r.device.platformName.isNotEmpty).toList();
      });
    });

    await Future.delayed(const Duration(seconds: 4));
    setState(() {
      isScanning = false;
    });
  }

  void _connectToEsp32(BluetoothDevice device) async {
    setState(() {
      espStatus = "Conectando...";
    });

    await device.connect(autoConnect: false);

    List<BluetoothService> services = await device.discoverServices();
    for (var service in services) {
      if (service.uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
        for (var charac in service.characteristics) {
          if (charac.uuid.toString().toLowerCase() ==
              characteristicRxUuid.toLowerCase()) {
            rxCharacteristic = charac;
          }
        }
      }
    }

    setState(() {
      connectedEsp32 = device;
      espStatus = "CONECTADO A ${device.platformName}";
    });
  }

  void _disconnectEsp32() async {
    await connectedEsp32?.disconnect();
    setState(() {
      connectedEsp32 = null;
      rxCharacteristic = null;
      espStatus = "Desconectado";
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _gamepadFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('UPIIH Gamepad Gateway 100%'),
          centerTitle: true,
          backgroundColor: const Color(0xFF1E293B),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ESTADO
              _buildCard(
                title: "ESTADO DEL ROBOT",
                icon: Icons.memory,
                color: connectedEsp32 != null
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Estado: $espStatus",
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          focusNode: FocusNode(canRequestFocus: false),
                          onPressed: isScanning ? null : _startBleScan,
                          icon: const Icon(Icons.search),
                          label: Text(
                              isScanning ? "Buscando..." : "Buscar Robots"),
                        ),
                        const SizedBox(width: 10),
                        if (connectedEsp32 != null)
                          OutlinedButton(
                            focusNode: FocusNode(canRequestFocus: false),
                            onPressed: _disconnectEsp32,
                            child: const Text("Desconectar"),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // LISTA DE ROBOTS DISPONIBLES
              if (scanResults.isNotEmpty && connectedEsp32 == null) ...[
                const Text("ROBOTS DETECTADOS:",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: scanResults.length,
                  itemBuilder: (context, index) {
                    final dev = scanResults[index].device;
                    return Card(
                      color: const Color(0xFF1E293B),
                      child: ListTile(
                        title: Text(dev.platformName),
                        subtitle: Text("MAC: ${dev.remoteId.str}"),
                        trailing: ElevatedButton(
                          focusNode: FocusNode(canRequestFocus: false),
                          onPressed: () => _connectToEsp32(dev),
                          child: const Text("Vincular"),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 14),
              ],

              // RECONOCIMIENTO DE TODOS LOS BOTONES
              _buildCard(
                title: "BOTONES PULSADOS SIMULTÁNEAMENTE",
                icon: Icons.sports_esports,
                color: Colors.greenAccent,
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "ACTIVOS: ${activeButtons.isEmpty ? 'NINGUNO' : activeButtons.join(' + ')}",
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.yellowAccent),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _buttonBadge("A"),
                        _buttonBadge("B"),
                        _buttonBadge("X"),
                        _buttonBadge("Y"),
                        _buttonBadge("LB"),
                        _buttonBadge("RB"),
                        _buttonBadge("LT"),
                        _buttonBadge("RT"),
                        _buttonBadge("L3"),
                        _buttonBadge("R3"),
                        _buttonBadge("START"),
                        _buttonBadge("SELECT"),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // TELEMETRÍA COMPLETA (6 EJES)
              _buildCard(
                title: "TELEMETRÍA COMPLETA (6 EJES)",
                icon: Icons.speed,
                color: Colors.cyanAccent,
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        "Stick Izq:  LX: ${(lx * 255).toInt()} | LY: ${(ly * 255).toInt()}",
                        style: const TextStyle(fontFamily: 'monospace')),
                    Text(
                        "Stick Der:  RX: ${(rx * 255).toInt()} | RY: ${(ry * 255).toInt()}",
                        style: const TextStyle(fontFamily: 'monospace')),
                    Text(
                        "Gatillos:   LT: ${(lt * 255).toInt()} | RT: ${(rt * 255).toInt()}",
                        style: const TextStyle(fontFamily: 'monospace')),
                    const SizedBox(height: 8),
                    Text(
                      "Trama BLE: [ ${(lx * 255).toInt()},${(ly * 255).toInt()},${(rx * 255).toInt()},${(ry * 255).toInt()},${(lt * 255).toInt()},${(rt * 255).toInt()},${activeButtons.isEmpty ? 'NONE' : activeButtons.join('+')} ]",
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buttonBadge(String name) {
    bool isPressed = activeButtons.contains(name);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isPressed ? Colors.greenAccent : const Color(0xFF334155),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: isPressed ? Colors.green : Colors.transparent),
      ),
      child: Text(
        name,
        style: TextStyle(
          color: isPressed ? Colors.black : Colors.white70,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildCard(
      {required String title,
      required IconData icon,
      required Color color,
      required Widget content}) {
    return Card(
      color: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withAlpha(100)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ],
            ),
            const Divider(color: Colors.white24, height: 16),
            content,
          ],
        ),
      ),
    );
  }
}
