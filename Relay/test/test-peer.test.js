'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const test = require('node:test');
const WebSocket = require('ws');
const { createRelayServer } = require('../server');
const { addPeer, createTestPeer, invitationCode, loadIdentity, open, parseInvitation, seal } = require('../privatecat-test-user');

const X25519_PRIVATE_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');
const vector = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/cryptokit-test-vector.json'), 'utf8'));

function temporaryDirectory() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'privatecat-test-peer-'));
}

function nextPacket(socket, packets, predicate) {
  const queued = packets.findIndex(predicate);
  if (queued >= 0) return Promise.resolve(packets.splice(queued, 1)[0]);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timed out waiting for relay packet')), 2000);
    function receive(packet) {
      if (!predicate(packet)) return;
      clearTimeout(timer);
      socket.off('packet', receive);
      resolve(packet);
    }
    socket.on('packet', receive);
  });
}

function observe(socket) {
  const packets = [];
  socket.on('message', (raw) => {
    try {
      const packet = JSON.parse(raw.toString());
      packets.push(packet);
      socket.emit('packet', packet);
    } catch {}
  });
  return packets;
}

test('matches CryptoKit key agreement, HKDF, and ChaChaPoly combined bytes', () => {
  const botAgreementKey = crypto.createPrivateKey({
    key: Buffer.concat([X25519_PRIVATE_PREFIX, Buffer.from(vector.botAgreementPrivate, 'base64url')]),
    format: 'der', type: 'pkcs8'
  });
  const bot = {
    id: vector.botID,
    agreementKey: botAgreementKey,
    agreementPublic: Buffer.from(vector.botAgreementPublic, 'base64url')
  };
  const alice = {
    id: vector.aliceID,
    agreementPublic: Buffer.from(vector.aliceAgreementPublic, 'base64url')
  };
  assert.equal(open(Buffer.from(vector.ciphertextFromAlice, 'base64url'), bot, alice).toString(), vector.payload);
  assert.deepEqual(seal(Buffer.from(vector.replyPayload), bot, alice, Buffer.from(vector.nonceFromBot, 'base64url')),
    Buffer.from(vector.expectedBotReply, 'base64url'));
});

test('test user authenticates, acknowledges an app message, and sends an encrypted reply', async (t) => {
  const relay = createRelayServer({ port: 0, host: '127.0.0.1' });
  const address = await relay.listen();
  const url = `ws://127.0.0.1:${address.port}/relay`;
  const dataDir = temporaryDirectory();
  const clientDir = temporaryDirectory();
  const bot = createTestPeer({ dataDir, relayURL: url });
  const client = loadIdentity(clientDir);
  addPeer(dataDir, invitationCode(client));
  t.after(async () => {
    bot.stop();
    fs.rmSync(dataDir, { recursive: true, force: true });
    fs.rmSync(clientDir, { recursive: true, force: true });
    await relay.close();
  });

  const botReady = once(bot.events, 'ready');
  bot.start();
  await botReady;

  const socket = new WebSocket(url);
  const packets = observe(socket);
  t.after(() => socket.close());
  await once(socket, 'open');
  const challenge = await nextPacket(socket, packets, (packet) => packet.type === 'challenge');
  socket.send(JSON.stringify({ type: 'hello', deviceId: client.id,
    signingPublicKey: client.signingPublic.toString('base64url'),
    signature: crypto.sign(null, Buffer.from(challenge.nonce, 'base64url'), client.signingKey).toString('base64url') }));
  await nextPacket(socket, packets, (packet) => packet.type === 'ready');

  const appText = Buffer.from(JSON.stringify({ kind: 'text', text: 'Can you hear me?' }));
  const ciphertext = seal(appText, client, bot.identity).toString('base64url');
  const ack = nextPacket(socket, packets, (packet) => packet.type === 'ack');
  const reply = nextPacket(socket, packets, (packet) => packet.type === 'frame');
  socket.send(JSON.stringify({ type: 'frame', id: crypto.randomUUID(), to: bot.identity.id, ciphertext }));
  assert.equal((await ack).from, bot.identity.id);
  const response = await reply;
  assert.equal(response.from, bot.identity.id);
  assert.deepEqual(JSON.parse(open(Buffer.from(response.ciphertext, 'base64url'), client, bot.identity).toString()),
    { kind: 'text', text: '테스트 유저가 받았어요: Can you hear me?' });
});

test('only valid PrivateCat invitation codes can be paired', (t) => {
  const directory = temporaryDirectory();
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const inviter = loadIdentity(directory);
  const code = invitationCode(inviter);
  assert.equal(parseInvitation(code).id, inviter.id);
  assert.throws(() => parseInvitation('privatecat:not-an-id:abcd:efgh'), /Invalid PrivateCat invitation/);
});
