'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const WebSocket = require('ws');
const { createRelayServer } = require('../server');

function messageQueue(ws) {
  const packets = [];
  const waiters = [];
  ws.on('message', (data) => {
    const packet = JSON.parse(data.toString());
    const waiter = waiters.shift();
    if (waiter) waiter.resolve(packet);
    else packets.push(packet);
  });
  return {
    packets,
    next() {
      if (packets.length) return Promise.resolve(packets.shift());
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('Timed out waiting for relay packet')), 1500);
        waiters.push({ resolve: (packet) => { clearTimeout(timeout); resolve(packet); } });
        ws.once('error', reject);
      });
    }
  };
}

async function connect(url) {
  const ws = new WebSocket(url);
  const queue = messageQueue(ws);
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  const challenge = await queue.next();
  const keys = crypto.generateKeyPairSync('ed25519');
  const spki = keys.publicKey.export({ format: 'der', type: 'spki' });
  const rawPublicKey = spki.subarray(-32);
  const deviceId = crypto.createHash('sha256').update(rawPublicKey).digest('base64url');
  ws.send(JSON.stringify({
    type: 'hello', deviceId,
    signingPublicKey: rawPublicKey.toString('base64url'),
    signature: crypto.sign(null, Buffer.from(challenge.nonce, 'base64url'), keys.privateKey).toString('base64url')
  }));
  const ready = await queue.next();
  assert.equal(ready.type, 'ready');
  return { ws, deviceId, pending: queue.packets, next: queue.next };
}

test('routes opaque frames and acknowledgements only to live peers; offline frames are not queued', async (t) => {
  const relay = createRelayServer({ port: 0, host: '127.0.0.1' });
  const address = await relay.listen();
  const url = `ws://127.0.0.1:${address.port}/relay`;
  t.after(async () => relay.close());

  const alice = await connect(url);
  const bob = await connect(url);
  t.after(() => { alice.ws.terminate(); bob.ws.terminate(); });

  alice.ws.send(JSON.stringify({ type: 'frame', id: 'msg-1', to: bob.deviceId, ciphertext: 'opaque_ciphertext' }));
  assert.deepEqual(await bob.next(), {
    type: 'frame', id: 'msg-1', from: alice.deviceId, ciphertext: 'opaque_ciphertext'
  });

  bob.ws.send(JSON.stringify({ type: 'ack', id: 'msg-1', to: alice.deviceId }));
  assert.deepEqual(await alice.next(), { type: 'ack', id: 'msg-1', from: bob.deviceId });

  const offlineId = crypto.createHash('sha256').update('offline').digest('base64url');
  alice.ws.send(JSON.stringify({ type: 'frame', id: 'msg-2', to: offlineId, ciphertext: 'opaque' }));
  assert.deepEqual(await alice.next(), { type: 'unavailable', id: 'msg-2' });

  const offlinePeer = await connect(url);
  t.after(() => offlinePeer.ws.terminate());
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(offlinePeer.pending.length, 0, 'relay must not replay frames sent while offline');
  assert.equal(relay.routes.size, 3, 'only live socket routes are retained');
});

test('rejects a device that cannot sign the issued challenge', async (t) => {
  const relay = createRelayServer({ port: 0, host: '127.0.0.1' });
  const address = await relay.listen();
  t.after(async () => relay.close());

  const ws = new WebSocket(`ws://127.0.0.1:${address.port}/relay`);
  const queue = messageQueue(ws);
  t.after(() => ws.terminate());
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  const challenge = await queue.next();
  const keys = crypto.generateKeyPairSync('ed25519');
  const rawPublicKey = keys.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  const deviceId = crypto.createHash('sha256').update(rawPublicKey).digest('base64url');
  ws.send(JSON.stringify({
    type: 'hello', deviceId,
    signingPublicKey: rawPublicKey.toString('base64url'),
    signature: crypto.sign(null, Buffer.from(`${challenge.nonce} altered`), keys.privateKey).toString('base64url')
  }));

  const error = await queue.next();
  assert.equal(error.type, 'error');
  assert.equal(error.message, 'Invalid signature');
  assert.equal(relay.routes.size, 0, 'unauthenticated devices must not get a live route');
});
