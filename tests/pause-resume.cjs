// 暂停/继续：前端只发信号，不 kill 子进程；文案、按钮和失败回滚都要对上方案。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('frontend/app.js', 'utf8');

const el = () => ({
  style: {}, title: '', innerHTML: '', textContent: '',
  classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
  setAttribute() {},
});
const elements = {
  queueSummary: el(), compressBtnText: el(),
  pauseCompressBtn: el(), pauseBtnText: el(), restoreAllBtn: el(),
};
const calls = [];
let failNext = false;
const context = vm.createContext({
  console: { log: console.log, warn: console.warn, error: message => calls.push(['error', message]) },
  Set, Map, Promise, JSON,
  files: Array.from({ length: 20 }, (_, i) => `/img-${i}.png`),
  results: [], isCompressing: true, processingMode: 'advanced',
  document: { getElementById: id => elements[id] || null },
  applyQueueView() {}, showToast(message) { calls.push(['toast', message]); },
  invoke: async (command, args) => {
    calls.push([command, args]);
    if (failNext) throw new Error('ipc down');
    return null;
  },
});
const slice = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));
vm.runInContext(slice('function updateQueueSummary(', 'function toggleQueueSortDirection('), context);
vm.runInContext(slice('function processingActionText(', 'function setProcessingMode('), context);
vm.runInContext(slice('var compressionPaused = false;', '// ─── 历史记录页'), context);

const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
const last = name => [...calls].reverse().find(call => call[0] === name);

(async () => {
  assert.match(context.pauseButtonText(false), /暂停/);
  assert.match(context.pauseButtonText(true), /继续/);

  await context.toggleCompressionPause();
  assert.ok(last('pause_compression'), 'first click must ask the backend to pause');
  assert.equal(context.compressionPaused, true);
  assert.match(elements.pauseBtnText.innerHTML, /继续/, 'button must offer resume');
  assert.match(elements.compressBtnText.innerHTML, /暂停中…/, 'progress button must read 暂停中…');
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成 · 已暂停');

  await context.toggleCompressionPause();
  assert.ok(last('resume_compression'), 'second click must ask the backend to resume');
  assert.equal(context.compressionPaused, false);
  assert.match(elements.compressBtnText.innerHTML, /压缩中…/);
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成', '已暂停 must disappear once resumed');

  // 后端拒绝时不能把 UI 停在错误状态。
  failNext = true;
  await context.toggleCompressionPause();
  assert.equal(context.compressionPaused, false, 'failed pause must roll back');
  assert.ok(last('error'), 'failure must be logged');
  assert.deepEqual(last('toast'), ['toast', '暂停失败，请重试']);

  context.isCompressing = false;
  context.renderPauseControls();
  assert.equal(elements.queueSummary.textContent, '20 个文件', 'idle summary keeps its own copy');
  assert.doesNotMatch(elements.compressBtnText.innerHTML, /暂停中/, 'idle must not rewrite the button');

  context.setPauseButtonVisible(false);
  assert.equal(elements.pauseCompressBtn.style.display, 'none');

  // 取消整批 = 一次 cancel_batch，并且绝不因此解除暂停。
  const countOf = needle => source.split(needle).length - 1;
  assert.equal(countOf("invoke('cancel_file'"), 1, '只有队列里单个文件才逐个取消');
  assert.equal(countOf("invoke('cancel_batch'"), 2, '清空全部与清除结果各发一次批量取消');

  const batchCalls = [];
  const paths = ['/a.png', '/b.png', '/c.png'];
  const batch = vm.createContext({
    console, Set, Map, Promise, JSON,
    files: paths.slice(), results: [], inputPaths: [], fileRows: {},
    isCompressing: true, queueRevision: 0, pendingAutoCompress: true,
    activeBatchPaths: paths.slice(), activeBatchSet: new Set(paths),
    activeBatchRows: new Map(), activeBatchRevision: 7,
    cancelledFiles: new Set(), compressionPaused: true,
    confirm: () => true,
    document: { getElementById: () => null },
    settingsPanel: { style: {} }, resultsPanel: { style: {} },
    updateQueueSummary() {}, emitCompareResultsChanged() {},
    invoke: async (command, args) => { batchCalls.push([command, args]); return null; },
  });
  vm.runInContext(slice('function clearAllFiles(', '// ─── Compression'), batch);
  batch.clearAllFiles();
  await flush();
  assert.equal(batchCalls.length, 1, `清空全部只许发一次取消请求：${JSON.stringify(batchCalls)}`);
  assert.equal(batchCalls[0][0], 'cancel_batch');
  assert.deepEqual(batchCalls[0][1].filePaths, paths);
  assert.deepEqual([...batch.cancelledFiles], paths, '这批路径必须全部标记为已取消');
  assert.equal(batch.pendingAutoCompress, false);
  assert.equal(batch.compressionPaused, true, '取消不能把暂停闸门打开');
  assert.ok(!batchCalls.some(call => call[0] === 'resume_compression'),
    '取消路径里绝不许出现 resume_compression');
  console.log('PASS: pause/resume signals, 暂停中… title, 已暂停 summary, rollback on failure, 一次批量取消不动暂停');
})().catch(error => { console.error(error); process.exitCode = 1; });
