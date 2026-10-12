// semut page client. Compiled into the launcher and injected at document
// start, so `window.semut` exists before any of the page's own scripts run.
//
// Every call is one postMessage to the launcher's "semut" handler, which
// replies with a JSON string (WKScriptMessageHandlerWithReply). Names with a
// built-in prefix (dialog., win., clipboard., shell., app.) are answered by
// the launcher itself; every other name goes to the Tov backend.
(() => {
  if (window.semut) return;
  const port = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.semut;
  const listeners = new Map();

  async function call(method, params) {
    if (!port) throw new Error('semut: not running inside a semut window');
    const raw = await port.postMessage({
      method: String(method),
      params: JSON.stringify(params === undefined ? {} : params),
    });
    return raw === undefined || raw === null || raw === '' ? undefined : JSON.parse(raw);
  }

  function on(event, fn) {
    if (!listeners.has(event)) listeners.set(event, new Set());
    listeners.get(event).add(fn);
    return () => off(event, fn);
  }
  function off(event, fn) {
    const set = listeners.get(event);
    if (set) set.delete(fn);
  }

  const semut = {
    api: { call, on, off },
    dialog: {
      openFile: (o = {}) => call('dialog.openFile', o),
      openFiles: (o = {}) => call('dialog.openFile', { ...o, multiple: true }),
      pickFolder: (o = {}) => call('dialog.pickFolder', o),
      saveFile: (o = {}) => call('dialog.saveFile', o),
      alert: (message, detail = '') => call('dialog.alert', { message, detail }),
      confirm: (message, detail = '') => call('dialog.confirm', { message, detail }),
    },
    win: {
      setTitle: (title) => call('win.setTitle', { title }),
      setSize: (width, height) => call('win.setSize', { width, height }),
    },
    clipboard: {
      readText: () => call('clipboard.readText'),
      writeText: (text) => call('clipboard.writeText', { text }),
    },
    shell: {
      openExternal: (url) => call('shell.openExternal', { url }),
    },
    app: {
      info: () => call('app.info'),
      quit: () => call('app.quit'),
    },
    // Called by the launcher (callAsyncJavaScript) for each backend emit.
    _emit(event, data) {
      const set = listeners.get(event);
      if (!set) return;
      for (const fn of [...set]) {
        try { fn(data); } catch (e) { console.error('semut listener for "' + event + '" threw', e); }
      }
    },
  };
  // Dev: mirror the page's console to the terminal running `semut dev`.
  if (window.__SEMUT_DEV__ && port) {
    const fmt = (a) => {
      if (typeof a === 'string') return a;
      if (a instanceof Error) return a.stack || String(a);
      try { return JSON.stringify(a); } catch { return String(a); }
    };
    for (const level of ['log', 'info', 'warn', 'error']) {
      const orig = console[level].bind(console);
      console[level] = (...args) => {
        orig(...args);
        port.postMessage({ method: 'app.log', params: JSON.stringify({ level, text: args.map(fmt).join(' ') }) }).catch(() => {});
      };
    }
    window.addEventListener('error', (e) => console.error('uncaught', e.error || e.message));
    window.addEventListener('unhandledrejection', (e) => console.error('unhandled rejection', e.reason));
  }

  Object.defineProperty(window, 'semut', { value: Object.freeze(semut), enumerable: true });
})();
