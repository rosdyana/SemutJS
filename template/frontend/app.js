// The page. `semut` is injected by the launcher before this runs:
//   semut.api.call(name, params)  -> your backend (backend/main.tov)
//   semut.api.on(event, fn)       <- app.emit(event, data) in the backend
//   semut.dialog / win / clipboard / shell / app -> native, no backend needed

const $ = (id) => document.getElementById(id);

function show(el, text, isError = false) {
  el.textContent = text;
  el.classList.toggle('error', isError);
}

async function guarded(el, fn) {
  try {
    await fn();
  } catch (e) {
    show(el, String(e.message || e), true);
  }
}

$('hello-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  guarded($('hello-out'), async () => {
    show($('hello-out'), await semut.api.call('hello', { name: $('name').value }));
  });
});

semut.api.on('tick', ({ uptime }) => {
  $('uptime').textContent = `Backend up ${uptime}s.`;
});

async function loadSysinfo() {
  const info = await semut.api.call('sysinfo');
  $('sysinfo').replaceChildren(
    ...Object.entries(info).flatMap(([k, v]) => {
      const dt = document.createElement('dt');
      const dd = document.createElement('dd');
      dt.textContent = k;
      dd.textContent = String(v);
      return [dt, dd];
    }),
  );
}

$('pick').addEventListener('click', () => guarded($('dir'), async () => {
  const dir = await semut.dialog.pickFolder();
  if (!dir) return;
  $('dir').textContent = dir;
  const entries = await semut.api.call('listDir', { path: dir });
  $('entries').replaceChildren(...entries.map((e) => {
    const li = document.createElement('li');
    li.textContent = e.name + (e.isDir ? '/' : '');
    li.className = e.isDir ? 'dir' : '';
    return li;
  }));
}));

$('save').addEventListener('click', () => guarded($('note-out'), async () => {
  const file = await semut.api.call('saveNote', { text: $('note').value });
  show($('note-out'), 'Saved to ' + file);
}));

$('copy').addEventListener('click', async () => {
  await semut.clipboard.writeText($('note').value);
  show($('note-out'), 'Copied.');
});

$('fetch-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  show($('fetch-out'), 'Fetching…');
  guarded($('fetch-out'), async () => {
    const r = await semut.api.call('fetchStatus', { url: $('url').value });
    show($('fetch-out'), `HTTP ${r.status} · ${r.bytes.toLocaleString()} bytes · ${r.ms} ms`);
  });
});

// Calls queue until the backend is up, so these are safe at load.
guarded($('hello-out'), async () => {
  await loadSysinfo();
  $('note').value = await semut.api.call('loadNote');
});
