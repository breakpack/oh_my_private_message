'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const { WebSocketServer, WebSocket } = require('ws');

const MAX_FRAME_BYTES = 1024 * 1024;
const ID_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
const MESSAGE_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;

function send(socket, value) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value));
}

function parseBase64url(value) {
  if (typeof value !== 'string' || !BASE64URL_PATTERN.test(value)) return null;
  const bytes = Buffer.from(value, 'base64url');
  return bytes.toString('base64url') === value ? bytes : null;
}

function protocolError(socket, message) {
  send(socket, { type: 'error', message });
  socket.close(1008, 'protocol error');
}

function createRelayServer({ port = Number(process.env.PORT || 8080), host = process.env.HOST || '0.0.0.0' } = {}) {
  const routes = new Map();
  const challenges = new WeakMap();
  const authenticated = new WeakMap();

  const server = http.createServer((request, response) => {
    if (request.method === 'GET' && request.url === '/healthz') {
      response.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      response.end('ok\n');
      return;
    }
    response.writeHead(404);
    response.end();
  });

  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES });

  server.on('upgrade', (request, socket, head) => {
    if (request.url !== '/relay') {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => wss.emit('connection', ws, request));
  });

  wss.on('connection', (socket) => {
    const nonce = crypto.randomBytes(32);
    challenges.set(socket, nonce);
    send(socket, { type: 'challenge', nonce: nonce.toString('base64url') });

    socket.on('message', (data, isBinary) => {
      if (isBinary) return protocolError(socket, 'JSON text frames are required');
      let packet;
      try { packet = JSON.parse(data.toString()); } catch { return protocolError(socket, 'Invalid JSON'); }
      if (!packet || typeof packet !== 'object' || Array.isArray(packet)) return protocolError(socket, 'Invalid packet');

      const deviceId = authenticated.get(socket);
      if (!deviceId) {
        const challenge = challenges.get(socket);
        const publicKeyBytes = parseBase64url(packet.signingPublicKey);
        const signature = parseBase64url(packet.signature);
        if (packet.type !== 'hello' || !challenge || !publicKeyBytes || publicKeyBytes.length !== 32 || !signature ||
            !ID_PATTERN.test(packet.deviceId || '') ||
            crypto.createHash('sha256').update(publicKeyBytes).digest('base64url') !== packet.deviceId) {
          return protocolError(socket, 'Invalid hello');
        }
        let valid = false;
        try {
          const publicKey = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicKeyBytes]), format: 'der', type: 'spki' });
          valid = crypto.verify(null, challenge, publicKey, signature);
        } catch { valid = false; }
        challenges.delete(socket);
        if (!valid) return protocolError(socket, 'Invalid signature');

        const previous = routes.get(packet.deviceId);
        if (previous && previous !== socket) previous.close(4001, 'replaced by a newer connection');
        authenticated.set(socket, packet.deviceId);
        routes.set(packet.deviceId, socket);
        send(socket, { type: 'ready' });
        return;
      }

      if (packet.type === 'frame') {
        if (!MESSAGE_ID_PATTERN.test(packet.id || '') || !ID_PATTERN.test(packet.to || '') ||
            typeof packet.ciphertext !== 'string' || !BASE64URL_PATTERN.test(packet.ciphertext)) {
          return protocolError(socket, 'Invalid frame');
        }
        const recipient = routes.get(packet.to);
        if (!recipient || recipient.readyState !== WebSocket.OPEN) {
          routes.delete(packet.to);
          send(socket, { type: 'unavailable', id: packet.id });
          return;
        }
        send(recipient, { type: 'frame', id: packet.id, from: deviceId, ciphertext: packet.ciphertext });
        return;
      }

      if (packet.type === 'ack') {
        if (!MESSAGE_ID_PATTERN.test(packet.id || '') || !ID_PATTERN.test(packet.to || '')) return protocolError(socket, 'Invalid acknowledgement');
        const sender = routes.get(packet.to);
        if (!sender || sender.readyState !== WebSocket.OPEN) {
          send(socket, { type: 'unavailable', id: packet.id });
          return;
        }
        send(sender, { type: 'ack', id: packet.id, from: deviceId });
        return;
      }

      protocolError(socket, 'Unsupported packet type');
    });

    socket.on('close', () => {
      const id = authenticated.get(socket);
      if (id && routes.get(id) === socket) routes.delete(id);
      challenges.delete(socket);
      authenticated.delete(socket);
    });
  });

  return {
    server,
    routes,
    listen() {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => {
          server.off('error', reject);
          resolve(server.address());
        });
      });
    },
    close() {
      return new Promise((resolve) => {
        for (const socket of wss.clients) socket.terminate();
        routes.clear();
        wss.close(() => server.close(() => resolve()));
      });
    }
  };
}

if (require.main === module) {
  const relay = createRelayServer();
  relay.listen().then(({ port }) => process.stdout.write(`Private Chat relay listening on ${port}\n`));
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => relay.close().then(() => process.exit(0)));
  }
}

module.exports = { createRelayServer };
