'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const WebSocket = require('ws');

const ED25519_PUBLIC_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const ED25519_PRIVATE_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const X25519_PUBLIC_PREFIX = Buffer.from('302a300506032b656e032100', 'hex');
const X25519_PRIVATE_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');
const INVITE_PREFIX = 'privatecat:';

function privateKey(raw, prefix) {
  return crypto.createPrivateKey({ key: Buffer.concat([prefix, raw]), format: 'der', type: 'pkcs8' });
}

function publicKey(raw, prefix) {
  return crypto.createPublicKey({ key: Buffer.concat([prefix, raw]), format: 'der', type: 'spki' });
}

function rawPublicKey(key) {
  return key.export({ format: 'der', type: 'spki' }).subarray(-32);
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
}

function loadIdentity(dataDir) {
  const file = path.join(dataDir, 'identity.json');
  let stored;
  try { stored = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const signingPrivateRaw = stored ? Buffer.from(stored.signingPrivateKey, 'base64') : crypto.randomBytes(32);
  const agreementPrivateRaw = stored ? Buffer.from(stored.agreementPrivateKey, 'base64') : crypto.randomBytes(32);
  if (signingPrivateRaw.length !== 32 || agreementPrivateRaw.length !== 32) {
    throw new Error('Invalid test-user identity file');
  }
  if (!stored) writeJSON(file, {
    signingPrivateKey: signingPrivateRaw.toString('base64'),
    agreementPrivateKey: agreementPrivateRaw.toString('base64')
  });

  const signingKey = privateKey(signingPrivateRaw, ED25519_PRIVATE_PREFIX);
  const agreementKey = privateKey(agreementPrivateRaw, X25519_PRIVATE_PREFIX);
  const signingPublic = rawPublicKey(crypto.createPublicKey(signingKey));
  const agreementPublic = rawPublicKey(crypto.createPublicKey(agreementKey));
  const id = crypto.createHash('sha256').update(signingPublic).digest('base64url');
  return { id, signingKey, signingPublic, agreementKey, agreementPublic };
}

function parseInvitation(code) {
  if (typeof code !== 'string' || !code.startsWith(INVITE_PREFIX)) throw new Error('Invalid PrivateCat invitation code');
  const fields = code.trim().split(':');
  if (fields.length !== 4 || fields[0] !== 'privatecat') throw new Error('Invalid PrivateCat invitation code');
  const id = fields[1];
  const agreementPublic = Buffer.from(fields[2], 'base64url');
  const signingPublic = Buffer.from(fields[3], 'base64url');
  if (agreementPublic.length !== 32 || signingPublic.length !== 32 ||
      crypto.createHash('sha256').update(signingPublic).digest('base64url') !== id) {
    throw new Error('Invalid PrivateCat invitation code');
  }
  publicKey(agreementPublic, X25519_PUBLIC_PREFIX);
  publicKey(signingPublic, ED25519_PUBLIC_PREFIX);
  return { id, agreementPublic, signingPublic };
}

function invitationCode(identity) {
  return [INVITE_PREFIX.slice(0, -1), identity.id,
    identity.agreementPublic.toString('base64url'), identity.signingPublic.toString('base64url')].join(':');
}

function addPeer(dataDir, code) {
  const peer = parseInvitation(code);
  const identity = loadIdentity(dataDir);
  if (peer.id === identity.id) throw new Error('Cannot add the test user to itself');
  const file = path.join(dataDir, 'peers.json');
  let peers = [];
  try { peers = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  peers = peers.filter((item) => item.id !== peer.id);
  peers.push({ id: peer.id, agreementPublic: peer.agreementPublic.toString('base64url'),
    signingPublic: peer.signingPublic.toString('base64url') });
  writeJSON(file, peers);
  return peer.id;
}

function loadPeers(dataDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dataDir, 'peers.json'), 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

function messageKey(identity, peer) {
  const sharedSecret = crypto.diffieHellman({
    privateKey: identity.agreementKey,
    publicKey: publicKey(peer.agreementPublic, X25519_PUBLIC_PREFIX)
  });
  const ids = [identity.id, peer.id].sort().join(':');
  return Buffer.from(crypto.hkdfSync('sha256', sharedSecret, Buffer.alloc(0),
    Buffer.from(`PrivateCat v1:${ids}`), 32));
}

function seal(plaintext, identity, peer, nonce = crypto.randomBytes(12)) {
  const cipher = crypto.createCipheriv('chacha20-poly1305', messageKey(identity, peer), nonce, { authTagLength: 16 });
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([nonce, encrypted, cipher.getAuthTag()]);
}

function open(combined, identity, peer) {
  if (combined.length < 28) throw new Error('Invalid encrypted message');
  const nonce = combined.subarray(0, 12);
  const tag = combined.subarray(combined.length - 16);
  const encrypted = combined.subarray(12, combined.length - 16);
  const decipher = crypto.createDecipheriv('chacha20-poly1305', messageKey(identity, peer), nonce, { authTagLength: 16 });
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]);
}

function createTestPeer({ dataDir = '/data', relayURL = 'ws://privatecat-relay:8080/relay', replyPrefix = '테스트 유저가 받았어요: ' } = {}) {
  const events = new EventEmitter();
  const identity = loadIdentity(dataDir);
  const seenMessageIDs = new Set();
  let socket;
  let reconnectTimer;
  let stopped = false;

  function send(packet) {
    if (socket?.readyState !== WebSocket.OPEN) return false;
    socket.send(JSON.stringify(packet));
    return true;
  }

  function processFrame(packet) {
    const peer = loadPeers(dataDir).find((item) => item.id === packet.from);
    if (!peer) return;
    const peerKeys = { id: peer.id, agreementPublic: Buffer.from(peer.agreementPublic, 'base64url') };
    let payload;
    try { payload = JSON.parse(open(Buffer.from(packet.ciphertext, 'base64url'), identity, peerKeys).toString('utf8')); }
    catch { events.emit('invalid-message', packet.from, packet.id); return; }

    send({ type: 'ack', id: packet.id, to: packet.from });
    if (seenMessageIDs.has(packet.id)) return;
    seenMessageIDs.add(packet.id);
    if (seenMessageIDs.size > 4096) seenMessageIDs.delete(seenMessageIDs.values().next().value);
    if (payload.kind !== 'text' || typeof payload.text !== 'string' || !payload.text.trim()) return;

    const reply = Buffer.from(JSON.stringify({ kind: 'text', text: `${replyPrefix}${payload.text}` }));
    const ciphertext = seal(reply, identity, peerKeys).toString('base64url');
    send({ type: 'frame', id: crypto.randomUUID(), to: peer.id, ciphertext });
    events.emit('message', packet.from, payload.text);
  }

  function connect() {
    if (stopped) return;
    socket = new WebSocket(relayURL);
    socket.on('message', (raw) => {
      let packet;
      try { packet = JSON.parse(raw.toString()); } catch { return; }
      if (packet.type === 'challenge') {
        const nonce = Buffer.from(packet.nonce, 'base64url');
        const signature = crypto.sign(null, nonce, identity.signingKey).toString('base64url');
        send({ type: 'hello', deviceId: identity.id, signingPublicKey: identity.signingPublic.toString('base64url'), signature });
      } else if (packet.type === 'ready') {
        events.emit('ready');
      } else if (packet.type === 'frame' && typeof packet.id === 'string' && typeof packet.from === 'string' && typeof packet.ciphertext === 'string') {
        processFrame(packet);
      }
    });
    socket.on('close', () => {
      events.emit('disconnected');
      if (!stopped && !reconnectTimer) reconnectTimer = setTimeout(() => { reconnectTimer = undefined; connect(); }, 3000);
    });
    socket.on('error', () => {});
  }

  return {
    identity,
    invitationCode: invitationCode(identity),
    events,
    start() { connect(); },
    stop() {
      stopped = true;
      clearTimeout(reconnectTimer);
      reconnectTimer = undefined;
      socket?.close();
    }
  };
}

function runCLI() {
  const dataDir = process.env.PRIVATECAT_TEST_PEER_DATA_DIR || '/data';
  if (process.argv[2] === 'add-peer') {
    if (!process.argv[3]) throw new Error('Usage: node privatecat-test-user.js add-peer <PrivateCat invitation code>');
    console.log(`Added test peer ${addPeer(dataDir, process.argv[3])}`);
    return;
  }
  const peer = createTestPeer({ dataDir, relayURL: process.env.PRIVATECAT_RELAY_URL });
  console.log(`PrivateCat test-user invitation code: ${peer.invitationCode}`);
  console.log('Test-user private keys are kept in its Docker volume; message contents are not stored.');
  peer.events.on('ready', () => console.log('Test user connected to relay.'));
  peer.events.on('message', (_, text) => console.log(`Replied to a ${Buffer.byteLength(text)}-byte text message.`));
  peer.events.on('invalid-message', () => console.warn('Ignored an unpaired or invalid message.'));
  peer.events.on('disconnected', () => console.warn('Relay disconnected; retrying.'));
  peer.start();
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { peer.stop(); process.exit(0); });
}

if (require.main === module) {
  try { runCLI(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}

module.exports = { addPeer, createTestPeer, invitationCode, loadIdentity, messageKey, open, parseInvitation, seal };
