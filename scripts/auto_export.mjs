/* QuadroBuilder — automatic Optimo export.
 *
 * Drives the real Optimo UI in a persistent Chromium profile and downloads the
 * six reports, then runs the Python pipeline and publishes docs/index.html.
 *
 *   node scripts/auto_export.mjs            # scheduled run (headless)
 *   node scripts/auto_export.mjs --login    # visible window, sign in by hand
 *   node scripts/auto_export.mjs --no-push  # build locally, skip git push
 *
 * SESSIONS. Optimo issues a 15-minute JWT renewed behind the scenes by an
 * HttpOnly refresh cookie. The session dies on its own after a while, which used
 * to strand the scheduler until someone logged in by hand. If a credential has
 * been stored (scripts/optimo_credential.ps1 -Set) this signs itself back in;
 * otherwise it exits with EXIT.AUTH so the scheduler can say so precisely.
 *
 * EXIT CODES — the scheduler keys its retry policy off these, so keep them
 * meaningful: retrying an auth failure every five minutes never helps.
 *   0 ok   1 transient (retry)   2 auth required (human)   3 page/selector
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, renameSync, rmSync, statSync, readFileSync, writeFileSync, copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const RAW = join(ROOT, 'data', 'raw');
const PROFILE = join(ROOT, '.optimo-profile');           // gitignored session store
const TMP = join(ROOT, '.dl');                            // scratch download dir
const DIAG = join(ROOT, 'logs', 'diag');                  // failure screenshots / HTML
const SIZES = join(RAW, '.last-good-sizes.json');
// Browsers live inside the repo, not %LOCALAPPDATA%\ms-playwright. The default
// location is not guaranteed to be the same directory for every process on this
// machine, and a scheduled run that cannot see the browser fails with a bogus
// "Executable doesn't exist" error. Must be set BEFORE playwright is imported,
// which is why the import below is dynamic.
process.env.PLAYWRIGHT_BROWSERS_PATH ||= join(ROOT, '.playwright-browsers');
const { chromium } = await import('playwright');

const ARGS = new Set(process.argv.slice(2));
const LOGIN = ARGS.has('--login');
const PUSH = !ARGS.has('--no-push');

const EXIT = { OK: 0, TRANSIENT: 1, AUTH: 2, PAGE: 3 };
const ORIGIN = 'https://dashboard.optimo.ge';

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const die = (m, code = EXIT.TRANSIENT) => { console.error('\n  ✗ ' + m + '\n'); process.exit(code); };

class Fail extends Error {
  constructor(msg, code, retryable) { super(msg); this.code = code; this.retryable = retryable; }
}
const authFail = (m) => new Fail(m, EXIT.AUTH, false);
const pageFail = (m) => new Fail(m, EXIT.PAGE, true);

// Local date, not UTC. The machine is UTC+4, so toISOString() before 04:00 local
// yields YESTERDAY and every ranged report would silently stop a day short.
const TODAY = new Date().toLocaleDateString('en-CA');
const FROM = '2024-01-01';
const range = (path) => `${path}${path.includes('?') ? '&' : '?'}dateFrom=${FROM}&dateTo=${TODAY}`;

/* The six exports, in order. `menu` picks the line-item option from the caret
   dropdown; a plain green button otherwise. `min` is a floor well under the
   smallest genuine file, to catch a truncated download. */
const JOBS = [
  { name: 'sales_lines_retail.xlsx', label: 'retail line items', min: 40000,
    url: range('/reports/sale-orders/retail?pageIndex=1&sortField=orderDate&sortOrder=DESC&pageSize=20'), menu: 'products' },
  { name: 'sales_lines_entity.xlsx', label: 'B2B line items', min: 7000,
    url: range('/reports/sale-orders/entity?pageIndex=1&sortField=orderDate&sortOrder=DESC&pageSize=20'), menu: 'products' },
  { name: 'stock_on_hand.xlsx', label: 'stock on hand', min: 20000,
    url: '/stockholdings?pageIndex=1&sortField=stockItemName&sortOrder=DESC&pageSize=20' },
  { name: 'stock_movement.xlsx', label: 'stock movement', min: 20000,
    url: range('/reports/stock-movement?pageIndex=1&pageSize=20'), menu: null },
  { name: 'supplies_ledger.xlsx', label: 'supplies ledger', min: 60000,
    url: range('/reports/supplies?pageIndex=1&pageSize=20'), menu: null },
  { name: 'daily_statistics.xlsx', label: 'daily statistics', min: 7000,
    url: '/statistics/general', menu: null, stats: true },
];

const isLoginUrl = (u) => /\/login|\/auth|identity|signin/i.test(u);

/* ---------------------------------------------------------------- session --*/

/* The stored token is a JSON wrapper: {"token":"<jwt>"} — splitting the wrapper
   on '.' slices mid-token and yields garbage. Returns expiry in ms, or null. */
async function tokenExpiry(page) {
  return page.evaluate(() => {
    try {
      const raw = localStorage.getItem('accessToken');
      if (!raw) return null;
      let jwt = raw;
      try { const o = JSON.parse(raw); if (o && typeof o.token === 'string') jwt = o.token; } catch { }
      const parts = jwt.split('.');
      if (parts.length !== 3) return null;
      const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
      const claims = JSON.parse(atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4)));
      return typeof claims.exp === 'number' ? claims.exp * 1000 : null;
    } catch { return null; }
  });
}

/* Liveness has to be behavioural, not a token check. Between runs the stored
   token is ALWAYS expired — it lives 15 minutes and the slots are hours apart —
   and the app renews it a second or two after the page loads. Treating a stale
   token as logged-out would fail every healthy scheduled run. So: load the app,
   then wait for it to either redirect to the login screen or mint a fresh token. */
async function sessionState(page) {
  await page.goto(ORIGIN + '/dashboard', { waitUntil: 'domcontentloaded' });
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (isLoginUrl(page.url())) return 'LOGGED_OUT';
    const exp = await tokenExpiry(page);
    if (exp && exp > Date.now() + 60000) return 'OK';     // renewed => refresh honoured
    await page.waitForTimeout(500);
  }
  // No redirect and no fresh token. Ambiguous — let the first export decide
  // rather than failing a run that may just be slow.
  return 'UNKNOWN';
}

/* Reads the DPAPI-encrypted credential. The password crosses a stdout pipe from
   a direct child process — never an argv, which is world-readable in the process
   list — and is never logged or written to disk here. */
function storedCredential() {
  const script = join(ROOT, 'scripts', 'optimo_credential.ps1');
  if (!existsSync(script)) return null;
  try {
    const out = execFileSync('powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-Emit'],
      { cwd: ROOT, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 30000 });
    const j = JSON.parse(out.trim() || '{"ok":false}');
    return j.ok ? j : null;
  } catch { return null; }
}

async function signIn(page, cred) {
  await page.goto(ORIGIN + '/login', { waitUntil: 'domcontentloaded' });
  const user = page.locator('#userName, input[formcontrolname="userName"]').first();
  const pass = page.locator('#password, input[formcontrolname="password"]').first();
  try {
    await user.waitFor({ state: 'visible', timeout: 20000 });
    await pass.waitFor({ state: 'visible', timeout: 20000 });
  } catch {
    throw authFail('the Optimo login form did not appear — cannot sign in automatically');
  }
  await user.fill(cred.user);
  await pass.fill(cred.pass);                    // value never reaches a log
  await page.locator('button[type="submit"]').first().click();

  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    const exp = await tokenExpiry(page);
    if (exp && exp > Date.now() + 60000 && !isLoginUrl(page.url())) {
      await page.waitForTimeout(2000);           // let Chromium flush the session
      return true;
    }
    await page.waitForTimeout(500);
  }
  throw authFail('signed in with the stored credential but Optimo did not accept it '
    + '(password changed, or the account needs attention). '
    + 'Re-store it with:  .\\scripts\\optimo_credential.ps1 -Set');
}

/* ----------------------------------------------------------------- export --*/

async function captureDiag(page, tag) {
  try {
    mkdirSync(DIAG, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const base = join(DIAG, `${stamp}_${tag}`);
    await page.screenshot({ path: base + '.png', fullPage: true }).catch(() => {});
    writeFileSync(base + '.html', await page.content().catch(() => ''), 'utf-8');
    log(`    diagnostics: logs/diag/${stamp}_${tag}.{png,html}`);
  } catch { /* diagnostics must never mask the real failure */ }
}

const lastGoodSizes = () => { try { return JSON.parse(readFileSync(SIZES, 'utf-8')); } catch { return {}; } };
function rememberSize(name, size) {
  const s = lastGoodSizes(); s[name] = size;
  try { writeFileSync(SIZES, JSON.stringify(s, null, 2), 'utf-8'); } catch { }
}

async function attemptExport(page, job) {
  await page.goto(ORIGIN + job.url, { waitUntil: 'domcontentloaded' });
  // A session that lapsed mid-run lands here, not on the report. Detect it now:
  // otherwise it surfaces 20s later as a bogus "export button not visible".
  await page.waitForTimeout(1200);
  if (isLoginUrl(page.url())) throw authFail('session expired part-way through the run');

  await page.waitForTimeout(job.stats ? 5300 : 3300);

  const btn = page.locator('button[class*="excel-export"], button[class*="export-b"]').first();
  try {
    await btn.waitFor({ state: 'visible', timeout: 25000 });
  } catch {
    if (isLoginUrl(page.url())) throw authFail('session expired part-way through the run');
    throw pageFail(`export button never appeared on ${job.label}`);
  }

  // Download to a .part sibling and only swap it in once it validates, so a
  // failed download can never destroy the last good copy of the report.
  const to = join(RAW, job.name);
  const part = to + '.part';
  const clickAndSave = async (clickFn) => {
    const dl = page.waitForEvent('download', { timeout: 90000 });
    await clickFn();
    const d = await dl;
    if (existsSync(part)) rmSync(part);
    // saveAs waits for the stream to finish on its own. Do NOT call failure()
    // first - it blocks until the download settles and reports the context as
    // closed, which breaks every export.
    await d.saveAs(part);
    return statSync(part).size;
  };

  let size;
  if (job.menu === 'products') {
    const box = await btn.boundingBox();
    if (!box) throw pageFail(`could not locate the export control on ${job.label}`);
    // click the caret half of the split button, then the "პროდუქტები" item
    await page.mouse.click(box.x + box.width - 12, box.y + box.height / 2);
    await page.waitForTimeout(900);
    // The menu entries are DIVs; a SPAN with the same text lives inside the
    // button itself (tooltip), so match the div or we click the trigger again.
    const item = page.locator('div:text-is("პროდუქტები")').last();
    try { await item.waitFor({ state: 'visible', timeout: 10000 }); }
    catch { throw pageFail(`the export menu did not open on ${job.label}`); }
    size = await clickAndSave(() => item.click());
  } else {
    size = await clickAndSave(() => btn.click());
  }

  // Two floors. The absolute one catches an empty file; the relative one catches
  // a plausible-looking partial export, which is the dangerous case - it loads
  // cleanly and quietly publishes a fraction of the real numbers.
  const prev = lastGoodSizes()[job.name];
  if (size < job.min) {
    rmSync(part, { force: true });
    throw pageFail(`${job.name} is ${size} bytes, under its ${job.min} floor — truncated export`);
  }
  if (prev && size < prev * 0.6) {
    rmSync(part, { force: true });
    throw pageFail(`${job.name} shrank from ${prev} to ${size} bytes (>40% drop) — refusing it. `
      + `If the drop is real, delete ${SIZES} and re-run.`);
  }

  renameSync(part, to);                          // atomic swap on the same volume
  rememberSize(job.name, size);
  log(`  ✓ ${job.label.padEnd(18)} ${(size / 1024).toFixed(0)} KB`);
}

/* One flaky job used to kill all six exports and the whole refresh. Retry each
   from a fresh navigation - but never retry an auth failure, which no amount of
   retrying fixes and which needs to surface immediately. */
async function runExport(page, job) {
  const backoff = [2000, 8000];
  for (let attempt = 0; ; attempt++) {
    try {
      return await attemptExport(page, job);
    } catch (e) {
      const retryable = e instanceof Fail ? e.retryable : true;
      if (!retryable || attempt >= backoff.length) {
        await captureDiag(page, job.name.replace(/\W+/g, '-'));
        throw e;
      }
      log(`  … ${job.label}: ${e.message} — retry ${attempt + 1}/${backoff.length}`);
      await page.waitForTimeout(backoff[attempt]);
    }
  }
}

/* --------------------------------------------------------------- publish ---*/

function publish() {
  const git = (...a) => {
    try { return { ok: true, out: execFileSync('git', a, { cwd: ROOT, encoding: 'utf-8' }) }; }
    catch (e) { return { ok: false, out: `${e.stdout || ''}${e.stderr || ''}`.trim(), status: e.status }; }
  };
  const rev = (r) => { const x = git('rev-parse', r); return x.ok ? x.out.trim() : null; };

  git('add', 'docs/index.html');
  if (git('diff', '--cached', '--name-only').out.trim()) {
    const c = git('commit', '-m', `Data refresh ${TODAY}`,
      '-m', 'Automated Optimo export.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>');
    if (!c.ok) die('git commit failed:\n' + c.out, EXIT.TRANSIENT);
  }

  // Refresh the remote-tracking ref first: if an earlier run committed but failed
  // to push, there is nothing staged now yet we are still behind, and the old
  // code reported "nothing to publish" while production silently went stale.
  git('fetch', 'origin', 'main');
  const head = rev('HEAD'), remote = rev('origin/main');
  if (head && remote && head === remote) { log('  · already published, nothing to push'); return; }

  const p = git('push', 'origin', 'main');
  if (!p.ok) die('git push failed — the site was NOT updated:\n' + p.out, EXIT.TRANSIENT);
  git('fetch', 'origin', 'main');
  if (rev('HEAD') !== rev('origin/main')) {
    die('git push reported success but origin/main does not match HEAD — site NOT updated', EXIT.TRANSIENT);
  }
  log('  ✓ pushed — live in ~1 min at https://reporting.quadrobuilder.ge');
}

/* ------------------------------------------------------------------ main ---*/

async function main() {
  mkdirSync(RAW, { recursive: true });
  mkdirSync(TMP, { recursive: true });

  const ctx = await chromium.launchPersistentContext(PROFILE, {
    headless: !LOGIN,
    // Deliberately NOT channel:'chrome'. Launching the installed Chrome while the
    // user already has Chrome open makes the new process hand off to the running
    // instance and exit, killing the context mid-download. The bundled Chromium is
    // fully isolated, so the job works whether or not Chrome is open.
    acceptDownloads: true,
    downloadsPath: TMP,
    viewport: { width: 1440, height: 900 },
  });
  const page = ctx.pages()[0] || await ctx.newPage();

  try {
    let state = await sessionState(page);

    if (LOGIN) {
      // --login is a one-shot: sign in, flush the session, and exit cleanly.
      // (Force-killing the process instead loses the cookie flush, which is what
      //  broke persistence the first time round.)
      if (state !== 'OK') {
        log('Log in to Optimo in the window that opened, then wait — I will detect it.');
        await page.waitForFunction(
          () => { try { return !!localStorage.getItem('accessToken') && !/\/login|\/auth/i.test(location.href); } catch { return false; } },
          { timeout: 300000 });
      }
      await page.waitForTimeout(2500);          // let Chromium write the session
      log('  ✓ logged in — session saved. Now run:  node scripts/auto_export.mjs');
      return;                                    // finally{} closes ctx cleanly
    }

    if (state === 'LOGGED_OUT') {
      const cred = storedCredential();
      if (!cred) {
        throw authFail('the Optimo session has expired.\n'
          + '    To let the refresh sign itself back in from now on:\n'
          + '      powershell -ExecutionPolicy Bypass -File scripts\\optimo_credential.ps1 -Set\n'
          + '    Or log in by hand this once:\n'
          + '      node scripts/auto_export.mjs --login');
      }
      log(`session expired — signing in as ${cred.user}`);
      await signIn(page, cred);
      log('  ✓ signed in');
      state = 'OK';
    }
    if (state === 'UNKNOWN') log('session state unclear — continuing, the first export will tell');
    else log('session ok — exporting');

    for (const job of JOBS) await runExport(page, job);
  } finally {
    await ctx.close();
    try { rmSync(TMP, { recursive: true, force: true }); } catch {}
  }

  log('building dashboard…');
  const py = (f) => execFileSync('python', [join('scripts', f)], { cwd: ROOT, stdio: 'inherit', env: { ...process.env, PYTHONIOENCODING: 'utf-8' } });
  py('build_warehouse.py');
  py('export_data.py');
  py('render.py');
  // node's own copy - no dependency on a POSIX cp being on PATH when the
  // scheduler starts us from the Startup folder rather than a Git Bash shell.
  copyFileSync(join(ROOT, 'dashboard.html'), join(ROOT, 'docs', 'index.html'));

  if (PUSH) { log('publishing…'); publish(); }
  log('done.');
}

main().catch((e) => die(e.message || String(e), e instanceof Fail ? e.code : EXIT.TRANSIENT));
