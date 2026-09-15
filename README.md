# molten.el

A small, pure-Elisp frontend for executing arbitrary source regions on a Jupyter
Server and keeping their output beside the source, including across Emacs restarts.
No source text is inserted or rewritten to store output.

## Install

Requires Emacs 27.1 or newer. Install the **pure-Elisp `websocket` package**
(`M-x package-install RET websocket RET`, available from GNU ELPA), put this
repository on `load-path`, and add this to your init file:

```elisp
(add-to-list 'load-path "/path/to/molten-el")
(require 'molten)
(setq molten-server-url "http://127.0.0.1:18888")
```

Loading Molten and restoring output work even without `websocket` installed.
It is loaded only when opening kernel channels. The client requires no Python,
ZMQ, `emacs-zmq`, `emacs-jupyter`, `jupyter_client`, native module, or native JSON
library. Jupyter Server and the language kernel run on the server machine.
HTTPS uses whatever TLS support your Emacs provides; SSH-forwarded HTTP works
without client TLS support.

## Minimal remote workflow

```sh
# remote machine (with Jupyter Server, ipykernel and matplotlib installed)
jupyter server --no-browser --ip=127.0.0.1

# Termux / local machine
ssh -L 18888:127.0.0.1:8888 workstation
```

Keep the tunnel running. In Emacs:

1. Open an ordinary `.py` file.
2. Run `M-x molten-connect`, enter `http://127.0.0.1:18888`, then enter the token
   printed by Jupyter Server. Enter the base URL separately from the token;
   deployment prefixes such as `/jupyter/user/me` are supported.
3. Run `M-x molten-start-kernel` and accept `python3`, or use
   `M-x molten-select-kernel` to choose an existing kernel. Wait for
   “Molten kernel connected”.
4. Select any nonempty region and run `M-x molten-eval-region`.

For example, execute the lines between the two comments:

```python
# unique plotting example starts here
%matplotlib inline
import matplotlib.pyplot as plt
print("hello from the workstation")
plt.plot([1, 2, 3], [1, 4, 9])
plt.show()
# unique plotting example ends here
```

`%matplotlib inline` is an IPython magic: you can execute it once in a scratch
buffer instead of keeping it in a Python script. Kernel code and file access run
on the workstation; local source filenames are only anchors and are not sent as
remote working-directory paths.

Text appears after the selection using an overlay. Supported PNG/SVG images take
precedence over plain text when Emacs can render them. A terminal-only Emacs may
show the text fallback or an image indication; the image is still saved. Actual
image rendering requires an Emacs display with image support, such as a graphical
Emacs session under Termux:X11. No terminal graphics protocol is implemented.
Large text and tracebacks show a compact indication. Put point within the source
and use `molten-show-output` to inspect the full output in an ordinary buffer.

## Commands

| Command | Action |
| --- | --- |
| `molten-connect` | Set server and memory-only token; verify REST access |
| `molten-start-kernel` | Start a kernel spec and open its channels |
| `molten-select-kernel` | List and connect to an existing kernel |
| `molten-eval-region` | Execute exactly BEG through END asynchronously |
| `molten-eval-line` | Execute the current line |
| `molten-reeval` | Execute the current live range of the record at point |
| `molten-show-output` | Show the full record at point |
| `molten-clear-output` | Hide that output, including after reopening; keep history |
| `molten-output-history` | Browse all this file's records, including hidden/orphaned ones |
| `molten-interrupt` | Interrupt the selected kernel |
| `molten-restart-kernel` | Restart it, losing its variables |
| `molten-kill-kernel` | Shut it down; saved output remains |
| `molten-mode` | Toggle this buffer's output presentation |

The current server/kernel selection is shared by buffers. Re-executing the same
live marker range replaces its displayed result and keeps both records in history.
History entries are buttons opening full-output buffers. These buffers are
snapshots; invoke the command again to refresh a running execution's full output.
No default key bindings or cell selection rules are imposed.

## Persistence and freshness

By default records live under `$XDG_STATE_HOME/molten/`, falling back to
`~/.local/state/molten/`. Customize `molten-state-directory` **before** opening
source files if you want another directory.

- `records/<execution-id>.json`: one atomically replaced, versioned document per
  execution, with source, context, original line range, SHA256, timestamp, kernel
  identifiers, execution count/state and blob references.
- `blobs/<sha256>`: deduplicated payloads, including raw PNG bytes and UTF-8
  text/SVG. Large streams and tracebacks also use blobs. Payload hashes are
  checked on restoration.

Output updates are saved as they arrive, not only when Emacs exits. Files use
mode 0600 and directories 0700. Only allowlisted execution metadata is serialized;
server tokens and transport/session objects are never stored. Executed source and
its output are saved verbatim, so anything your code prints is part of the record.
Unsaved, non-file buffers keep history only for the current Emacs session.
Storage errors produce a warning; partial records from disconnected runs survive.
There is no retention policy or blob garbage collector yet. Separate execution
IDs allow concurrent Emacs processes to add history; active buffers do not watch
for another process's newly written records.

With `(require 'molten)` in your init file, visiting a file automatically restores
saved outputs without contacting a server. Set `molten-auto-restore` to nil to opt
out and enable `molten-mode` manually instead.

Restoration widens the buffer temporarily and follows conservative rules:

1. A unique exact occurrence of the executed source is **fresh**, even if moved.
   If unchanged enclosing context identifies added characters within the range,
   it is **stale**, even when the old source remains as a substring.
2. If the exact source is absent, unique nonempty context on both sides can
   identify the changed range as **stale**. Up to 120 characters on each side
   are retained. Freshness is recalculated on live edits too.
3. Duplicate source matches, changed surrounding context, or insufficient
   context produce **orphaned** records. They stay in history without overlays.
   An old line number alone is never enough to attach output.

This means changed regions at the beginning/end of a file may be orphaned.
Staleness describes only changes to the executed source: edits to imports,
other variables or dependencies do not affect it. Restarting a kernel does not
make unchanged source “stale”.

## Tests

Run the offline suite (no websocket package, Python, network or Jupyter needed):

```sh
sh test/run-tests.sh
make compile
```

The suite includes mocked HTTP/WebSocket dispatch, source anchoring, bookkeeping,
MIME/blob round trips, corruption handling, overlay replacement and image fallback.
`test/load-minimal.el` blocks external processes, native module loading and native
JSON functions while loading the entire package. `test/restart.el` runs in four
separate Emacs processes: save and exit, reopen fresh, reopen after an external
edit as stale, and reopen duplicated source as orphaned.

For the real-server smoke test, start a local server and use its token:

```sh
jupyter server --no-browser --ip=127.0.0.1 --port=18991
mkdir -p /tmp/molten-smoke
MOLTEN_TEST_URL=http://127.0.0.1:18991 \
MOLTEN_TEST_TOKEN=YOUR_TOKEN MOLTEN_TEST_DIR=/tmp/molten-smoke \
  emacs --batch -Q -L . -L /path/to/websocket-package -l test/integration.el
MOLTEN_TEST_DIR=/tmp/molten-smoke \
  emacs --batch -Q -L . -l test/integration-restore.el
```

The test creates its own kernel, executes text and matplotlib PNG output, restarts
and interrupts the kernel, and shuts it down in cleanup. The next Emacs process
restores its saved output offline. The server needs the `python3` kernel and
matplotlib. Run this test from the repository root.

Manual visual/crash-recovery acceptance procedure:

1. Follow the SSH workflow and execute the plotting region above. Check the text
   and image (or terminal fallback), then re-execute: one displayed result, two
   history records. The source buffer should remain unmodified by execution.
2. Save your source edits. Once output is displayed, exit Emacs. To test abrupt
   termination, use `kill -9 EMACS_PID` on this test Emacs process instead.
3. Stop the kernel/server and tunnel. Start a **new** Emacs with Molten loaded,
   open the file, and verify the output is restored as fresh, including its image.
4. Close Emacs. Change a literal inside the region externally while leaving the
   surrounding comments intact. Reopen: the saved output should be stale.
5. Restore the original source and duplicate that exact region elsewhere in the
   file. Reopen: the record should appear only as orphaned in output history.

Validated here with Emacs 30.2, websocket 1.12 and Jupyter Server 2.18.0.
Graphical image presentation and the actual Termux/SSH path require the manual
check; the automated real-server test runs headlessly over loopback.

## Layers and scope

`molten-core.el` owns session/execution/anchor/output structs and the execution
update hook. `molten-jupyter.el` translates REST and channels traffic into those
records. `molten-store.el` persists them; `molten-display.el` presents them;
`molten.el` supplies commands and connects update subscribers. Session IDs identify
Molten clients, not notebook documents or Jupyter REST session resources.

The backend uses the default channels protocol (no optional v1 subprotocol),
handles legacy binary envelopes as well as JSON frames, correlates parent IDs,
and waits for both shell `execute_reply` and IOPub `idle`. Late correlated output
is retained. Requests explicitly disable stdin. After a dropped connection,
select the existing kernel again; unfinished runs are marked disconnected and
are never automatically retried. Server output-rate limits still apply.

Protocol references consulted before implementation:

- [Jupyter Server REST API](https://jupyter-server.readthedocs.io/en/latest/developers/rest-api.html)
- [WebSocket wire protocols](https://jupyter-server.readthedocs.io/en/latest/developers/websocket-protocols.html)
- [Jupyter messaging specification](https://jupyter-client.readthedocs.io/en/stable/messaging.html)
- [Server authentication](https://jupyter-server.readthedocs.io/en/latest/operators/security.html)

Only status, streams, execution results, display data, errors and execution
replies are handled. MIME support is text/plain, image/png and image/svg+xml.
Widgets, HTML/JS, Plotly, Vega, stdin, completion, inspection, notebook editing,
cell/Quarto parsing, alternative transports and DAG/IPyflow providers are outside
this MVP. See [PLAN.md](PLAN.md) for the original implementation plan.

License: GPL-3.0-or-later.
