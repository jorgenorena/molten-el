# MVP implementation plan

Protocol review (2026-09-15):
- https://jupyter-server.readthedocs.io/en/latest/developers/rest-api.html
- https://jupyter-server.readthedocs.io/en/latest/developers/websocket-protocols.html
- https://jupyter-client.readthedocs.io/en/stable/messaging.html
- https://jupyter-server.readthedocs.io/en/latest/operators/security.html

Use built-in url/json and lazily loaded pure-Elisp websocket.el. REST manages
kernels; the default channels protocol carries JSON with channel/header/parent
header/metadata/content, plus legacy binary framing when present. Authenticate
with an Authorization header, never a stored URL query. Execute asynchronously
with allow_stdin=false and finish only after execute_reply plus IOPub idle.

1. Core structs and events: session, execution, anchor, output; transport-neutral
   execution updates and live markers. Preserve history independently of overlays.
2. Backend: bounded synchronous REST control calls, asynchronous channels socket,
   parent-ID dispatch, explicit disconnection/restart states.
3. Store: atomic per-execution JSON, SHA256 blobs, credential-free allowlisted
   metadata. Relocate by unique exact source, then unique surrounding context;
   never infer changed locations solely from old line numbers.
4. Presentation/public commands: overlays, image preference and text fallback,
   ordinary full-output/history buffers, offline mode restoration and live staleness.
5. ERT mocks, separate-process persistence tests, and real-server manual workflow.

No native modules, client Python processes, parsing of cells, or graph provider.
