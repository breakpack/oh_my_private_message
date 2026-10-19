# Client relay contract

The app follows the shared [relay protocol](../Relay/PROTOCOL.md): connect to `/relay`, sign the decoded base64url challenge nonce with the device Ed25519 key, then send authenticated `frame` and `ack` JSON text packets. Device IDs are unpadded base64url SHA-256 of the signing public key. App payloads use a separately paired Curve25519 agreement key and ChaChaPoly; the relay never receives plaintext.

Files use encrypted 512 KiB chunks in individual frames, with per-frame UUID acknowledgements, a shared transfer UUID and SHA-256 digest. The client stores pending frames locally and retries them when its route reconnects. LAN uses the same encrypted frame fields over a one-packet TCP connection discovered and advertised by Bonjour.

LAN pairing sends a signed request containing the sender's route ID and public keys. The receiving device shows an accept/decline prompt in Settings; acceptance sends a signed response, and both devices save the peer only after approval. The QR/code path remains a manual alternative and requires each person to add the other's code.
