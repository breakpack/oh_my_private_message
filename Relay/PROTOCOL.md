# Private Chat relay protocol

The relay accepts WebSocket connections at `/relay` (use `wss://` behind a TLS reverse proxy for internet use). It forwards frames only while both peers are connected. It has no account system, database, message/file storage, or offline queue. Its only application state is the in-memory map from authenticated device IDs to live sockets; restarting the service clears that map.

Every packet is a UTF-8 JSON text frame. IDs and binary values use unpadded base64url. Device IDs are `base64url(SHA-256(raw Ed25519 public key))` and must be 43 characters for a 32-byte key.

## Authenticate a live route

1. On connection, the server sends `{"type":"challenge","nonce":"<32 random bytes, base64url>"}`.
2. The client sends `{"type":"hello","deviceId":"<derived ID>","signingPublicKey":"<32 raw Ed25519 public-key bytes, base64url>","signature":"<Ed25519 signature of decoded nonce, base64url>"}`.
3. The server validates the key-derived ID and signature, registers the socket, and replies `{"type":"ready"}`. A new authenticated connection for the same ID replaces its previous live route.

This proves control of a device signing key and prevents another key from claiming its route. The app must still check that `from` is an approved peer and encrypt/decrypt application data with its own paired keys; the relay does not decide pair approval.

## Forward encrypted data

Sender to relay:

```json
{"type":"frame","id":"<unique message ID>","to":"<recipient device ID>","ciphertext":"<opaque base64url encrypted bytes>"}
```

Relay to recipient:

```json
{"type":"frame","id":"<same ID>","from":"<authenticated sender device ID>","ciphertext":"<unchanged ciphertext>"}
```

The relay replies `{"type":"unavailable","id":"<ID>"}` when `to` has no live route. It drops that frame; the sending app keeps it in its local queue and retries after reconnecting. The relay does not deduplicate IDs or retain retry state.

Recipient to relay acknowledgement:

```json
{"type":"ack","id":"<message ID>","to":"<sender device ID>"}
```

Relay to sender:

```json
{"type":"ack","id":"<same ID>","from":"<authenticated recipient device ID>"}
```

Acknowledgements are transient and forwarded only to a live sender. The client owns durable queue removal and duplicate suppression using the message ID. Files use the same encrypted `frame` envelope; chunking and reassembly happen in the clients.

## Limits

The service accepts JSON text frames up to 1 MiB. Applications should keep each encrypted frame below that limit (including JSON overhead). The HTTP `GET /healthz` endpoint returns `200 ok` for container health checks. Unknown paths return `404`; invalid packets close the WebSocket with policy code `1008`.
