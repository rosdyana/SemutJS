# semut app — notes for coding agents

This is a semut app: a native macOS window (WKWebView) showing `frontend/`,
and a backend in **Tov** (`backend/main.tov`) compiled to one native binary.
Tov is TypeScript without `any`, `null` and `==`; read https://tov.sh/llms.txt
before writing backend code.

## Layout

- `semut.json`: name, title, id, version, size ("960x640").
- `frontend/`: plain HTML/CSS/JS, served as files (`index.html` is the entry). No build step.
- `backend/main.tov`: the backend. `backend/semut.tov` is the SDK, copied in
  by the CLI; don't edit it (it gets overwritten).
- `icon.png` (optional, 1024×1024): becomes the app icon on `semut build`.

## Commands

- `semut dev`: opens the window. Frontend edits reload the page, `.tov` edits
  rebuild and restart the backend. The page's `console.*` prints to the terminal.
- `semut check`: `tov check` on the backend. Use `tov check --json backend`
  and apply fixes marked "safe".
- `semut build`: writes `dist/<title>.app` (ad-hoc signed).

## Backend API (Tov)

```ts
import { App, Empty } from "./semut"

type Greet = { name: string }
const app = new App()

app.on("greet", async (p: Greet) => `hi ${p.name}`)    // params are checked against Greet
app.on("now", async (p: Empty) => Date.now())          // no params: type them as Empty
app.onReady(() => app.emit("status", { ok: true }))    // runs each time the page loads
app.emit("progress", { pct: 40 })                      // -> semut.api.on("progress", ...)
app.setTitle("…"); app.setSize(800, 600); app.quit()
app.dataDir()                                          // ~/Library/Application Support/<id> (throws)
app.dev; app.id

try await app.run()                                    // last line: serve calls until the window closes
```

- A handler is `async (p: P) => R`. Whatever it returns goes to the page as JSON.
  When it throws, the page's promise rejects with the error's message.
- Handlers run concurrently. A slow one doesn't block the others.
- Answers and events reach the page in the order the backend produced them.
- The backend has `node:fs` (sync), `node:path`, `process`, `fetch` (HTTP and
  HTTPS), timers and `Bun.serve`.

## Page API (`window.semut`, injected before your scripts)

```js
await semut.api.call('greet', { name: 'x' })     // -> backend
const off = semut.api.on('progress', (d) => …)   // <- app.emit
await semut.dialog.openFile({ title })           // path | null   (openFiles -> string[])
await semut.dialog.pickFolder()                  // path | null
await semut.dialog.saveFile({ name })            // path | null
await semut.dialog.alert(msg, detail); await semut.dialog.confirm(msg, detail)  // bool
semut.win.setTitle(t); semut.win.setSize(w, h)
await semut.clipboard.readText(); semut.clipboard.writeText(t)
semut.shell.openExternal(url)                    // http/https/mailto only
await semut.app.info(); semut.app.quit()
```

Calls made before the backend is up wait in a queue, so it's safe to call at page load.

## Tov gotchas seen while building semut (Tov 0.0.1)

- Inside an *imported* module, `fetch` must be imported explicitly
  (`import { fetch } from "std/http"`). `tov check` passes without the import,
  but `tov build` fails. The entry file gets it as a global.
- There's no `Date` class, only `Date.now()`. `node:os` and other modules
  that aren't built in need Tov's JavaScriptCore build (`TOV_NPM=1`). Calls into
  them throw `JsError`.
- There are no child processes, raw sockets or stdin. Shell out from the page
  side if you must, or wait for Tov to add them.
- `readdirSync` doesn't say whether an entry is a directory. The template
  probes each entry with `readdirSync(child)` to find out.
- A record field can't be a quoted name (`{ "Content-Type": … }`) unless
  the value is typed `Record<string, V>`.
