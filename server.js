const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const express = require('express');
const { Server } = require('socket.io');
const selfsigned = require('selfsigned');
const os = require('os');

const PORT = process.env.PORT || 3000;

// Detect if running on a deployed cloud platform (like Render or Fly.io)
const isProduction = process.env.NODE_ENV === 'production' || process.env.DEPLOYED === 'true';

let key, cert;
if (!isProduction) {
  // Generate and load certs only if we are running locally
  const certsDir = path.join(__dirname, 'certs');
  const keyPath = path.join(certsDir, 'key.pem');
  const certPath = path.join(certsDir, 'cert.pem');

  if (!fs.existsSync(certsDir)) {
    fs.mkdirSync(certsDir);
  }

  if (!fs.existsSync(keyPath) || !fs.existsSync(certPath)) {
    console.log('Generating self-signed SSL certificates for secure local Wi-Fi hosting...');
    const attrs = [
      { name: 'commonName', value: 'local-walkie-talkie' },
      { name: 'organizationName', value: 'Antigravity Walkie Talkie' }
    ];
    // Generate certificates valid for 365 days
    const pems = selfsigned.generate(attrs, { days: 365, keySize: 2048 });
    fs.writeFileSync(keyPath, pems.private);
    fs.writeFileSync(certPath, pems.cert);
    key = pems.private;
    cert = pems.cert;
    console.log('SSL certificates generated and saved in /certs folder.');
  } else {
    key = fs.readFileSync(keyPath);
    cert = fs.readFileSync(certPath);
  }
}

// 2. Initialize Express App
const app = express();
app.use(express.static(path.join(__dirname, 'public')));

// 3. Create HTTP or HTTPS Server
let server;
if (isProduction) {
  // Cloud providers handle SSL termination externally; the app runs on plain HTTP internally.
  server = http.createServer(app);
} else {
  // Local Wi-Fi requires HTTPS directly to grant microphone permissions.
  server = https.createServer({ key, cert }, app);
}

// 4. Initialize Socket.io
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

// In-memory data structures to store user mappings
// Maps socket.id -> { username, roomName }
const users = {};

io.on('connection', (socket) => {
  console.log(`Socket connected: ${socket.id}`);

  // When a user joins a room
  socket.on('join-room', ({ roomName, username }) => {
    // Validate inputs
    if (!roomName || !username) {
      return socket.emit('error-msg', 'Room name and Username are required.');
    }

    const sanitizedRoom = roomName.trim().toLowerCase();
    const sanitizedUser = username.trim();

    socket.join(sanitizedRoom);

    // Save user info
    users[socket.id] = {
      username: sanitizedUser,
      roomName: sanitizedRoom
    };
    socket.username = sanitizedUser;
    socket.roomName = sanitizedRoom;

    console.log(`User "${sanitizedUser}" (${socket.id}) joined room "${sanitizedRoom}"`);

    // 1. Get other users already in the room
    const clients = io.sockets.adapter.rooms.get(sanitizedRoom);
    const peerList = [];
    if (clients) {
      for (const clientId of clients) {
        if (clientId !== socket.id) {
          peerList.push({
            id: clientId,
            username: users[clientId]?.username || 'Unknown User'
          });
        }
      }
    }

    // 2. Send the existing peer list to the new joiner
    socket.emit('room-users', peerList);

    // 3. Notify existing peers in the room about the new user
    socket.to(sanitizedRoom).emit('user-joined', {
      id: socket.id,
      username: sanitizedUser
    });
  });

  // Relay WebRTC signaling messages
  socket.on('signal', ({ to, signal }) => {
    // Send the offer, answer, or ice-candidate to the destination peer
    io.to(to).emit('signal', {
      from: socket.id,
      signal: signal
    });
  });

  // Broadcast speaking state change (for UI audio waves / glowing effects)
  socket.on('speaking-state', ({ isSpeaking }) => {
    if (socket.roomName) {
      socket.to(socket.roomName).emit('user-speaking', {
        id: socket.id,
        username: socket.username,
        isSpeaking: isSpeaking
      });
    }
  });

  // Handle client disconnection
  socket.on('disconnect', () => {
    console.log(`Socket disconnected: ${socket.id}`);
    const user = users[socket.id];
    if (user) {
      const { roomName, username } = user;
      // Notify other room members
      socket.to(roomName).emit('user-left', {
        id: socket.id,
        username: username
      });
      delete users[socket.id];
      console.log(`User "${username}" left room "${roomName}"`);
    }
  });
});

// 5. Detect and list local network IP addresses
function getLocalIpAddresses() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  for (const interfaceName in interfaces) {
    for (const iface of interfaces[interfaceName]) {
      // Filter out loopback (127.0.0.1) and non-IPv4 addresses
      if (iface.family === 'IPv4' && !iface.internal) {
        addresses.push(iface.address);
      }
    }
  }
  return addresses;
}

// 6. Start the server
server.listen(PORT, () => {
  if (isProduction) {
    console.log('\n===============================================================');
    console.log(`⚡ WALKIE-TALKIE PRODUCTION SERVER RUNNING ON PORT ${PORT} ⚡`);
    console.log('===============================================================');
    console.log('Server is running securely in the cloud.');
    console.log('Connect clients using your deployed cloud HTTPS URL.');
    console.log('===============================================================\n');
  } else {
    const localIps = getLocalIpAddresses();
    console.log('\n===============================================================');
    console.log(`⚡ ANTIGRAVITY WALKIE-TALKIE SERVER RUNNING ON PORT ${PORT} ⚡`);
    console.log('===============================================================');
    console.log(`Access locally on this machine at:`);
    console.log(`   👉  https://localhost:${PORT}`);
    console.log('\nAccess from other devices on the same Wi-Fi network at:');
    if (localIps.length > 0) {
      localIps.forEach(ip => {
        console.log(`   👉  https://${ip}:${PORT}`);
      });
    } else {
      console.log(`   ⚠️  No local Wi-Fi IP address detected. Check network connection!`);
    }
    console.log('===============================================================\n');
    console.log('NOTE: Since this uses a self-signed SSL certificate:');
    console.log('1. Browsers will show a warning about an "untrusted certificate".');
    console.log('2. You MUST click "Advanced" -> "Proceed" to open the app.');
    console.log('3. This is normal and required to enable camera/mic in local networks.');
    console.log('===============================================================\n');
  }
});
