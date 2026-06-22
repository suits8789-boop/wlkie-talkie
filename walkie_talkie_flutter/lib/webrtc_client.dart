import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'sound_effects.dart';

enum LcdState { standby, transmitting, receiving }

class PeerState {
  final String id;
  final String username;
  String connectionState; // 'connecting', 'listening', 'speaking', 'offline'
  RTCVideoRenderer? renderer; // used to play the peer's audio stream

  PeerState({
    required this.id,
    required this.username,
    required this.connectionState,
    this.renderer,
  });
}

class WebRTCClient {
  IO.Socket? _socket;
  MediaStream? _localStream;
  bool isTransmitting = false;
  bool isReceiving = false;
  String? currentSpeakerName;

  // Configuration for remote signaling server
  // Leave empty to connect to the custom input URL in lobby
  static const String defaultServerUrl = "https://wlkie-talkie.onrender.com";

  final Map<String, PeerState> peers = {};
  
  // Callback functions to notify UI of updates
  void Function()? onPeersChanged;
  void Function(String message, String type)? onLog;
  void Function(LcdState state, String arg)? onLcdChanged;

  final Map<String, RTCPeerConnection> _peerConnections = {};

  final Map<String, dynamic> _iceConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ]
  };

  // Connect to the signaling server and request mic permissions
  Future<void> connect({
    required String serverUrl,
    required String username,
    required String roomName,
  }) async {
    _log("Requesting microphone permission...", "system");

    try {
      // 1. Acquire microphone input stream
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

      // Disable mic initially
      _setMicEnabled(false);
      _log("Microphone access granted.", "system");

      // 2. Initialize Socket.io connection
      _log("Connecting to server at $serverUrl...", "system");
      
      _socket = IO.io(serverUrl, IO.OptionBuilder()
        .setTransports(['websocket']) // Required for flutter socket connections
        .disableAutoConnect()
        .build());

      _socket!.onConnect((_) {
        _log("Connected to signaling server.", "system");
        _socket!.emit('join-room', {
          'roomName': roomName,
          'username': username,
        });
      });

      _socket!.onConnectError((err) {
        _log("Server Connection Error: $err", "error");
      });

      _socket!.onDisconnect((_) {
        _log("Disconnected from server.", "system");
        disconnect();
      });

      // Set up signaling and state handlers
      _setupSocketListeners();
      _socket!.connect();

    } catch (e) {
      _log("Error during connection setup: $e", "error");
      rethrow;
    }
  }

  void _setupSocketListeners() {
    // Receive lists of existing operators in the room on join
    _socket!.on('room-users', (data) async {
      final List users = data as List;
      _log("Joined channel. Operators online: ${users.length}", "system");
      
      for (var user in users) {
        final id = user['id'] as String;
        final name = user['username'] as String;
        _addPeer(id, name);
        await _createPeerConnection(id, name, isInitiator: true);
      }
      onPeersChanged?.call();
    });

    // A new operator joined the room
    _socket!.on('user-joined', (data) async {
      final id = data['id'] as String;
      final name = data['username'] as String;
      _log("[JOIN] $name entered channel.", "join");
      
      _addPeer(id, name);
      onPeersChanged?.call();
      
      // Act as receiver (wait for offer)
      await _createPeerConnection(id, name, isInitiator: false);
    });

    // Relay WebRTC signaling messages
    _socket!.on('signal', (data) async {
      final from = data['from'] as String;
      final signal = data['signal'] as Map;
      final peer = _peerConnections[from];
      if (peer == null) return;

      try {
        if (signal.containsKey('sdp')) {
          final sdpMap = signal['sdp'] as Map;
          final sdp = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
          await peer.setRemoteDescription(sdp);

          if (sdp.type == 'offer') {
            final answer = await peer.createAnswer();
            await peer.setLocalDescription(answer);
            _socket!.emit('signal', {
              'to': from,
              'signal': {'sdp': answer.toMap()}
            });
          }
        } else if (signal.containsKey('candidate')) {
          final candMap = signal['candidate'] as Map;
          final candidate = RTCIceCandidate(
            candMap['candidate'],
            candMap['sdpMid'],
            candMap['sdpMLineIndex'],
          );
          await peer.addCandidate(candidate);
        }
      } catch (e) {
        print("Error processing signal: $e");
      }
    });

    // Receive peer speaking state transitions
    _socket!.on('user-speaking', (data) {
      final id = data['id'] as String;
      final name = data['username'] as String;
      final isSpeaking = data['isSpeaking'] as bool;

      _updatePeerSpeakingState(id, isSpeaking);

      if (isSpeaking) {
        _log("[RX] $name is speaking...", "rx");
        _setReceivingState(true, name);
      } else {
        _log("[RX] $name finished transmitting.", "rx");
        _setReceivingState(false, null);
      }
    });

    // Peer disconnected
    _socket!.on('user-left', (data) {
      final id = data['id'] as String;
      final name = data['username'] as String;
      _log("[LEAVE] $name disconnected.", "leave");
      _removePeer(id);
    });
  }

  // ==========================================
  // WEBRTC PEER CONNECTION CREATION
  // ==========================================
  Future<void> _createPeerConnection(String peerId, String peerUsername, {required bool isInitiator}) async {
    final pc = await createPeerConnection(_iceConfiguration);
    _peerConnections[peerId] = pc;

    // Add local tracks (mic) to peer connection
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    pc.onIceCandidate = (candidate) {
      _socket!.emit('signal', {
        'to': peerId,
        'signal': {'candidate': candidate.toMap()}
      });
    };

    pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _log("Link established with $peerUsername.", "system");
          _setPeerStatus(peerId, 'listening');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _log("Connection with $peerUsername failed.", "system");
          _setPeerStatus(peerId, 'offline');
          break;
        default:
          break;
      }
    };

    // When remote track is received, route it to a video renderer for audio playback
    pc.onAddStream = (stream) async {
      print("Received remote audio stream from $peerUsername");
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      renderer.srcObject = stream;
      
      // Store renderer in peer state so it plays and can be disposed later
      if (peers.containsKey(peerId)) {
        peers[peerId]!.renderer = renderer;
        peers[peerId]!.connectionState = 'listening';
        onPeersChanged?.call();
      }
    };

    if (isInitiator) {
      try {
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        _socket!.emit('signal', {
          'to': peerId,
          'signal': {'sdp': offer.toMap()}
        });
      } catch (e) {
        print("Error generating WebRTC Offer: $e");
      }
    }
  }

  // ==========================================
  // TRANSMISSION STATE TOCK TOCK
  // ==========================================
  void startTransmission() {
    if (isTransmitting || isReceiving) return;
    
    isTransmitting = true;
    _socket!.emit('speaking-state', {'isSpeaking': true});
    SoundEffects.playStart();

    // Small delay to allow the beep to start playing before recording
    Future.delayed(const Duration(milliseconds: 100), () {
      if (isTransmitting) {
        _setMicEnabled(true);
        onLcdChanged?.call(LcdState.transmitting, "");
      }
    });
  }

  void stopTransmission() {
    if (!isTransmitting) return;
    
    isTransmitting = false;
    _setMicEnabled(false);
    _socket!.emit('speaking-state', {'isSpeaking': false});
    SoundEffects.playStop();
    onLcdChanged?.call(LcdState.standby, "");
  }

  void _setMicEnabled(bool enabled) {
    if (_localStream != null) {
      for (var track in _localStream!.getAudioTracks()) {
        track.enabled = enabled;
      }
    }
  }

  void _setReceivingState(bool receiving, String? speakerName) {
    if (receiving) {
      isReceiving = true;
      currentSpeakerName = speakerName;
      onLcdChanged?.call(LcdState.receiving, speakerName ?? "Unknown");
    } else {
      isReceiving = false;
      currentSpeakerName = null;
      onLcdChanged?.call(LcdState.standby, "");
      // Reset peer states back to listening
      peers.forEach((_, peer) {
        if (peer.connectionState == 'speaking') {
          peer.connectionState = 'listening';
        }
      });
      onPeersChanged?.call();
    }
  }

  // ==========================================
  // STATE HELPERS
  // ==========================================
  void _addPeer(String id, String username) {
    peers[id] = PeerState(
      id: id,
      username: username,
      connectionState: 'connecting',
    );
  }

  void _removePeer(String id) {
    if (_peerConnections.containsKey(id)) {
      _peerConnections[id]!.close();
      _peerConnections.remove(id);
    }
    if (peers.containsKey(id)) {
      final peer = peers[id];
      peer?.renderer?.srcObject = null;
      peer?.renderer?.dispose();
      peers.remove(id);
    }
    onPeersChanged?.call();
  }

  void _setPeerStatus(String id, String status) {
    if (peers.containsKey(id)) {
      peers[id]!.connectionState = status;
      onPeersChanged?.call();
    }
  }

  void _updatePeerSpeakingState(String id, bool isSpeaking) {
    if (peers.containsKey(id)) {
      peers[id]!.connectionState = isSpeaking ? 'speaking' : 'listening';
      onPeersChanged?.call();
    }
  }

  void _log(String message, String type) {
    onLog?.call(message, type);
  }

  // Clean up and disconnect
  void disconnect() {
    _socket?.disconnect();
    _socket = null;
    
    _peerConnections.forEach((_, pc) => pc.close());
    _peerConnections.clear();

    peers.forEach((_, peer) {
      peer.renderer?.srcObject = null;
      peer.renderer?.dispose();
    });
    peers.clear();

    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;

    isTransmitting = false;
    isReceiving = false;
    currentSpeakerName = null;

    onPeersChanged?.call();
    onLcdChanged?.call(LcdState.standby, "");
  }
}
