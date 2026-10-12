const assert = require('node:assert/strict');
const vm = require('node:vm');
const { slice, installQueueRowPainter } = require('./app-slices.cjs');
const { queueDOM } = require('./queue-dom.cjs');

const { controls, document } = queueDOM();
const files = Array.from({ length: 100_000 }, (_, i) => `/photos/${i}.jpg`);
const queueItems = new Map(files.map(path => [path, { path, state: 'pending', result: null, originalSize: null }]));
const batches = [];
let metadataReply;
const context = vm.createContext({
  document, files, queueItems, fileRows: {}, queueSortDescending: false, queueRevision: 0,
  basename: path => path.split('/').pop(), localizeUiText: value => value,
  iconMarkup: name => name, formatBytes: String, waitingRowStatus: () => 'pending',
  renderTaskStatus: (row, status) => { row.status = status; },
  renderQueueResultActions: () => {}, renderRestoredActions: () => {},
  requestAnimationFrame: callback => { callback(); return 1; },
  invoke: async (_, args) => {
    batches.push(args.filePaths.length);
    if (metadataReply) return metadataReply();
    return args.filePaths.map(() => 1024);
  },
});
vm.runInContext(slice('function toggleQueueSortDirection(', '/// 把一个队列项此刻的状态'), context);
installQueueRowPainter(context);
vm.runInContext(slice('function createQueueRow(', '/// 把一个文件移出队列'), context);

async function main() {
  await context.renderFileQueue();
  const list = controls.fileQueueList;
  const rows = () => list.children.filter(row => row.dataset.file);
  assert.ok(rows().length <= 23, '100,000 items retain only viewport + overscan rows');
  assert.equal(Object.keys(context.fileRows).length, rows().length);
  assert.ok(batches.length > 1 && Math.max(...batches) <= 256, 'metadata IPC is chunked');
  assert.equal(queueItems.get(files.at(-1)).originalSize, 1024);
  const oldRow = context.fileRows[files[0]];

  // An offscreen update creates no DOM; scrolling paints from current state.
  queueItems.get(files[50_000]).state = 'failed';
  queueItems.get(files[50_000]).result = { file: files[50_000], success: false };
  context.paintQueueRow(files[50_000]);
  assert.equal(context.fileRows[files[50_000]], undefined);
  list.scrollTop = 50_000 * 42;
  context.renderQueueViewport();
  assert.equal(oldRow.parentNode, null, 'scrolled-away rows are detached and released');
  assert.ok(Object.keys(context.fileRows).length <= 23);
  assert.equal(context.fileRows[files[50_000]].querySelector('.queue-item-status').textContent, '失败');
  list.scrollTop = files.length * 42;
  context.renderQueueViewport();
  assert.ok(context.fileRows[files.at(-1)], 'last item remains reachable');

  controls.queueFailedOnly.checked = true;
  context.applyQueueView();
  assert.deepEqual(rows().map(row => row.dataset.file), [files[50_000]]);
  assert.equal(list.scrollTop, 0, 'filter change returns to reachable first row');
  controls.queueFailedOnly.checked = false;
  context.queueSortDescending = true;
  context.applyQueueView();
  assert.equal(rows()[0].dataset.file, files.at(-1));
  assert.equal(files[0], '/photos/0.jpg', 'display sort never changes execution order');

  // A delayed metadata response must not write into a same-path reimport.
  context.files = ['/photos/reimport.jpg'];
  const original = { state: 'pending', result: null, originalSize: null };
  context.queueItems = new Map([[context.files[0], original]]);
  let resolveMetadata;
  metadataReply = () => new Promise(resolve => { resolveMetadata = resolve; });
  const read = context.renderFileQueue();
  const replacement = { state: 'pending', result: null, originalSize: null };
  context.queueItems.set(context.files[0], replacement);
  resolveMetadata([8192]);
  await read;
  assert.equal(replacement.originalSize, null);

  context.queueRevision++;
  context.files = [];
  context.queueItems = new Map();
  context.applyQueueView();
  assert.equal(Object.keys(context.fileRows).length, 0);
  assert.equal(context.queueViewport.paths.length, 0, 'clear releases the view snapshot');

  let refreshes = 0;
  const callbacks = new Map();
  let timerID = 0;
  context.setTimeout = callback => { const id = ++timerID; callbacks.set(id, callback); return id; };
  context.clearTimeout = id => callbacks.delete(id);
  context.updateStats = () => refreshes++;
  context.updateQueueSummary = () => {};
  context.emitCompareResultsChanged = () => {};
  vm.runInContext(slice('var queueUpdatesTimer = null;', 'function updateStats('), context);
  for (let i = 0; i < 100_000; i++) context.scheduleQueueUpdates();
  assert.equal(callbacks.size, 1, 'a progress burst schedules one queue refresh');
  context.flushQueueUpdates();
  assert.equal(refreshes, 1);
  assert.equal(callbacks.size, 0, 'batch completion flushes and cancels the pending timer');

  const listeners = {};
  let snapshots = 0;
  context.listen = (name, callback) => { listeners[name] = callback; };
  context.window = { __TAURI__: { event: { emit() {} } } };
  context.comparableResults = () => { snapshots++; return []; };
  vm.runInContext(slice('var compareWindowOpen = false;', "listen('compare-recompressed'"), context);
  context.emitCompareResultsChanged();
  assert.equal(callbacks.size, 0, 'closed comparison does not build a queue snapshot');
  listeners['compare-ready']();
  for (let i = 0; i < 100_000; i++) context.emitCompareResultsChanged();
  assert.equal(callbacks.size, 1);
  const [id, callback] = callbacks.entries().next().value;
  callbacks.delete(id); callback();
  assert.equal(snapshots, 1, 'an open comparison coalesces snapshot serialization');
  listeners['compare-closed']();
  context.emitCompareResultsChanged();
  assert.equal(callbacks.size, 0);

  context.pendingImports = Promise.resolve();
  context.settingsPanel = { style: {} };
  context.resultsPanel = { style: {} };
  context.inputPaths = [];
  context.isCompressing = false;
  context.showToast = () => {};
  vm.runInContext(slice('function uniqueFilePaths(', '// Global state for compression'), context);
  let resolveImport;
  context.invoke = () => new Promise(resolve => { resolveImport = resolve; });
  const importing = context.handleFilePaths(['/photos/old-folder']);
  await Promise.resolve();
  context.queueRevision++;
  resolveImport(['/photos/late.jpg']);
  assert.equal((await importing).length, 0, 'clear invalidates an in-flight directory scan');
  assert.equal(await context.pendingImports, undefined, 'the sequencing promise retains no path array');
  assert.equal(context.queueItems.size, 0);
  console.log('PASS: 100,000-item bounded DOM, scrolling, live state/filter/sort, 256-path IPC, stale reimport, clear, coalesced refresh');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
