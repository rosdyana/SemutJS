# semut

Small native desktop apps: an HTML/CSS/JS frontend in the macOS webview,
and a backend written in [Tov](https://tov.sh) and compiled to a native
binary. It follows the shape of [tinyjs](https://tinyjs.app), but the backend
is Tov instead of txiki.js.

*Semut* is Indonesian for ant.

```
semut new myapp && cd myapp
semut dev        # window opens; frontend edits reload, .tov edits rebuild + restart
semut build      # dist/myapp.app, ad-hoc signed, ~1.9 MB
```

## What it borrows from tinyjs, and what changes

tinyjs packages each app as three pieces:

1. **A native launcher** that owns the window and the OS webview (WebKit on
   macOS), the menu bar and the native dialogs.
2. **A JavaScript backend** running on txiki.js (QuickJS + libuv, about 5.6 MB),
   with full system access.
3. **A bridge** between them: newline-framed `CALL`/`RET`/`EVAL` lines over a
   Unix socket in a private temp dir, so nothing listens on a port. The page
   sees it as `tiny.api.call(name, params)` and `tiny.api.on(event, fn)`.

Tov is a compiler. It reads TypeScript syntax, type-checks it more strictly
(no `any`, `null` or `==`; `int` and `f64` are separate types; a call that can
fail is marked `try`), writes C, and has clang build one native binary
around its runtime (event loop, HTTP server and client, BoringSSL). There's no
VM and no garbage collector; memory is reference-counted.

semut keeps the first and third pieces and replaces the second with a Tov
binary. That removed one constraint and forced one change:

- **The backend ships as a compiled binary.** The app has no runtime of its own:
  about 100 KB of launcher plus a Tov binary of about 1.7 MB. Most of the
  binary is the TLS stack behind `fetch`.
- **The bridge is HTTP over a Unix socket.** Tov has no FFI, raw sockets,
  stdin or child processes, so the tinyjs line protocol can't be ported
  directly. Tov's `fetch` does support Bun's `{ unix: path }` option, so the
  launcher runs a small HTTP/1.1 server on a socket in a 0700 temp dir and
  the backend acts as its client. There is still no port.

```
 page (WKWebView)                 launcher (AppKit, ~100 KB)                 backend (Tov binary)
 semut.api.call ──postMessage──▶  inbox ──────── GET /next (long poll) ───▶  app.on handlers
 semut.api.on   ◀─callAsyncJS───  apply ◀─────── POST /out (ordered batch) ── ret / emit / title / quit
 semut.dialog… ──▶ answered natively (NSOpenPanel, NSAlert, NSPasteboard)
```

- **Calls.** The page posts `{method, params}` through
  `WKScriptMessageHandlerWithReply`, so every call is a real promise with no
  id bookkeeping on the page. The launcher queues the call. The backend's
  long poll picks up everything queued at once. Each handler runs as its own
  task.
- **Answers and events** go through one outbox on the backend, sent by one
  `POST /out` at a time. A handler that emits and then returns is seen by
  the page in that order.
- **Values are JSON text end to end.** The launcher never re-encodes numbers or
  strings (`0.1` stays `0.1`, 1 MB of emoji survives unchanged). Events reach the
  page through `callAsyncJavaScript` arguments, never spliced into source.
- **Typed params.** `app.on("x", async (p: P) => …)` runs `JSON.parse` against
  `P`. Tov checks the shape, so a wrong param rejects the page's promise
  with a readable message instead of reaching the handler.

| | backend | shipped size | ports | system access |
|---|---|---|---|---|
| Electron | Node.js + bundled Chromium | ≥ 150 MB | none | full |
| tinyjs | txiki.js (JS, interpreted) | ~6 MB | none | full: fs, sockets, processes, FFI, sqlite |
| **semut** | Tov (TypeScript-shaped, compiled) | **~1.9 MB** | none | what Tov has: fs, path, process, fetch, timers, Bun.serve |

## Layout

```
semut                    the CLI (POSIX sh; it has to spawn clang/tov, which Tov can't yet)
install.sh               installer: prerequisites, Tov, clone, PATH link, launcher
native/launcher-macos.m  window, webview, native built-ins, the socket server
runtime/semut.js         page client (compiled into the launcher, injected at document start)
runtime/semut.tov        backend SDK (copied into each app's backend/)
template/                what `semut new` copies
docs/AGENTS.md           API + gotchas, copied into each app for coding agents
test/e2e/                self-driving end-to-end test (./test/e2e/run.sh)
```

## Install

semut has no prebuilt binaries. You install it from source, and every app
you build compiles on your own Mac.

### What you need

| | why | check | get it |
|---|---|---|---|
| macOS 12+ on Apple silicon | the launcher is AppKit + WKWebView; Tov targets arm64 macOS | `sw_vers` | |
| Xcode command-line tools | clang builds the launcher and Tov's output; xxd embeds the page client | `xcode-select -p` | `xcode-select --install` |
| git | clones semut and Tov | `git --version` | ships with the tools above |
| Rust, recent stable | builds the Tov compiler (one time) | `rustc --version` | [rustup.rs](https://rustup.rs), then `rustup update stable` |
| Tov | compiles your backend | `tov version` | the installer below gets it, or `curl -fsSL https://tov.sh/install.sh \| sh` |

You don't need Node, npm or full Xcode.

### Option A: one command

```sh
curl -fsSL https://raw.githubusercontent.com/rosdyana/semutjs/main/install.sh | sh
```

[`install.sh`](install.sh) runs these steps, and stops with a fix if one fails:

1. Checks for macOS, git, clang and xxd.
2. Installs Tov if `tov` isn't on your PATH. This builds Tov from source with
   cargo and takes a few minutes.
3. Clones semut into `~/.semut/src`. If a clone is already there, it updates it.
4. Links `~/.local/bin/semut` to the clone.
5. Builds the launcher once and caches it in `~/Library/Caches/semut`.

You can change these locations with `SEMUT_DIR=…`, `SEMUT_BIN=…` and
`SEMUT_REPO=…` (to point at a fork).

### Option B: by hand from a clone

```sh
# 1. Tov (skip if `tov version` already works)
curl -fsSL https://tov.sh/install.sh | sh
. "$HOME/.cargo/env"                 # puts ~/.cargo/bin (where tov lives) on PATH
tov version                          # -> tov 0.0.1

# 2. semut
git clone https://github.com/rosdyana/semutjs ~/code/semutjs
cd ~/code/semutjs
sh install.sh                        # uses this checkout instead of cloning again
#   or link it yourself:  ln -s "$PWD/semut" ~/.local/bin/semut && ./semut launcher
```

Run `install.sh` from inside a checkout and it uses that checkout. Your
edits to the launcher or the SDK then apply right away (see "Hacking on semut"
below).

### Put it on your PATH

The installer tells you if `~/.local/bin` or `~/.cargo/bin` is missing from
your PATH. For zsh:

```sh
echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Check the install

```sh
semut doctor
```

```
semut 0.1.0 at /Users/you/.semut/src
  ok    macOS 15.5
  ok    clang: Apple clang version 17.0.0
  ok    xxd
  ok    tov: /Users/you/.cargo/bin/tov (tov 0.0.1)
  ok    launcher: /Users/you/Library/Caches/semut/launcher
  ok    semut on PATH: /Users/you/.local/bin/semut
All good.
```

### Make and build your first app

```sh
semut new myapp          # scaffolds ./myapp
cd myapp
semut dev                # opens the window. Ctrl-C to quit
semut build              # -> dist/myapp.app (about 1.9 MB); `semut build -Os` for smaller
open dist/myapp.app
```

`semut build` signs the app ad hoc, which is enough to run it on your own
Mac. To give it to other people, sign it with your Developer ID and notarize it:

```sh
codesign --force --deep --options runtime --sign "Developer ID Application: You (TEAMID)" dist/myapp.app
ditto -c -k --keepParent dist/myapp.app myapp.zip
xcrun notarytool submit myapp.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/myapp.app
```

### Update and uninstall

```sh
git -C ~/.semut/src pull && semut launcher       # update to the latest semut
rm -rf ~/.semut ~/.local/bin/semut ~/Library/Caches/semut  # uninstall semut
# Tov: cargo uninstall tov && rm -rf ~/.tov
```

### Troubleshooting

| symptom | fix |
|---|---|
| Tov's build fails with ``error[E0658]: `if let` guards are experimental`` | Your Rust is too old for Tov. Run `rustup update stable` and install again. To leave your default toolchain alone, use a newer one already installed: `cargo +<version> install --locked --path ~/.tov/src/crates/tov` |
| `tov not found` | Tov is in `~/.cargo/bin`. Run `. "$HOME/.cargo/env"` or add it to your PATH |
| `semut: command not found` | Add `~/.local/bin` to your PATH, or run the script by its full path |
| `xcrun: error: invalid active developer path` | Run `xcode-select --install` |
| `backend didn't build` on `semut dev` | Run `semut check` (or `tov check --json backend`) and apply the fixes marked safe |
| `tov check` passes but `tov build` fails with ``unknown name `fetch` `` | In a module other than `main.tov`, add `import { fetch } from "std/http"` |
| The window opens blank | Check the terminal: `semut dev` prints the page's console and errors there |

### Hacking on semut

- After changing `native/launcher-macos.m` or `runtime/semut.js`, the
  launcher rebuilds on the next `semut dev` or `build` (or run `semut launcher`).
- After changing `runtime/semut.tov`, each app picks up the new copy in
  `backend/` on its next `dev`, `check` or `build`.
- Run the end-to-end test after any change: `./test/e2e/run.sh`. It opens a
  window for a few seconds and prints `17/17 passed`.

## The API

Backend (`backend/main.tov`):

```ts
import { App, Empty } from "./semut"
type Greet = { name: string }

const app = new App()
app.on("greet", async (p: Greet) => `hi ${p.name}`)
app.onReady(() => app.emit("status", { ok: true }))
try await app.run()
```

Page:

```js
await semut.api.call('greet', { name: 'ant' })   // "hi ant"
semut.api.on('status', (s) => …)
await semut.dialog.pickFolder()
```

The full surface is in [docs/AGENTS.md](docs/AGENTS.md).

## Verified

`test/e2e/run.sh` drives a real window through `semut dev` and checks 17 behaviors:

- typed calls and param checking
- error and unknown-method rejection
- a 1 MB Unicode round trip and exact numbers
- 200 events arriving in order before their call's answer
- concurrent calls
- the page-ready hook and the native built-ins
- a mid-run `.tov` edit that rebuilds and restarts the backend while the page keeps calling
- a crash rejecting the call in flight

Round-trip latency is about 0.2 ms per call. On exit no processes or temp dirs
are left behind.

## Not done (yet)

- **macOS only.** Tov doesn't target Windows yet. A Linux launcher (WebKitGTK)
  would work with the same backend and protocol.
- **A smaller native surface than tinyjs.** semut has dialogs, title, size,
  clipboard, external links and the app info. It doesn't have tray, global
  hotkeys, notifications, multiple windows, custom menus, auto-update or
  notarization.
- **The backend can only do what Tov can.** There are no subprocesses, raw
  sockets, sqlite or FFI. npm packages need Tov's JavaScriptCore build.
- **No Vite or TypeScript frontend templates.** Any static build output dropped
  into `frontend/` works.
