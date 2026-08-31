/* QuadroBuilder — automatic Optimo export.
 *
 * Drives the real Optimo UI in a persistent Chromium profile: you log in once,
 * every run after reuses the session. No password is ever stored by this script.
 * It downloads the six reports, files them into data/raw/, then runs the Python
 * pipeline and pushes docs/index.html.
 *
 *   node scripts/auto_export.mjs            # normal daily run (headless once logged in)
 *   node scripts/auto_export.mjs --login    # visible window to log in / re-auth
 *   node scripts/auto_export.mjs --no-push  # build locally, skip git push
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, renameSync, rmSync, readdirSync, statSync, copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const RAW = join(ROOT, 'data', 'raw');
const PROFILE = join(ROOT, '.optimo-profile');           // gitignored session store
const TMP = join(ROOT, '.dl');                            // scratch download dir
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

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const die = (m) => { console.error('\n  ✗ ' + m + '\n'); process.exit(1); };

// as-of = today; the whole trading history since a fixed floor
const TODAY = new Date().toISOString().slice(0, 10);
const FROM = '2024-01-01';
const range = (path) => `${path}${path.includes('?') ? '&' : '?'}dateFrom=${FROM}&dateTo=${TODAY}`;

/* the six exports, in order. `menu` picks the line-item option from the caret
   dropdown; a plain green button otherwise. */
const JOBS = [
  { name: 'sales_lines_retail.xlsx', label: 'retail line items',
    url: range('/reports/sale-orders/retail?pageIndex=1&sortField=orderDate&sortOrder=DESC&pageSize=20'), menu: 'products' },
  { name: 'sales_lines_entity.xlsx', label: 'B2B line items',
    url: range('/reports/sale-orders/entity?pageIndex=1&sortField=orderDate&sortOrder=DESC&pageSize=20'), menu: 'products' },
  { name: 'stock_on_hand.xlsx', label: 'stock on hand',
    url: '/stockholdings?pageIndex=1&sortField=stockItemName&sortOrder=DESC&pageSize=20' },
  { name: 'stock_movement.xlsx', label: 'stock movement',
    url: range('/reports/stock-movement?pageIndex=1&pageSize=20'), menu: null },
  { name: 'supplies_ledger.xlsx', label: 'supplies ledger',
    url: range('/reports/supplies?pageIndex=1&pageSize=20'), menu: null },
  { name: 'daily_statistics.xlsx', label: 'daily statistics',
    url: '/statistics/general', menu: null, stats: true },
];

async function ensureLoggedIn(page) {
  await page.goto('https://dashboard.optimo.ge/dashboard', { waitUntil: 'domcontentloaded' });
  // the app stores a JWT here once authenticated
  for (let i = 0; i < 40; i++) {
    const tok = await page.evaluate(() => { try { return localStorage.getItem('accessToken'); } catch { return null; } });
    const url = page.url();
    if (tok && url.includes('/dashboard')) return true;
    if (/login|auth|identity/i.test(url)) return false;
    await page.waitForTimeout(500);
  }
  return false;
}

async function runExport(page, job) {
  await page.goto('https://dashboard.optimo.ge' + job.url, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(job.stats ? 6500 : 4500);

  // the export control carries an "excel-export" class; the stats page uses a
  // different one. Find it by class fragment.
  const btn = page.locator('button[class*="excel-export"], button[class*="export-b"]').first();
  await btn.waitFor({ state: 'visible', timeout: 20000 });

  const clickAndSave = async (clickFn) => {
    const dl = page.waitForEvent('download', { timeout: 60000 });
    await clickFn();
    const d = await dl;
    const to = join(RAW, job.name);
    if (existsSync(to)) rmSync(to);
    // saveAs waits for the stream to finish on its own. Do NOT call failure()
    // first - it blocks until the download settles and reports the context as
    // closed, which breaks every export.
    await d.saveAs(to);
    return statSync(to).size;
  };

  let size;
  if (job.menu === 'products') {
    // click the caret half of the split button, then the "პროდუქტები" item
    const box = await btn.boundingBox();
    await page.mouse.click(box.x + box.width - 12, box.y + box.height / 2);
    await page.waitForTimeout(900);
    // The menu entries are DIVs; a SPAN with the same text lives inside the
    // button itself (tooltip), so match the div or we click the trigger again.
    const item = page.locator('div:text-is("პროდუქტები")').last();
    await item.waitFor({ state: 'visible', timeout: 10000 });
    size = await clickAndSave(() => item.click());
  } else {
    size = await clickAndSave(() => btn.click());
  }
  if (size < 4000) throw new Error(`${job.name} is only ${size} bytes — likely an empty/partial export`);
  log(`  ✓ ${job.label.padEnd(18)} ${(size / 1024).toFixed(0)} KB`);
}

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
    const ok = await ensureLoggedIn(page);
    if (LOGIN) {
      // --login is a one-shot: sign in, flush the session, and exit cleanly.
      // (Force-killing the process instead loses the cookie flush, which is what
      //  broke persistence the first time round.)
      if (!ok) {
        log('Log in to Optimo in the window that opened, then wait — I will detect it.');
        await page.waitForFunction(
          () => { try { return !!localStorage.getItem('accessToken') && location.href.includes('/dashboard'); } catch { return false; } },
          { timeout: 300000 });
      }
      await page.waitForTimeout(2500);          // let Chromium write the session
      log('  ✓ logged in — session saved. Now run:  node scripts/auto_export.mjs');
      return;                                    // finally{} closes ctx cleanly
    }
    if (!ok) die('Not logged in. Run once with:  node scripts/auto_export.mjs --login');
    log('session ok — exporting');
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

  if (PUSH) {
    log('publishing…');
    const git = (...a) => { try { return execFileSync('git', a, { cwd: ROOT, encoding: 'utf-8' }); } catch (e) { return e.stdout || ''; } };
    git('add', 'docs/index.html');
    const staged = git('diff', '--cached', '--name-only').trim();
    if (staged) {
      git('commit', '-m', `Data refresh ${TODAY}`, '-m', 'Automated Optimo export.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>');
      git('push', 'origin', 'main');
      log('  ✓ pushed — live in ~1 min at https://reporting.quadrobuilder.ge');
    } else {
      log('  · no change since last run, nothing to publish');
    }
  }
  log('done.');
}

main().catch((e) => die(e.message || String(e)));
