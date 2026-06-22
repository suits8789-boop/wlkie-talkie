// ==========================================
// 1. STATE & GLOBAL CONFIGURATION
// ==========================================
let socket;
let localStream;
let myUsername = '';
let myRoom = '';

// Maps peer socket ID -> { pc: RTCPeerConnection, username: string }
const peerConnections = {};

// To use over long-distance (Internet), replace this placeholder with your deployed HTTPS server URL:
// E.g., 'https://my-walkie-talkie-server.onrender.com'
const REMOTE_SERVER_URL = '';

// WebRTC ICE Servers configuration
// STUN servers resolve public IPs. For long distance traversal over strict carrier NATs (LTE/5G),
// you can add TURN servers in the iceServers list.
const peerConfiguration = {
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
    { urls: 'stun:stun2.l.google.com:19302' }
    // Example TURN Server integration (Optional, for 100% cellular NAT traversal):
    // {
    //   urls: 'turn:your-turn-server.com:3478',
    //   username: 'your-username',
    //   credential: 'your-password'
    // }
  ]
};

// UI State flags
let isTransmitting = false;
let isReceiving = false;
let spacePressed = false;
let currentSpeakerId = null;

// Audio context for sound effects and visualizer
let audioContext;
let localAnalyser;
let remoteAnalyser;
let visualizerInterval;

// DOM Elements Cache
const joinScreen = document.getElementById('join-screen');
const walkieTalkieScreen = document.getElementById('walkie-talkie-screen');
const joinForm = document.getElementById('join-form');
const usernameInput = document.getElementById('username');
const roomInput = document.getElementById('room-name');
const randomizeBtn = document.getElementById('randomize-btn');
const joinBtn = document.getElementById('join-btn');

const displayRoom = document.getElementById('display-room');
const displayUsername = document.getElementById('display-username');
const leaveBtn = document.getElementById('leave-btn');
const pttBtn = document.getElementById('ptt-btn');
const pttPrompt = document.getElementById('ptt-prompt');
const micLock = document.getElementById('mic-lock');
const peerList = document.getElementById('peer-list');
const peerCount = document.getElementById('peer-count');
const systemLogs = document.getElementById('system-logs');

const lcdStatus = document.getElementById('lcd-status');
const lcdSubstatus = document.getElementById('lcd-substatus');
const lcdRxTx = document.getElementById('lcd-rx-tx');
const waveCanvas = document.getElementById('wave-canvas');
const waveCtx = waveCanvas.getContext('2d');

// ==========================================
// 2. RANDOM USERNAME GENERATION
// ==========================================
const callsigns = [
  'Viper', 'Nomad', 'Spectre', 'Phoenix', 'Outlaw', 'Ranger',
  'Bravo', 'Shadow', 'Falcon', 'Ghost', 'Tango', 'Sierra',
  'Titan', 'Hunter', 'Echo', 'Apex', 'Razor', 'Cobra'
];

function generateRandomUsername() {
  const name = callsigns[Math.floor(Math.random() * callsigns.length)];
  const num = Math.floor(Math.random() * 90) + 10; // 2 digit number
  return `${name}-${num}`;
}

// Initialize random username on load
usernameInput.value = generateRandomUsername();

randomizeBtn.addEventListener('click', () => {
  usernameInput.value = generateRandomUsername();
  // Trigger micro-animation on randomize icon
  randomizeBtn.style.transform = 'rotate(180deg)';
  setTimeout(() => randomizeBtn.style.transform = 'none', 300);
});

// ==========================================
// 3. SOUND SYNTHESIS ENGINE (Web Audio API)
// ==========================================
function initAudioEngine() {
  if (!audioContext) {
    audioContext = new (window.AudioContext || window.webkitAudioContext)();
  }
  // Resume AudioContext if suspended (browser security restriction)
  if (audioContext.state === 'suspended') {
    audioContext.resume();
  }
}

// Key up beep (Double high tone beep)
function playKeyChirp() {
  if (!audioContext) return;
  initAudioEngine();

  const osc1 = audioContext.createOscillator();
  const osc2 = audioContext.createOscillator();
  const gain = audioContext.createGain();

  osc1.type = 'sine';
  osc2.type = 'sine';
  
  // Retro sci-fi dual-frequency beeps
  osc1.frequency.setValueAtTime(880, audioContext.currentTime); // A5
  osc2.frequency.setValueAtTime(1109, audioContext.currentTime); // C#6

  gain.gain.setValueAtTime(0, audioContext.currentTime);
  gain.gain.linearRampToValueAtTime(0.08, audioContext.currentTime + 0.01);
  gain.gain.setValueAtTime(0.08, audioContext.currentTime + 0.08);
  gain.gain.exponentialRampToValueAtTime(0.001, audioContext.currentTime + 0.12);

  osc1.connect(gain);
  osc2.connect(gain);
  gain.connect(audioContext.destination);

  osc1.start();
  osc2.start();
  osc1.stop(audioContext.currentTime + 0.12);
  osc2.stop(audioContext.currentTime + 0.12);
}

// Key down squelch (Hiss + end chirp)
function playSquelchChirp() {
  if (!audioContext) return;
  initAudioEngine();

  const osc = audioContext.createOscillator();
  const gainOsc = audioContext.createGain();

  osc.type = 'sine';
  osc.frequency.setValueAtTime(440, audioContext.currentTime); // A4

  gainOsc.gain.setValueAtTime(0.05, audioContext.currentTime);
  gainOsc.gain.exponentialRampToValueAtTime(0.001, audioContext.currentTime + 0.06);

  osc.connect(gainOsc);
  gainOsc.connect(audioContext.destination);
  osc.start();
  osc.stop(audioContext.currentTime + 0.06);

  // Generate 150ms of white noise for radio static squelch
  const bufferSize = audioContext.sampleRate * 0.15;
  const buffer = audioContext.createBuffer(1, bufferSize, audioContext.sampleRate);
  const data = buffer.getChannelData(0);
  for (let i = 0; i < bufferSize; i++) {
    data[i] = Math.random() * 2 - 1;
  }

  const noise = audioContext.createBufferSource();
  noise.buffer = buffer;

  const gainNoise = audioContext.createGain();
  gainNoise.gain.setValueAtTime(0.04, audioContext.currentTime + 0.02);
  gainNoise.gain.exponentialRampToValueAtTime(0.001, audioContext.currentTime + 0.14);

  // Bandpass filter to make it sound like a cheap walkie talkie speaker
  const filter = audioContext.createBiquadFilter();
  filter.type = 'bandpass';
  filter.frequency.value = 1200; // Centered at 1.2kHz
  filter.Q.value = 1.5;

  noise.connect(filter);
  filter.connect(gainNoise);
  gainNoise.connect(audioContext.destination);

  noise.start(audioContext.currentTime + 0.02);
  noise.stop(audioContext.currentTime + 0.16);
}

// ==========================================
// 4. NETWORKING & CONNECTION INITIATION
// ==========================================
joinForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  
  myUsername = usernameInput.value.trim();
  myRoom = roomInput.value.trim();

  if (!myUsername || !myRoom) return;

  logToConsole(`[SYSTEM] Requesting microphone access...`);
  joinBtn.disabled = true;
  joinBtn.innerText = 'REQUESTING MIC...';

  try {
    // Acquire audio-only local stream
    localStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      },
      video: false
    });

    // Disable the mic track initially (so we are not broadcasting on startup)
    localStream.getAudioTracks().forEach(track => {
      track.enabled = false;
    });

    // Initialize Web Audio nodes for our local microphone visualizer
    initAudioEngine();
    localAnalyser = audioContext.createAnalyser();
    localAnalyser.fftSize = 64;
    const localSource = audioContext.createMediaStreamSource(localStream);
    localSource.connect(localAnalyser);

    logToConsole(`[SYSTEM] Microphone access granted.`);
    
    // Connect to WebSocket signaling server
    // If REMOTE_SERVER_URL is provided, we use it. Otherwise, default to current origin (localhost/Wi-Fi IP).
    // Also check if running inside Capacitor (webview url typically starts with 'capacitor://' or matches local webview addresses)
    let connectionUrl = window.location.origin;
    const isApp = window.location.origin.includes('capacitor://') || 
                  (window.location.origin.includes('localhost') && !window.location.origin.includes(':3000'));
    
    if (REMOTE_SERVER_URL) {
      connectionUrl = REMOTE_SERVER_URL;
    } else if (isApp) {
      connectionUrl = 'http://localhost:3000'; // Default local server fallback
      logToConsole(`[WARNING] Mobile app detected. Please configure REMOTE_SERVER_URL in client.js for remote server connection!`);
    }

    socket = io(connectionUrl);
    
    setupSocketListeners();

    // UI transitions
    joinScreen.classList.add('hidden');
    walkieTalkieScreen.classList.remove('hidden');
    displayRoom.innerText = myRoom.toUpperCase();
    displayUsername.innerText = myUsername;

    // Join room on signaling server
    socket.emit('join-room', { roomName: myRoom, username: myUsername });
    logToConsole(`[SYSTEM] Joining channel: ${myRoom}`);

    // Start rendering the wave canvas loop
    startVisualizer();

  } catch (err) {
    console.error('Error joining:', err);
    logToConsole(`[ERROR] Microphone permission denied. Walkie-talkie requires mic access. Ensure HTTPS is used!`);
    alert('Microphone access is required to use the walkie talkie. Please grant permission and ensure you are accessing via HTTPS.');
    joinBtn.disabled = false;
    joinBtn.innerText = 'CONNECT CHANNEL';
  }
});

// Setup WebSocket message handlers
function setupSocketListeners() {
  // Receive lists of existing operators in the room on join
  socket.on('room-users', (users) => {
    logToConsole(`[SYSTEM] Connected. Operators in room: ${users.length}`);
    updatePeerListUI(users);

    // Establish PeerConnections with everyone currently in the room
    // Since we just joined, we act as the WebRTC Initiator
    users.forEach(user => {
      createPeerConnection(user.id, user.username, true);
    });
  });

  // A new operator joined the room
  socket.on('user-joined', ({ id, username }) => {
    logToConsole(`[JOIN] ${username} entered channel.`);
    addPeerToUI(id, username);
    
    // Prepare PeerConnection for the incoming offer from the joiner
    createPeerConnection(id, username, false);
  });

  // Signal message from a peer (contains WebRTC SDP or ICE candidates)
  socket.on('signal', async ({ from, signal }) => {
    const peer = peerConnections[from];
    if (!peer) return;

    try {
      if (signal.sdp) {
        await peer.pc.setRemoteDescription(new RTCSessionDescription(signal.sdp));
        
        // If we received an Offer, we must create and send an Answer
        if (signal.sdp.type === 'offer') {
          const answer = await peer.pc.createAnswer();
          await peer.pc.setLocalDescription(answer);
          socket.emit('signal', { to: from, signal: { sdp: peer.pc.localDescription } });
        }
      } else if (signal.candidate) {
        await peer.pc.addIceCandidate(new RTCIceCandidate(signal.candidate));
      }
    } catch (err) {
      console.error('Error handling signaling message:', err);
    }
  });

  // Broadcast of speaking state
  socket.on('user-speaking', ({ id, username, isSpeaking }) => {
    updatePeerSpeakingState(id, isSpeaking);

    const peerItem = document.getElementById(`peer-${id}`);
    if (isSpeaking) {
      logToConsole(`[RX] ${username} is speaking...`);
      setReceivingState(true, username, id);
    } else {
      logToConsole(`[RX] ${username} finished transmitting.`);
      setReceivingState(false, null, null);
    }
  });

  // An operator left the room
  socket.on('user-left', ({ id, username }) => {
    logToConsole(`[LEAVE] ${username} disconnected.`);
    removePeer(id);
  });

  // Generic errors
  socket.on('error-msg', (msg) => {
    logToConsole(`[SERVER ERROR] ${msg}`);
  });
}

// ==========================================
// 5. WEBRTC MULTI-PEER ENGINE
// ==========================================
function createPeerConnection(peerId, peerUsername, isInitiator) {
  // If connection already exists, close it first to avoid memory leaks
  if (peerConnections[peerId]) {
    peerConnections[peerId].pc.close();
  }

  const pc = new RTCPeerConnection(peerConfiguration);
  
  // Store this peer connection
  peerConnections[peerId] = {
    pc: pc,
    username: peerUsername
  };

  // Set peer UI connection status to Connecting
  setPeerUIStatus(peerId, 'connecting');

  // Add all local tracks (our mic track) to this peer connection
  localStream.getTracks().forEach(track => {
    pc.addTrack(track, localStream);
  });

  // Send ICE candidates to the other peer via signaling server
  pc.onicecandidate = (event) => {
    if (event.candidate) {
      socket.emit('signal', { to: peerId, signal: { candidate: event.candidate } });
    }
  };

  // Connection state monitoring
  pc.onconnectionstatechange = () => {
    switch (pc.connectionState) {
      case 'connected':
        logToConsole(`[SYSTEM] WebRTC link established with ${peerUsername}.`);
        setPeerUIStatus(peerId, 'listening');
        break;
      case 'disconnected':
      case 'failed':
        logToConsole(`[SYSTEM] Connection with ${peerUsername} failed/disconnected.`);
        setPeerUIStatus(peerId, 'offline');
        break;
      case 'closed':
        setPeerUIStatus(peerId, 'offline');
        break;
    }
  };

  // Play remote audio streams automatically
  pc.ontrack = (event) => {
    console.log(`Received track from ${peerUsername}`, event.streams);
    
    // Add remote stream to an invisible audio tag in the DOM
    let audioEl = document.getElementById(`audio-${peerId}`);
    if (!audioEl) {
      audioEl = document.createElement('audio');
      audioEl.id = `audio-${peerId}`;
      audioEl.autoplay = true;
      audioEl.playsInline = true;
      document.getElementById('remote-audio-container').appendChild(audioEl);
    }
    
    const remoteStream = event.streams[0];
    audioEl.srcObject = remoteStream;

    // Attach remote stream to visualizer context
    try {
      if (!remoteAnalyser) {
        remoteAnalyser = audioContext.createAnalyser();
        remoteAnalyser.fftSize = 64;
      }
      const remoteSource = audioContext.createMediaStreamSource(remoteStream);
      remoteSource.connect(remoteAnalyser);
    } catch (e) {
      console.warn('Could not pipe remote audio to Web Audio visualizer:', e);
    }
  };

  // If we are the initiator, create the SDP offer and send it to the other peer
  if (isInitiator) {
    pc.onnegotiationneeded = async () => {
      try {
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        socket.emit('signal', { to: peerId, signal: { sdp: pc.localDescription } });
      } catch (err) {
        console.error('Error generating WebRTC Offer:', err);
      }
    };
  }
}

// Clean up and disconnect a peer
function removePeer(peerId) {
  if (peerConnections[peerId]) {
    peerConnections[peerId].pc.close();
    delete peerConnections[peerId];
  }

  // Remove audio tag
  const audioEl = document.getElementById(`audio-${peerId}`);
  if (audioEl) {
    audioEl.srcObject = null;
    audioEl.remove();
  }

  // Remove from UI list
  const li = document.getElementById(`peer-${peerId}`);
  if (li) {
    li.remove();
  }

  updatePeerCount();
}

// ==========================================
// 6. MIC TRANSMISSION CONTROL (PTT)
// ==========================================
function startTransmission() {
  if (isTransmitting || isReceiving) return; // Can't talk if already talking or if someone is talking to us
  
  isTransmitting = true;
  pttBtn.classList.add('active');
  pttPrompt.innerText = 'TRANSMITTING';
  
  // 1. Alert server and peers that we are starting to speak
  socket.emit('speaking-state', { isSpeaking: true });

  // 2. Play walkie talkie beep locally
  playKeyChirp();

  // 3. Enable the local audio tracks to send our mic data
  setTimeout(() => {
    if (isTransmitting) {
      localStream.getAudioTracks().forEach(track => {
        track.enabled = true;
      });
      setLcdState('transmitting');
    }
  }, 100); // 100ms delay to let the key chirp finish playing
}

function stopTransmission() {
  if (!isTransmitting) return;

  isTransmitting = false;
  pttBtn.classList.remove('active');
  pttPrompt.innerText = 'HOLD TO TALK';

  // Disable the local audio track (mute us)
  localStream.getAudioTracks().forEach(track => {
    track.enabled = false;
  });

  // Alert server and peers that we stopped speaking
  socket.emit('speaking-state', { isSpeaking: false });

  // Play stop walkie talkie sound (chirp + static hiss)
  playSquelchChirp();

  // Reset display back to Standby
  setLcdState('standby');
}

// ==========================================
// 7. RECEIVING STATE MANAGEMENT
// ==========================================
function setReceivingState(receiving, speakerName, speakerId) {
  if (receiving) {
    isReceiving = true;
    currentSpeakerId = speakerId;
    setLcdState('receiving', speakerName);
    updatePeerSpeakingState(speakerId, true);
  } else {
    isReceiving = false;
    currentSpeakerId = null;
    setLcdState('standby');
    // Set all peers speaking state to false
    Object.keys(peerConnections).forEach(id => {
      updatePeerSpeakingState(id, false);
    });
  }
}

// ==========================================
// 8. LCD DISPLAY STATE UPDATES
// ==========================================
function setLcdState(state, arg = '') {
  const signalBars = document.querySelectorAll('.sig-bar');
  
  switch (state) {
    case 'standby':
      lcdStatus.innerText = 'STANDBY';
      lcdStatus.className = 'lcd-status-msg';
      lcdSubstatus.innerText = 'READY TO RECEIVE';
      lcdRxTx.style.visibility = 'hidden';
      lcdRxTx.innerText = 'RX';
      
      // Standby signal strength shows 3 bars
      signalBars.forEach((bar, idx) => {
        if (idx < 3) bar.classList.add('active');
        else bar.classList.remove('active');
      });
      break;

    case 'transmitting':
      lcdStatus.innerText = 'TX ACTIVE';
      lcdStatus.className = 'lcd-status-msg transmitting';
      lcdSubstatus.innerText = 'BROADCASTING...';
      lcdRxTx.innerText = 'TX';
      lcdRxTx.style.visibility = 'visible';
      
      // Full signal strength on transmit
      signalBars.forEach(bar => bar.classList.add('active'));
      break;

    case 'receiving':
      lcdStatus.innerText = 'RX ACTIVE';
      lcdStatus.className = 'lcd-status-msg receiving';
      lcdSubstatus.innerText = `FROM: ${arg.toUpperCase()}`;
      lcdRxTx.innerText = 'RX';
      lcdRxTx.style.visibility = 'visible';
      
      // Full signal bars on receive
      signalBars.forEach(bar => bar.classList.add('active'));
      break;
  }
}

// ==========================================
// 9. UI LISTS & LOGS HELPERS
// ==========================================
function updatePeerListUI(peers) {
  peerList.innerHTML = '';
  
  if (peers.length === 0) {
    peerList.innerHTML = '<li class="empty-list-placeholder">No other operators in this channel</li>';
  } else {
    peers.forEach(peer => {
      addPeerToUI(peer.id, peer.username);
    });
  }
  updatePeerCount();
}

function addPeerToUI(peerId, peerUsername) {
  // Remove placeholder if present
  const placeholder = peerList.querySelector('.empty-list-placeholder');
  if (placeholder) placeholder.remove();

  // If already exists, don't duplicate
  if (document.getElementById(`peer-${peerId}`)) return;

  const li = document.createElement('li');
  li.id = `peer-${peerId}`;
  li.className = 'connecting'; // initial state

  const nameContainer = document.createElement('div');
  nameContainer.className = 'peer-name-container';

  const avatar = document.createElement('div');
  avatar.className = 'peer-avatar';
  avatar.innerText = peerUsername.substring(0, 2).toUpperCase();

  const name = document.createElement('span');
  name.className = 'peer-name';
  name.innerText = peerUsername;

  nameContainer.appendChild(avatar);
  nameContainer.appendChild(name);

  const status = document.createElement('div');
  status.className = 'peer-status';
  
  const dot = document.createElement('span');
  dot.className = 'status-dot';
  
  const text = document.createElement('span');
  text.className = 'status-text';
  text.innerText = 'CONNECTING';

  status.appendChild(dot);
  status.appendChild(text);

  li.appendChild(nameContainer);
  li.appendChild(status);

  peerList.appendChild(li);
  updatePeerCount();
}

function setPeerUIStatus(peerId, status) {
  const li = document.getElementById(`peer-${peerId}`);
  if (!li) return;

  li.className = status; // listening, speaking, connecting, offline
  
  const statusText = li.querySelector('.status-text');
  if (statusText) {
    statusText.innerText = status.toUpperCase();
  }
}

function updatePeerSpeakingState(peerId, isSpeaking) {
  const li = document.getElementById(`peer-${peerId}`);
  if (!li) return;

  if (isSpeaking) {
    li.className = 'speaking';
    const statusText = li.querySelector('.status-text');
    if (statusText) statusText.innerText = 'SPEAKING';
  } else {
    li.className = 'listening';
    const statusText = li.querySelector('.status-text');
    if (statusText) statusText.innerText = 'LISTENING';
  }
}

function updatePeerCount() {
  const count = Object.keys(peerConnections).length;
  peerCount.innerText = count;
}

function logToConsole(message) {
  const time = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const entry = document.createElement('div');
  
  let entryClass = 'system';
  if (message.includes('[JOIN]')) entryClass = 'join';
  else if (message.includes('[LEAVE]')) entryClass = 'leave';
  else if (message.includes('[TX]')) entryClass = 'tx';
  else if (message.includes('[RX]')) entryClass = 'rx';
  else if (message.includes('[ERROR]')) entryClass = 'leave';

  entry.className = `log-entry ${entryClass}`;
  entry.innerText = `[${time}] ${message}`;

  systemLogs.appendChild(entry);
  
  // Auto scroll to bottom
  systemLogs.scrollTop = systemLogs.scrollHeight;
}

// Exit room and return to lobby
leaveBtn.addEventListener('click', () => {
  if (confirm('Disconnect from this walkie talkie channel?')) {
    location.reload();
  }
});

// ==========================================
// 10. INPUT GESTURES (TOUCH, MOUSE, KEYBOARD)
// ==========================================

// PUSH TO TALK BUTTON TRIGGERS
pttBtn.addEventListener('mousedown', (e) => {
  e.preventDefault();
  // Don't trigger if mic continuous lock is active
  if (micLock.checked) return;
  startTransmission();
});

window.addEventListener('mouseup', () => {
  if (micLock.checked) return;
  stopTransmission();
});

// Mobile Touch Support
pttBtn.addEventListener('touchstart', (e) => {
  e.preventDefault();
  initAudioEngine(); // resume audio context for mobile safari/chrome on first touch
  if (micLock.checked) return;
  startTransmission();
});

window.addEventListener('touchend', () => {
  if (micLock.checked) return;
  stopTransmission();
});

// SPACEBAR SHORTCUT (For Desktop convenience)
window.addEventListener('keydown', (e) => {
  // If user is focused in join screen inputs, don't trigger spacebar
  if (!joinScreen.classList.contains('hidden')) return;

  if (e.code === 'Space') {
    e.preventDefault(); // Prevent page scrolling
    if (micLock.checked) return;

    if (!spacePressed) {
      spacePressed = true;
      startTransmission();
    }
  }
});

window.addEventListener('keyup', (e) => {
  if (e.code === 'Space') {
    if (micLock.checked) return;
    spacePressed = false;
    stopTransmission();
  }
});

// MIC LOCK SLIDER (Continuous streaming)
micLock.addEventListener('change', () => {
  if (micLock.checked) {
    logToConsole(`[SYSTEM] Continuous streaming enabled. Mic is open.`);
    startTransmission();
    pttPrompt.innerText = 'MIC LOCKED OPEN';
  } else {
    logToConsole(`[SYSTEM] Continuous streaming disabled. Back to hold-to-talk.`);
    stopTransmission();
  }
});

// ==========================================
// 11. AUDIO OSCILLOSCOPE VISUALIZATION
// ==========================================
function startVisualizer() {
  const bufferLength = 32;
  const dataArray = new Uint8Array(bufferLength);

  function draw() {
    requestAnimationFrame(draw);

    const width = waveCanvas.width;
    const height = waveCanvas.height;

    // Clear background with dark LCD color
    waveCtx.fillStyle = '#0b1c1e';
    waveCtx.fillRect(0, 0, width, height);

    // Get active audio levels
    let activeAnalyser = null;
    if (isTransmitting && localAnalyser) {
      activeAnalyser = localAnalyser;
    } else if (isReceiving && remoteAnalyser) {
      activeAnalyser = remoteAnalyser;
    }

    if (activeAnalyser) {
      // Get waveform data
      activeAnalyser.getByteTimeDomainData(dataArray);

      // Draw glowing oscilliscope line
      waveCtx.lineWidth = 2.5;
      waveCtx.strokeStyle = isTransmitting ? '#ff0055' : '#00f0ff';
      waveCtx.shadowBlur = 6;
      waveCtx.shadowColor = isTransmitting ? 'rgba(255, 0, 85, 0.7)' : 'rgba(0, 240, 255, 0.7)';
      waveCtx.beginPath();

      const sliceWidth = width / bufferLength;
      let x = 0;

      for (let i = 0; i < bufferLength; i++) {
        const v = dataArray[i] / 128.0; // range 0 to 2
        const y = v * (height / 2);

        if (i === 0) {
          waveCtx.moveTo(x, y);
        } else {
          waveCtx.lineTo(x, y);
        }

        x += sliceWidth;
      }

      waveCtx.lineTo(width, height / 2);
      waveCtx.stroke();
    } else {
      // Standby visualizer state - draw a flat line with slight random static buzz
      waveCtx.lineWidth = 1.5;
      waveCtx.strokeStyle = 'rgba(0, 240, 255, 0.35)'; // cyan standby line
      waveCtx.shadowBlur = 0;
      waveCtx.beginPath();
      
      const sliceWidth = width / 10;
      let x = 0;
      waveCtx.moveTo(0, height / 2);
      
      for (let i = 0; i <= 10; i++) {
        // very minor ripple to indicate it is alive
        const buzz = (Math.random() - 0.5) * 1.5;
        waveCtx.lineTo(x, (height / 2) + buzz);
        x += sliceWidth;
      }
      waveCtx.stroke();
    }
  }

  draw();
}
