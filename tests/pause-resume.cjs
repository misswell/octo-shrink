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
  console.log('PASS: pause/resume signals, 暂停中… title, 已暂停 summary, rollback on failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
