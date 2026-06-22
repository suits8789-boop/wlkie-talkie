import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class SoundEffects {
  static final AudioPlayer _player = AudioPlayer();
  static String? _startChirpPath;
  static String? _stopSquelchPath;

  // Initialize and generate WAV files in temp directory
  static Future<void> init() async {
    try {
      final tempDir = await getTemporaryDirectory();
      
      // 1. Generate Start Chirp
      final startFile = File('${tempDir.path}/start_chirp.wav');
      final startBytes = _generateStartChirpBytes();
      await startFile.writeAsBytes(startBytes);
      _startChirpPath = startFile.path;

      // 2. Generate Stop Squelch
      final stopFile = File('${tempDir.path}/stop_squelch.wav');
      final stopBytes = _generateStopSquelchBytes();
      await stopFile.writeAsBytes(stopBytes);
      _stopSquelchPath = stopFile.path;
    } catch (e) {
      print("Failed to initialize SoundEffects: $e");
    }
  }

  static Future<void> playStart() async {
    if (_startChirpPath != null) {
      try {
        await _player.stop();
        await _player.play(DeviceFileSource(_startChirpPath!));
      } catch (e) {
        print("Error playing start beep: $e");
      }
    }
  }

  static Future<void> playStop() async {
    if (_stopSquelchPath != null) {
      try {
        await _player.stop();
        await _player.play(DeviceFileSource(_stopSquelchPath!));
      } catch (e) {
        print("Error playing stop static: $e");
      }
    }
  }

  static Uint8List _generateStartChirpBytes() {
    const sampleRate = 16000;
    const duration1 = 0.08; // 80ms for first tone (880Hz)
    const duration2 = 0.08; // 80ms for second tone (1109Hz)
    
    final samples1 = (sampleRate * duration1).toInt();
    final samples2 = (sampleRate * duration2).toInt();
    final totalSamples = samples1 + samples2;
    
    final pcmData = Int16List(totalSamples);
    
    // Tone 1: 880 Hz
    const freq1 = 880.0;
    for (int i = 0; i < samples1; i++) {
      double t = i / sampleRate;
      double val = sin(2 * pi * freq1 * t);
      double envelope = 1.0;
      if (i < 160) envelope = i / 160.0; // 10ms fade in
      if (samples1 - i < 160) envelope = (samples1 - i) / 160.0; // 10ms fade out
      pcmData[i] = (val * 16384 * envelope).toInt(); // half max amplitude
    }

    // Tone 2: 1109 Hz
    const freq2 = 1109.0;
    for (int i = 0; i < samples2; i++) {
      double t = i / sampleRate;
      double val = sin(2 * pi * freq2 * t);
      double envelope = 1.0;
      if (i < 160) envelope = i / 160.0;
      if (samples2 - i < 160) envelope = (samples2 - i) / 160.0;
      pcmData[samples1 + i] = (val * 16384 * envelope).toInt();
    }

    return _createWavContainer(pcmData, sampleRate);
  }

  static Uint8List _generateStopSquelchBytes() {
    const sampleRate = 16000;
    const beepDuration = 0.06; // 60ms beep (440Hz)
    const noiseDuration = 0.16; // 160ms squelch noise
    
    final beepSamples = (sampleRate * beepDuration).toInt();
    final noiseSamples = (sampleRate * noiseDuration).toInt();
    final totalSamples = beepSamples + noiseSamples;
    
    final pcmData = Int16List(totalSamples);
    
    // 440Hz beep
    const beepFreq = 440.0;
    for (int i = 0; i < beepSamples; i++) {
      double t = i / sampleRate;
      double val = sin(2 * pi * beepFreq * t);
      double envelope = exp(-5 * (i / beepSamples));
      pcmData[i] = (val * 12288 * envelope).toInt();
    }

    // Filtered white noise (static hiss)
    final rand = Random();
    double lastNoise = 0.0;
    for (int i = 0; i < noiseSamples; i++) {
      double white = rand.nextDouble() * 2.0 - 1.0;
      // Simple single-pole low pass filter centered around 1.2kHz
      double filtered = 0.35 * white + 0.65 * lastNoise;
      lastNoise = filtered;

      double progress = i / noiseSamples;
      double envelope = exp(-3.5 * progress);
      pcmData[beepSamples + i] = (filtered * 9216 * envelope).toInt();
    }

    return _createWavContainer(pcmData, sampleRate);
  }

  static Uint8List _createWavContainer(Int16List pcmData, int sampleRate) {
    final byteLength = pcmData.length * 2;
    final wavBytes = ByteData(44 + byteLength);

    // "RIFF"
    wavBytes.setUint8(0, 0x52);
    wavBytes.setUint8(1, 0x49);
    wavBytes.setUint8(2, 0x46);
    wavBytes.setUint8(3, 0x46);
    
    wavBytes.setUint32(4, 36 + byteLength, Endian.little);

    // "WAVE"
    wavBytes.setUint8(8, 0x57);
    wavBytes.setUint8(9, 0x41);
    wavBytes.setUint8(10, 0x56);
    wavBytes.setUint8(11, 0x45);

    // "fmt "
    wavBytes.setUint8(12, 0x66);
    wavBytes.setUint8(13, 0x6d);
    wavBytes.setUint8(14, 0x74);
    wavBytes.setUint8(15, 0x20);

    wavBytes.setUint32(16, 16, Endian.little);
    wavBytes.setUint16(20, 1, Endian.little); // PCM
    wavBytes.setUint16(22, 1, Endian.little); // Mono
    wavBytes.setUint32(24, sampleRate, Endian.little);
    wavBytes.setUint32(28, sampleRate * 2, Endian.little);
    wavBytes.setUint16(32, 2, Endian.little);
    wavBytes.setUint16(34, 16, Endian.little); // 16-bit

    // "data"
    wavBytes.setUint8(36, 0x64);
    wavBytes.setUint8(37, 0x61);
    wavBytes.setUint8(38, 0x74);
    wavBytes.setUint8(39, 0x61);

    wavBytes.setUint32(40, byteLength, Endian.little);

    for (int i = 0; i < pcmData.length; i++) {
      wavBytes.setInt16(44 + i * 2, pcmData[i], Endian.little);
    }

    return wavBytes.buffer.asUint8List();
  }
}
