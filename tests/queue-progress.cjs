// 队列生命周期：导入 → 一轮执行 → 停止 → 继续。
//
// 这一组盯的是"队列（长期存在）"与"执行会话（一轮）"的分家：
//   1. 追加导入不打断正在跑的那一轮（那一轮的目标是快照，不会中途变大）；
//   2. 进度属于队列：停止后继续，是从 40/100 接着长，不是 0/60 重来；
//   3. 停止之后不许自动续跑下一轮。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const {
  slice, installStateMachine, installQueueCore, installSessionModel, installQueueRowPainter,
} = require('./app-slices.cjs');
const summary = { textContent: '' };
const context_compressBtnText = { innerHTML: '' };
const context_startBtn = { disabled: false, classList: { toggle() {}, add() {}, remove() {} } };
const context_fill = { style: {} };
const runs = [];
let progress;
let sessionSeq = 0;
const context = vm.createContext({
  console, Set, Map, Promise,
  files: [], inputPaths: [], pendingAutoCompress: false, processingMode: 'advanced',
  queueItems: new Map(),
  fileRows: {},
  queueRevision: 0,
  executionSession: null,
  sessionSeq: 0,
  currentView: 'main',
  document: {
    getElementById: id => ({
      queueSummary: summary,
      compressBtnText: context_compressBtnText,
      startCompressBtn: context_startBtn,
      compressBtnFill: context_fill,
    }[id] || null),
    querySelector: () => null,
  },
  settingsPanel: {style:{}}, resultsPanel: {style:{}},
  statOriginal: {}, statCompressed: {}, totalSavings: {}, totalRate: {},
  ensureSystemOutputAccess: async () => true,
  getCurrentCompressionConfig: () => ({ options: {} }),
  listen: async (_, handler) => { progress = payload => handler({payload}); return () => {}; },
  invoke: async (command, args) => {
    if (command === 'expand_image_files') return args.filePaths;
    if (command === 'get_file_sizes') return args.filePaths.map(() => 1024);
    return new Promise(resolve => runs.push({ command, paths: args.filePaths, sessionId: args.sessionId, resolve }));
  },
  formatBytes: String, showToast(message) { context._toasts.push(message); }, iconMarkup() {},
  _toasts: [],
  renderQueueResultActions() {}, renderRestoredActions() {},
  updateStats() {}, showResults() {}, applyQueueView() {},
  refreshHistoryIfOpen() {}, emitCompareResultsChanged() {}, showErrorDetail() {},
});
vm.runInContext(slice('function uniqueFilePaths(', 'async function renderFileQueue('), context);
vm.runInContext(slice('function processingActionText(', 'function setProcessingMode('), context);
// 状态机与队列状态都是真实实现：批次起止要经过它们。
installQueueCore(context);
installStateMachine(context);
installQueueRowPainter(context);
installSessionModel(context);
context.setCompressionState('idle', true);
vm.runInContext(slice('async function startCompression(', 'function updateStats('), context);

// 每一行给个够用的假 DOM：真实 paintQueueRow 会往上写图标 / 文案 / 按钮。
let rowSeq = 0;
context.renderFileQueue = () => context.files.forEach(file => {
  if (context.fileRows[file]) return;
  const parts = {
    '.queue-item-icon': { innerHTML: '' },
    '.queue-item-status': { textContent: '' },
    '.queue-item-size': { textContent: '' },
    '.queue-item-actions': { innerHTML: '', querySelector: () => null },
    '.queue-item-remove': { style: {}, addEventListener() {} },
  };
  context.fileRows[file] = {
    _id: ++rowSeq,
    classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
    querySelector: selector => parts[selector] || null,
  };
});

const flush = async () => { for (let i=0;i<16;i++) await Promise.resolve(); };
const run = () => runs[runs.length - 1];
// 后端事件：payload 一定带着当前这一轮的 sessionId。
const emit = payload => progress(Object.assign({ sessionId: run().sessionId }, payload));
const settle = file => emit({ file, status: 'completed', result: {file, success:true, savings:10, originalSize: 100, compressedSize: 90} });
const startSession = file => emit({ file, status: 'starting' });
const defer = file => emit({ file, status: 'deferred' });

(async () => {
  const first = Array.from({length:10}, (_,i) => `/first-${i}.png`);
  const next = Array.from({length:10}, (_,i) => `/next-${i}.png`);
  await context.handleFilePaths(first);
  const firstRun = context.startCompression(false);
  await flush();
  first.slice(0,3).forEach(file => { startSession(file); settle(file); });
  assert.equal(summary.textContent, '3 / 10 已处理');

  await context.handleFilePaths(next);
  assert.equal(summary.textContent, '3 / 20 已处理', '导入要立刻把总数算进摘要');
  await context.handleFilePaths(next);
  assert.equal(summary.textContent, '3 / 20 已处理', '重复导入不许把总数撑大');
  assert.deepEqual(Array.from(run().paths), first, '这一轮的目标是快照，中途导入不改变它');
  assert.equal(context.getQueueProgress().pending, 17, '新导入的 10 张仍是 pending');

  first.slice(3).forEach(file => { startSession(file); settle(file); });
  run().resolve({ sessionId: run().sessionId, results: [] });
  await firstRun;
  assert.equal(summary.textContent, '10 / 20 已处理', '一轮结束后已处理的数不能丢');
  assert.equal(context.compressionState, 'idle');

  // ── 「继续压缩」只提交 pending ──────────────────────────────
  const second = context.startCompression(true);
  await flush();
  assert.deepEqual(Array.from(run().paths), next, '第二轮只带还没处理的那些');
  assert.equal(summary.textContent, '10 / 20 已处理', '新一轮不重置进度');
  next.forEach(file => { startSession(file); settle(file); });
  settle(next[0]);   // 重复事件不许算两次
  run().resolve({ sessionId: run().sessionId, results: [] });
  await second;
  assert.equal(summary.textContent, '20 / 20 已处理');
  assert.equal(context.getQueueProgress().pending, 0);

  // ── 自动续跑：正常结束后，新导入的 pending 会被自动拉起来 ──
  const extra = ['/extra.png'];
  await context.handleFilePaths(extra);
  const third = context.startCompression(false);
  await flush();
  await context.handleFilePaths(['/auto.png']);
  context.pendingAutoCompress = true;
  startSession(extra[0]); settle(extra[0]);
  run().resolve({ sessionId: run().sessionId, results: [] });
  await third;
  await flush();
  assert.equal(summary.textContent, '21 / 22 已处理', '自动续跑接着原来的进度');
  startSession('/auto.png'); settle('/auto.png');
  run().resolve({ sessionId: run().sessionId, results: [] });
  await flush();
  assert.equal(summary.textContent, '22 / 22 已处理');

  // ── 停止：这一轮就地结束，剩下的仍然是 pending，绝不自动续跑 ──
  const stopPaths = Array.from({length:6}, (_,i) => `/stop-${i}.png`);
  await context.handleFilePaths(stopPaths);
  const stopped = context.startCompression(false);
  await flush();
  context.pendingAutoCompress = true;
  startSession(stopPaths[0]); settle(stopPaths[0]);
  startSession(stopPaths[1]);
  context.setCompressionState('stopping', true);
  // 后端把后面的文件逐个报成 deferred（停止不是取消）。
  stopPaths.slice(2).forEach(defer);
  settle(stopPaths[1]);                       // 已经在跑的那个收尾
  run().resolve({ sessionId: run().sessionId, results: [] });
  await stopped;
  await flush();
  const stopRuns = runs.filter(r => r.paths.join('|') === stopPaths.join('|'));
  assert.equal(stopRuns.length, 1, '停止之后不许自动续跑下一轮');
  assert.equal(context.pendingAutoCompress, false, '停止之后自动压缩必须被清掉');
  assert.equal(context.compressionState, 'idle', '一轮收尾后回到空闲');
  assert.equal(summary.textContent, '24 / 28 已处理',
    '被停止延后的 4 张既不算处理过、也不能从总数里消失');
  assert.equal(context.getQueueProgress().pending, 4, '被延后的文件仍然是 pending');
  assert.match(context_compressBtnText.innerHTML, /继续压缩/,
    '队列还没干完，主按钮必须是「继续压缩」而不是「压缩完成」');

  // ── 继续：新的一轮只带那 4 张，进度接着长 ──────────────────
  const resumed = context.startCompression(true);
  await flush();
  assert.deepEqual(Array.from(run().paths), stopPaths.slice(2),
    '「继续压缩」只处理上一轮没轮到的');
  assert.equal(summary.textContent, '24 / 28 已处理', '继续之后进度绝不清零');
  run().paths.forEach(file => { startSession(file); settle(file); });
  run().resolve({ sessionId: run().sessionId, results: [] });
  await resumed;
  assert.equal(summary.textContent, '28 / 28 已处理');
  assert.equal(context.getQueueProgress().total, 28, '分母始终是整个队列');

  context.files = [];
  context.queueItems = new Map();
  context.updateQueueSummary();
  assert.equal(summary.textContent, '0 个文件');
  console.log('PASS: 队列与会话分家、导入不打断、停止保留 pending、继续从原进度接着长');
})().catch(error => { console.error(error); process.exitCode = 1; });
