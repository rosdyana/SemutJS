const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok: !!ok, detail: String(detail) });
const rejects = async (p) => { try { await p; return null; } catch (e) { return e.message || String(e); } };

(async () => {
  const c = semut.api.call;
  try {
    check('typed call', (await c('echo', { text: 'hi' })) === 'hi');

    const big = 'é🐜 "\\\n'.repeat(1) + 'x'.repeat(1 << 20);
    const back = await c('echo', { text: big });
    check('1 MB unicode roundtrip', back === big, back.length);

    const n = await c('nums', { x: 0.1, n: 9007199254740 });
    check('numbers exact', n.x === 0.1 && n.n === 9007199254740 && n.sum === 0.1 + 9007199254740, JSON.stringify(n));

    const bad = await rejects(c('echo', { txt: 'x' }));
    check('param type checked', bad && bad.includes('text'), bad);
    check('thrown error rejects', (await rejects(c('boom'))) === 'kaboom');
    check('unknown method rejects', (await rejects(c('nope'))) === 'no such method: nope');

    const seen = [];
    const off = semut.api.on('seq', (d) => seen.push(d.i));
    const count = await c('burst', { count: 200 });
    off();
    check('emits arrive in order, before the answer', count === 200 && seen.length === 200 && seen.every((v, i) => v === i), seen.length);

    const order = [];
    await Promise.all([
      c('sleep', { ms: 300 }).then(() => order.push('slow')),
      c('sleep', { ms: 10 }).then(() => order.push('fast')),
    ]);
    check('concurrent calls', order.join() === 'fast,slow', order.join());

    const t0 = performance.now();
    for (let i = 0; i < 200; i++) await c('echo', { text: 'x' });
    const per = (performance.now() - t0) / 200;
    check('round-trip latency', per < 20, per.toFixed(2) + ' ms/call');

    check('ready fired', (await c('readyCount')) >= 1);

    const info = await semut.app.info();
    check('builtin app.info', info.id === 'dev.semut.e2e' && info.backend === true, JSON.stringify(info));
    check('backend setTitle', (await c('title', { text: 'from backend' })) === true);
    check('builtin rejects unknown', (await rejects(c('win.nope'))) !== null);

    // Dev loop: run.sh touches backend/main.tov when it sees this line; the
    // CLI rebuilds and restarts the backend. Keep calling throughout.
    const boot = await c('bootId');
    console.log('E2E_RESTART_NOW');
    let okCalls = 0, failed = [], newBoot = boot;
    const deadline = performance.now() + 30000;
    while (newBoot === boot && performance.now() < deadline) {
      try { await c('echo', { text: 'y' }); okCalls++; newBoot = await c('bootId'); }
      catch (e) { failed.push(e.message); }
      await new Promise((r) => setTimeout(r, 20));
    }
    check('dev rebuild restarts backend', newBoot !== boot, `${okCalls} ok calls, ${failed.length} rejected during restart`);
    check('calls work after restart', (await c('echo', { text: 'after' })) === 'after');
    check('only "exited" rejections during restart', failed.every((m) => m.includes('exited')), failed.join(' | '));

    const lost = await rejects(c('crashNow'));
    check('crash rejects in-flight call', lost && lost.includes('exited'), lost);
  } catch (e) {
    check('no unexpected throw', false, e.stack || e);
  }
  document.getElementById('log').textContent = JSON.stringify(results, null, 2);
  console.log('E2E_REPORT ' + JSON.stringify(results));
  await semut.app.quit();
})();
