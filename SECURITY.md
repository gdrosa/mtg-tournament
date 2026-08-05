# Security policy

## Supported versions

The project is in early development. Security fixes are applied to the latest
published version only.

## Reporting a vulnerability

Use GitHub private vulnerability reporting when it is available for the
repository. If it is unavailable, contact the repository owner privately before
opening an issue. Do not include live session tokens, signing keys, OAuth
credentials, private tournament exports, or identifying screenshots in a public
issue.

Include the affected version, reproduction conditions, expected impact, and a
minimal sanitized proof of concept.

## Deployment boundaries

The embedded server is designed for a trusted private LAN. It uses cleartext
HTTP/WebSocket and bearer session tokens. Do not forward port `8080`, expose the
host directly to the internet, or run an event on a hostile shared network.

Online mode reaches the host only through the included Cloudflare relay over
HTTPS/WSS. The relay exposes player commands, never organizer commands, and is
designed not to persist tournament payloads. Keep Wrangler credentials out of
the repository and do not reuse or publish a room's host secret. See
[Online hosting](docs/ONLINE_HOSTING.md) for the deployment and trust model.
