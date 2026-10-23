# Lustre presence

This example shows how a Lustre page can reuse an authenticated browser
session when it connects to beryl.

The HTTP server has two demo users. A login route sets an HMAC-signed,
HTTP-only session cookie. The same-origin WebSocket handshake sends that
cookie automatically. The transport validates it once in `on_connect` and
stores the verified user fields in `ConnectSeed.metadata`. The dashboard
channel authorizes the join from that metadata; the client sends no second
token.

Run the example from this directory:

```sh
pnpm start
```

Then open <http://localhost:8002> and select a user.

The default transport origin policy rejects cross-origin browser WebSocket
handshakes. The session secret is generated at startup, so restarting the
example invalidates all demo sessions. A production HTTPS deployment must
also add the `Secure` cookie attribute.
