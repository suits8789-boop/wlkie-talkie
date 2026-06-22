import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'sound_effects.dart';
import 'webrtc_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set system navigation colors
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Color(0xFF0A0C10),
    statusBarColor: Colors.transparent,
  ));

  // Initialize sound synthesizer
  await SoundEffects.init();

  runApp(const WalkieTalkieApp());
}

class WalkieTalkieApp extends StatelessWidget {
  const WalkieTalkieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wi-Fi Walkie Talkie',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0C10),
        primarySwatch: Colors.cyan,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F0FF),
          secondary: Color(0xFF00FF88),
          surface: Color(0xFF121620),
          error: Color(0xFFFF0055),
        ),
        fontFamily: 'monospace',
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  final WebRTCClient _client = WebRTCClient();
  bool _isConnected = false;
  bool _isLoading = false;

  final TextEditingController _serverController = TextEditingController(text: WebRTCClient.defaultServerUrl);
  final TextEditingController _roomController = TextEditingController(text: "General");
  final TextEditingController _usernameController = TextEditingController();

  final List<Map<String, String>> _logs = [];
  final ScrollController _scrollController = ScrollController();
  
  LcdState _lcdState = LcdState.standby;
  String _lcdArg = "";
  bool _continuousLock = false;

  // Animation controller for the wave visualizer
  late AnimationController _waveController;

  final List<String> _callsigns = [
    'Viper', 'Nomad', 'Spectre', 'Phoenix', 'Outlaw', 'Ranger',
    'Bravo', 'Shadow', 'Falcon', 'Ghost', 'Tango', 'Sierra',
    'Titan', 'Hunter', 'Echo', 'Apex', 'Razor', 'Cobra'
  ];

  @override
  void initState() {
    super.initState();
    _generateRandomUsername();
    
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();

    // Bind WebRTCClient callbacks to state
    _client.onPeersChanged = () {
      if (mounted) setState(() {});
    };

    _client.onLog = (msg, type) {
      if (mounted) {
        setState(() {
          _logs.add({'msg': msg, 'type': type});
        });
        // Auto scroll to bottom
        Timer(const Duration(milliseconds: 100), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    };

    _client.onLcdChanged = (state, arg) {
      if (mounted) {
        setState(() {
          _lcdState = state;
          _lcdArg = arg;
        });
      }
    };
  }

  @override
  void dispose() {
    _waveController.dispose();
    _client.disconnect();
    _serverController.dispose();
    _roomController.dispose();
    _usernameController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _generateRandomUsername() {
    final rand = Random();
    final name = _callsigns[rand.nextInt(_callsigns.length)];
    final num = rand.nextInt(90) + 10;
    _usernameController.text = "$name-$num";
  }

  Future<void> _connect() async {
    final server = _serverController.text.trim();
    final room = _roomController.text.trim();
    final user = _usernameController.text.trim();

    if (server.isEmpty || room.isEmpty || user.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all lobby fields.')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Check microphone permissions first
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
        if (!status.isGranted) {
          throw Exception("Microphone permission denied.");
        }
      }

      await _client.connect(
        serverUrl: server,
        username: user,
        roomName: room,
      );

      setState(() {
        _isConnected = true;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Connection Failed"),
          content: Text("Could not connect to the walkie talkie server.\n\nError: $e\n\nEnsure the Node server is running and accessible over your Wi-Fi network."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("OK"),
            )
          ],
        ),
      );
    }
  }

  void _disconnect() {
    _client.disconnect();
    setState(() {
      _isConnected = false;
      _logs.clear();
      _continuousLock = false;
    });
  }

  // ==========================================
  // WIDGET BUILDERS
  // ==========================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background decoration
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF00F0FF).withOpacity(0.04),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            right: -100,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF9D4EDD).withOpacity(0.03),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _isConnected ? _buildWalkieTalkieView() : _buildLobbyView(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLobbyView() {
    return Center(
      child: SingleChildScrollView(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF121620).withOpacity(0.6),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Logo
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFF00F0FF).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF00F0FF).withOpacity(0.5)),
                ),
                child: const Icon(Icons.mic, size: 36, color: Color(0xFF00F0FF)),
              ),
              const SizedBox(height: 16),
              const Text(
                'WIFI TALKIE',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                  color: Colors.white,
                ),
              ),
              const Text(
                'Real-time Local Voice Mesh',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 24),
              
              // Inputs
              TextField(
                controller: _serverController,
                decoration: const InputDecoration(
                  labelText: "SERVER IP / URL",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.dns, size: 20),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _usernameController,
                      maxLength: 15,
                      decoration: const InputDecoration(
                        labelText: "CALLSIGN / USERNAME",
                        border: OutlineInputBorder(),
                        counterText: "",
                        prefixIcon: Icon(Icons.person, size: 20),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    onPressed: _generateRandomUsername,
                    icon: const Icon(Icons.refresh),
                    tooltip: "Randomize",
                  )
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _roomController,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: "CHANNEL NAME",
                  border: OutlineInputBorder(),
                  counterText: "",
                  prefixIcon: Icon(Icons.chat_bubble, size: 20),
                ),
              ),
              const SizedBox(height: 24),
              
              // Submit
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00F0FF),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isLoading 
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                      )
                    : const Text(
                        'CONNECT CHANNEL',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWalkieTalkieView() {
    return Column(
      children: [
        // Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ElevatedButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.exit_to_app, size: 16),
              label: const Text('Exit'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF0055).withOpacity(0.1),
                foregroundColor: const Color(0xFFFF0055),
                elevation: 0,
                side: BorderSide(color: const Color(0xFFFF0055).withOpacity(0.3)),
              ),
            ),
            Column(
              children: [
                const Text('CHANNEL', style: TextStyle(color: Colors.grey, fontSize: 10)),
                Text(
                  _roomController.text.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF00F0FF),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Row(
                children: [
                  Text(_usernameController.text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00FF88),
                      shape: BoxShape.circle,
                    ),
                  )
                ],
              ),
            )
          ],
        ),
        const SizedBox(height: 20),
        
        // Layout: Device Casing on top, Stats/Logs on bottom
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final isVertical = constraints.maxHeight > 500;
              
              if (isVertical) {
                return Column(
                  children: [
                    _buildDevicePanel(),
                    const SizedBox(height: 16),
                    Expanded(child: _buildInfoPanel()),
                  ],
                );
              } else {
                return Row(
                  children: [
                    Expanded(flex: 6, child: _buildDevicePanel()),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: _buildInfoPanel()),
                  ],
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDevicePanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10121A).withOpacity(0.55),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // LCD Screen
          _buildLcdDisplay(),
          const SizedBox(height: 20),
          
          // Walkie Talkie Outer Frame
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1E2330), Color(0xFF0E1119)],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF282F3D)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 15,
                  offset: const Offset(0, 8),
                )
              ]
            ),
            child: Column(
              children: [
                // Grille lines
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) => 
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: 25,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                
                // PTT Button
                GestureDetector(
                  onTapDown: (_) {
                    if (!_continuousLock) _client.startTransmission();
                  },
                  onTapUp: (_) {
                    if (!_continuousLock) _client.stopTransmission();
                  },
                  onTapCancel: () {
                    if (!_continuousLock) _client.stopTransmission();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: _lcdState == LcdState.transmitting
                          ? [const Color(0xFFFF0055), const Color(0xFFB3003B)]
                          : [const Color(0xFF2C3547), const Color(0xFF1A202B)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _lcdState == LcdState.transmitting
                            ? const Color(0xFFFF0055).withOpacity(0.4)
                            : Colors.black.withOpacity(0.5),
                          blurRadius: _lcdState == LcdState.transmitting ? 20 : 10,
                          spreadRadius: _lcdState == LcdState.transmitting ? 3 : 1,
                        )
                      ],
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.mic, 
                            size: 32, 
                            color: _lcdState == LcdState.transmitting ? Colors.white : Colors.grey[400]
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _lcdState == LcdState.transmitting ? 'TRANSMITTING' : 'HOLD TO TALK',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: _lcdState == LcdState.transmitting ? Colors.white : Colors.grey[400],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Continuous Lock Toggle
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Continuous stream (Lock mic)', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    Switch(
                      value: _continuousLock,
                      onChanged: (val) {
                        setState(() {
                          _continuousLock = val;
                        });
                        if (_continuousLock) {
                          _client.startTransmission();
                        } else {
                          _client.stopTransmission();
                        }
                      },
                      activeColor: const Color(0xFFFF0055),
                      activeTrackColor: const Color(0xFFFF0055).withOpacity(0.3),
                    )
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLcdDisplay() {
    Color lcdColor = const Color(0xFF00FF88);
    String status = "STANDBY";
    String subStatus = "READY TO RECEIVE";
    
    if (_lcdState == LcdState.transmitting) {
      lcdColor = const Color(0xFFFF0055);
      status = "TX ACTIVE";
      subStatus = "BROADCASTING...";
    } else if (_lcdState == LcdState.receiving) {
      lcdColor = const Color(0xFF00F0FF);
      status = "RX ACTIVE";
      subStatus = "FROM: ${_lcdArg.toUpperCase()}";
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1C1E),
        border: Border.all(color: const Color(0xFF1F2A30), width: 3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header of LCD
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _lcdState == LcdState.transmitting ? 'TX' : 'RX',
                style: TextStyle(
                  color: _lcdState == LcdState.standby ? Colors.grey[800] : lcdColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
              ),
              const Text('CH-01', style: TextStyle(color: Colors.cyan, fontSize: 10)),
              // Signal Bars
              Row(
                children: List.generate(5, (index) => 
                  Container(
                    margin: const EdgeInsets.only(left: 1.5),
                    width: 2.5,
                    height: (index + 1) * 3,
                    color: _lcdState == LcdState.standby && index >= 3
                      ? Colors.grey[800]
                      : lcdColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Main status
          Center(
            child: Column(
              children: [
                Text(
                  status,
                  style: TextStyle(
                    color: lcdColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  subStatus,
                  style: const TextStyle(color: Colors.grey, fontSize: 9),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          
          // Oscilloscope Wave Visualizer
          SizedBox(
            height: 32,
            width: double.infinity,
            child: CustomPaint(
              painter: OscilloscopePainter(
                animationValue: _waveController.value,
                state: _lcdState,
                color: lcdColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoPanel() {
    return Column(
      children: [
        // Peers Card
        Expanded(
          flex: 4,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF10121A).withOpacity(0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.people, size: 14, color: Colors.grey),
                    const SizedBox(width: 6),
                    Text(
                      'ONLINE PEERS (${_client.peers.length})', 
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)
                    ),
                  ],
                ),
                const Divider(height: 12, color: Colors.white10),
                Expanded(
                  child: _client.peers.isEmpty
                    ? const Center(child: Text('No other operators in channel', style: TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic)))
                    : ListView.builder(
                        itemCount: _client.peers.length,
                        itemBuilder: (ctx, index) {
                          final peer = _client.peers.values.elementAt(index);
                          Color statusColor = Colors.grey;
                          String statusText = "OFFLINE";
                          
                          if (peer.connectionState == 'listening') {
                            statusColor = const Color(0xFF00FF88);
                            statusText = "LISTENING";
                          } else if (peer.connectionState == 'speaking') {
                            statusColor = const Color(0xFFFF0055);
                            statusText = "SPEAKING";
                          } else if (peer.connectionState == 'connecting') {
                            statusColor = const Color(0xFFFFAA00);
                            statusText = "CONNECTING";
                          }
                          
                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.01),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: peer.connectionState == 'speaking'
                                  ? const Color(0xFFFF0055).withOpacity(0.2)
                                  : Colors.white.withOpacity(0.02),
                              )
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(6),
                                        gradient: LinearGradient(
                                          colors: [Colors.cyan.withOpacity(0.2), Colors.purple.withOpacity(0.2)],
                                        ),
                                      ),
                                      child: Center(
                                        child: Text(
                                          peer.username.substring(0, min(peer.username.length, 2)).toUpperCase(),
                                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF00F0FF)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(peer.username, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                                Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(statusText, style: TextStyle(fontSize: 10, color: statusColor, fontWeight: FontWeight.bold)),
                                  ],
                                )
                              ],
                            ),
                          );
                        },
                      ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        
        // Logs Card
        Expanded(
          flex: 3,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF06080C),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_note, size: 14, color: Colors.grey[600]),
                    const SizedBox(width: 6),
                    const Text('SYSTEM LOGS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                  ],
                ),
                const Divider(height: 12, color: Colors.white10),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: _logs.length,
                    itemBuilder: (ctx, index) {
                      final log = _logs[index];
                      Color logColor = Colors.grey;
                      
                      if (log['type'] == 'join') logColor = const Color(0xFF00FF88);
                      if (log['type'] == 'leave' || log['type'] == 'error') logColor = const Color(0xFFFF0055);
                      if (log['type'] == 'rx') logColor = const Color(0xFF00F0FF);
                      
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4.0),
                        child: Text(
                          log['msg'] ?? "",
                          style: TextStyle(color: logColor, fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// Custom Painter to draw the glowing digital oscilloscope waves
class OscilloscopePainter extends CustomPainter {
  final double animationValue;
  final LcdState state;
  final Color color;

  OscilloscopePainter({
    required this.animationValue,
    required this.state,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    final halfHeight = size.height / 2;
    final width = size.width;
    final rand = Random();

    if (state == LcdState.standby) {
      // Flat line with micro buzz
      path.moveTo(0, halfHeight);
      for (double x = 0; x <= width; x += 15) {
        final buzz = (rand.nextDouble() - 0.5) * 1.2;
        path.lineTo(x, halfHeight + buzz);
      }
    } else {
      // Active wave (sine-wave combination)
      path.moveTo(0, halfHeight);
      double freq = state == LcdState.transmitting ? 4 : 5.5;
      double amp = state == LcdState.transmitting ? 8 : 10;
      
      for (double x = 0; x <= width; x += 2) {
        final angle = (x / width) * 2 * pi * freq + (animationValue * 2 * pi);
        // Combine two frequencies for realistic voice shape
        final y = halfHeight + 
                  sin(angle) * amp + 
                  sin(angle * 2.3) * (amp / 3.0);
        path.lineTo(x, y);
      }
    }

    // Draw shadow blur/glow
    final shadowPaint = Paint()
      ..color = color.withOpacity(0.35)
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    
    canvas.drawPath(path, shadowPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant OscilloscopePainter oldDelegate) {
    return oldDelegate.animationValue != animationValue || 
           oldDelegate.state != state;
  }
}
