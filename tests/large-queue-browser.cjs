// Optional real Chromium heap/DOM probe. Requires Playwright and a local browser.
// CHROME_EXECUTABLE_PATH overrides the browser path; no compression or user files are changed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const baseline = Object.fromEntries(['app.js', 'style.css'].map(file =>
  [file, execFileSync('git', ['show', `HEAD:frontend/${file}`], { cwd: root, encoding: 'utf8', maxBuffer: 1024 * 1024 })]));
const server = http.createServer((req, res) => {
  const [version, file = 'index.html'] = new URL(req.url, 'http://localhost').pathname.slice(1).split('/');
  if (!['baseline', 'current'].includes(version) || file.includes('..')) { res.writeHead(404); res.end(); return; }
  const target = path.join(root, 'frontend', file);
  const content = version === 'baseline' && baseline[file] || (fs.existsSync(target) && fs.readFileSync(target));
  if (!content) { res.writeHead(404); res.end(); return; }
  res.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html');
  res.end(content);
});

async function main() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const executablePath = process.env.CHROME_EXECUTABLE_PATH || (fs.existsSync(chromium.executablePath())
    ? chromium.executablePath() : '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
  const browser = await chromium.launch({ executablePath, headless: true });
  const measurements = [];
  try {
    for (const [version, count] of [['baseline', 10_000], ['current', 10_000], ['current', 100_000]]) {
      const context = await browser.newContext({ viewport: { width: 920, height: 800 } });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.addInitScript(() => {
        window.confirm = () => true;
        window.__TAURI__ = {
          core: {
            convertFileSrc: value => value,
            invoke: async (command, args) => {
              if (command === 'expand_image_files') return args.filePaths;
              if (command === 'get_file_sizes') return args.filePaths.map(() => 2_000_000);
              if (command === 'get_app_settings') return { originalRetentionDays: 0 };
              if (command === 'get_cpu_info') return { logicalCpus: 8, availableParallelism: 8, effectiveLimit: 3 };
              if (command === 'get_app_version') return 'memory-probe';
              return null;
            },
          },
          event: { listen: async () => () => {}, emit: async () => {} },
        };
      });
      await page.goto(`http://127.0.0.1:${server.address().port}/${version}/index.html`);
      const cdp = await context.newCDPSession(page);
      async function measure(stage) {
        // Let DOM mutation observers deliver and release detached node records.
        await page.waitForTimeout(250);
        await cdp.send('HeapProfiler.collectGarbage');
        const heap = await cdp.send('Runtime.getHeapUsage');
        const dom = await cdp.send('Memory.getDOMCounters');
        const rows = await page.locator('.file-queue-item').count();
        measurements.push({ version, count, stage, rows, jsHeapMiB: +(heap.usedSize / 1048576).toFixed(2), nodes: dom.nodes });
      }
      await measure('empty');
      await page.evaluate(async count => {
        document.getElementById('autoCompress').checked = false;
        await handleFilePaths(Array.from({ length: count }, (_, i) => `/probe/photo-${i}.jpg`));
      }, count);
      await page.waitForFunction(count => queueItems.get(`/probe/photo-${count - 1}.jpg`).originalSize !== null, count);
      await measure('imported');
      if (version === 'current') {
        await page.evaluate(() => {
          const list = document.getElementById('fileQueueList');
          list.scrollTop = list.scrollHeight;
          renderQueueViewport();
        });
        assert.equal(await page.locator('.file-queue-item').last().getAttribute('data-file'), `/probe/photo-${count - 1}.jpg`);
        assert.ok(await page.locator('.file-queue-item').count() <= 23);
      }
      await page.evaluate(() => {
        files.forEach(file => {
          const item = queueItems.get(file);
          item.state = 'done';
          item.result = { file, success: true, originalSize: 2_000_000, compressedSize: 1_000_000,
            savings: 50, outputPath: file + '.out', outputMode: 'suffix', type: 'jpg', algorithm: 'probe' };
          paintQueueRow(file);
        });
        updateStats(); updateQueueSummary();
      });
      await measure('completed-metadata');
      await page.evaluate(() => clearAllFiles());
      await measure('cleared');
      assert.equal(await page.locator('.file-queue-item').count(), 0);
      if (version === 'current' && count === 100_000) {
        for (const round of [2, 3]) {
          await page.evaluate(async count => {
            await handleFilePaths(Array.from({ length: count }, (_, i) => `/probe/photo-${i}.jpg`));
          }, count);
          await page.waitForFunction(count => queueItems.get(`/probe/photo-${count - 1}.jpg`).originalSize !== null, count);
          await page.evaluate(() => {
            files.forEach(file => {
              const item = queueItems.get(file);
              item.state = 'done';
              item.result = { file, success: true, originalSize: 2_000_000, compressedSize: 1_000_000,
                savings: 50, outputPath: file + '.out', outputMode: 'suffix', type: 'jpg', algorithm: 'probe' };
            });
            updateStats(); updateQueueSummary(); clearAllFiles();
          });
          await measure(`cleared-round-${round}`);
        }
        const cleared = measurements.filter(value => value.version === version && value.count === count && value.stage.startsWith('cleared'));
        assert.ok(cleared.at(-1).jsHeapMiB <= cleared[0].jsHeapMiB + 1, 'three cleared batches have a stable JS heap');
      }
      assert.deepEqual(errors, [], `${version}: no browser JavaScript errors`);
      await context.close();
    }
    console.log(JSON.stringify({ kind: 'synthetic queue; no image encoding; JS heap after forced GC, not app RSS', measurements }, null, 2));
  } finally { await browser.close(); server.close(); }
}
main().catch(error => { server.close(); console.error(error); process.exitCode = 1; });
