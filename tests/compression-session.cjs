// 执行会话：Start → Pause → Resume、Start → Stop → Continue、Pause → Stop → Continue。
//
// 这一组是这次重构的正面清单（方案 §69 / §72），每条都对应一个真实踩过的错：
//   · 停止产生的 pending 绝不能变成 cancelled（那是"再也压不动"的根源）；
//   · 上一轮的迟到事件不许污染下一轮（会话号必须拦住它）；
//   · 「继续压缩」不许重压已经 done 的文件；
//   · failed 不许被普通「继续压缩」自动重试，但要能显式「重试」；
//   · Pause→Resume 不新开一轮，Stop→Continue 必须新开一轮；
//   · 进度绝不倒退回 0/N，processed 只增不减。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const {
  source, slice, installStateMachine, installQueueCore, installSessionModel, installQueueRowPainter,
} = require('./app-slices.cjs');

const summary = { textContent: '' };
const btnText = { innerHTML: '' };
const startBtn = { disabled: false, classList: { toggle() {}, add() {}, remove() {} } };
const fill = { style: {} };
const runs = [];
const toasts = [];
let progress = null;

const context = vm.createContext({
  console, Set, Map, Promise, Date,
  files: [], inputPaths: [], pendingAutoCompress: false, processingMode: 'advanced',
  queueItems: new Map(), fileRows: {}, queueRevision: 0,
  executionSession: null, sessionSeq: 0,
  document: {
    getElementById: id => ({
      queueSummary: summary, compressBtnText: btnText,
      startCompressBtn: startBtn, compressBtnFill: fill,
    }[id] || null),
    querySelector: () => null,
  },
  settingsPanel: { style: {} }, resultsPanel: { style: {} },
  statOriginal: {}, statCompressed: {}, totalSavings: {}, totalRate: {},
  ensureSystemOutputAccess: async () => true,
  getCurrentCompressionConfig: () => ({ options: {} }),
  // app.js 那边监听的是事件对象，事件载荷在 event.payload 里。
  listen: async (_, handler) => { progress = payload => handler({ payload }); return () => {}; },
  invoke: async (command, args) => {
    if (command === 'expand_image_files') return args.filePaths;
    if (command === 'get_file_sizes') return args.filePaths.map(() => 2048);
    return new Promise(resolve => runs.push({
      command, paths: args.filePaths, sessionId: args.sessionId, queueRevision: args.queueRevision, resolve,
    }));
  },
  formatBytes: String, iconMarkup: () => '<svg></svg>',
  basename: file => file.split('/').pop(),
  showToast: message => toasts.push(message),
  updateStats() {}, showResults() {}, applyQueueView() {},
  refreshHistoryIfOpen() {}, emitCompareResultsChanged() {}, showErrorDetail() {},
  renderQueueResultActions() {}, renderRestoredActions() {},
});

vm.runInContext(slice('function uniqueFilePaths(', 'async function renderFileQueue('), context);
vm.runInContext(slice('function processingActionText(', 'function setProcessingMode('), context);
installQueueCore(context);
installStateMachine(context);
installQueueRowPainter(context);
installSessionModel(context);
context.setCompressionState('idle', true);
vm.runInContext(slice('async function startCompression(', 'function updateStats('), context);
// 单文件重试：把那一行放回 pending 再开一轮只含它。
vm.runInContext(slice('async function compressOneFile(', 'async function saveResult('), context);

// 最小可用的假行 DOM（paintQueueRow 会往上写）。
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
    classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
    querySelector: selector => parts[selector] || null,
  };
});

const flush = async () => { for (let i = 0; i < 16; i++) await Promise.resolve(); };
const currentRun = () => runs[runs.length - 1];
const emit = payload => progress(Object.assign({ sessionId: currentRun().sessionId, queueRevision: currentRun().queueRevision }, payload));
const start = file => emit({ file, status: 'starting' });
const done = (file, ok = true) => emit({
  file, status: ok ? 'completed' : 'failed',
  result: { file, success: ok, savings: ok ? 12 : 0, originalSize: 2048, compressedSize: 1800 },
});
const deferred = file => emit({ file, status: 'deferred' });
const cancelAck = file => emit({ file, status: 'cancelled' });
const settleRun = () => currentRun().resolve({ sessionId: currentRun().sessionId, results: [] });

const stateOf = file => context.queueItems.get(file).state;
const progressOf = () => context.getQueueProgress();
const pendingPaths = () => context.getPendingQueuePaths();

(async () => {
  const paths = Array.from({ length: 10 }, (_, i) => `/shot-${i}.png`);
  await context.handleFilePaths(paths);
  assert.deepEqual(paths.map(stateOf), paths.map(() => 'pending'), '导入即 pending');

  // ── 场景 1：Start → Pause → Resume（同一个会话）─────────────────
  const firstRun = context.startCompression(false);
  await flush();
  paths.slice(0, 3).forEach(file => { start(file); done(file); });
  assert.equal(summary.textContent, '3 / 10 已处理');
  assert.equal(fill.style.width, '30%', '进度条必须是真实比例，不是 CSS 脉冲');

  context.setCompressionState('paused');
  const runIdBeforePause = currentRun().sessionId;
  paths.slice(3, 5).forEach(start);          // 暂停时还有两个在收尾
  paths.slice(3, 5).forEach(file => done(file));
  assert.equal(summary.textContent, '5 / 10 已处理 · 已暂停');
  assert.equal(context.taskStatusMarkup('running').text, '收尾中…',
    '暂停之后仍在跑的行要照实写「收尾中…」，不能假装停下来');

  context.setCompressionState('running');    // 点「继续」= resume_compression，不新开一轮
  assert.equal(currentRun().sessionId, runIdBeforePause, 'Pause→Resume 不新开会话');
  assert.equal(runs.length, 1, 'Pause→Resume 绝不能发起第二次后端调用');
  paths.slice(5).forEach(file => { start(file); done(file); });
  settleRun();
  await firstRun;
  assert.equal(summary.textContent, '10 / 10 已处理');
  assert.equal(fill.style.width, '100%');
  assert.match(btnText.innerHTML, /压缩完成/);

  // ── 场景 2：Start → Stop → Continue ────────────────────────────
  const more = Array.from({ length: 6 }, (_, i) => `/more-${i}.png`);
  await context.handleFilePaths(more);
  assert.equal(summary.textContent, '10 / 16 已处理', '新导入的立刻进总数');

  const secondRun = context.startCompression(false);
  await flush();
  assert.deepEqual(Array.from(currentRun().paths), more, '只提交 pending');
  start(more[0]); done(more[0]);
  start(more[1]);
  context.setCompressionState('stopping');
  more.slice(2).forEach(deferred);
  done(more[1]);
  settleRun();
  await secondRun;
  await flush();

  assert.equal(context.compressionState, 'idle', '一轮收尾后回到 idle');
  assert.equal(summary.textContent, '12 / 16 已处理', '被停止延后的不算处理过');
  assert.deepEqual(more.slice(2).map(stateOf), ['pending', 'pending', 'pending', 'pending'],
    '停止产生的项必须仍然是 pending —— 绝不能变成"取消/跳过"');
  assert.match(btnText.innerHTML, /继续压缩/,
    '队列还剩东西时主按钮是「继续压缩」，绝不能显示「压缩完成」');
  assert.equal(fill.style.width, '75%', '停止后进度停在真实比例上');

  // 继续：新一轮只带那 4 张，进度从 12 接着长，绝不回到 0/4。
  const thirdRun = context.startCompression(true);
  await flush();
  assert.deepEqual(Array.from(currentRun().paths), more.slice(2),
    '「继续压缩」只处理上一轮没轮到的，不重压已完成的');
  assert.equal(summary.textContent, '12 / 16 已处理', '继续之后进度不清零');
  assert.equal(progressOf().total, 16, '分母始终是整个队列，不是这一轮的目标');
  currentRun().paths.forEach(file => { start(file); done(file); });
  settleRun();
  await thirdRun;
  assert.equal(summary.textContent, '16 / 16 已处理');
  assert.equal(progressOf().processed, 16);

  // ── 上一轮的迟到事件不许污染这一轮 ───────────────────────────────
  const stale = Array.from({ length: 4 }, (_, i) => `/stale-${i}.png`);
  await context.handleFilePaths(stale);
  const fourthRun = context.startCompression(false);
  await flush();
  const liveSession = currentRun().sessionId;
  // 冒充"上一轮"发一条 deferred 和一条 cancelled：都不许碰这一轮。
  progress({ sessionId: 'session-old', file: stale[0], status: 'deferred' });
  progress({ sessionId: 'session-old', file: stale[1], status: 'cancelled' });
  progress({ sessionId: liveSession, queueRevision: currentRun().queueRevision - 1,
    file: stale[2], status: 'cancelled' });
  emit({ file: '/outside-snapshot.png', status: 'starting' });
  assert.deepEqual(stale.map(stateOf), ['pending', 'pending', 'pending', 'pending'],
    '旧会话、旧队列版本和快照外事件都不能改当前队列');
  stale.forEach(file => { start(file); done(file); });
  settleRun();
  await fourthRun;
  assert.equal(summary.textContent, '20 / 20 已处理');
  assert.equal(liveSession, runs[runs.length - 1].sessionId);

  // ── 失败是终态：普通「继续压缩」不重试，显式「重试」才行 ─────────
  const bad = '/broken.png';
  await context.handleFilePaths([bad]);
  const fifthRun = context.startCompression(false);
  await flush();
  start(bad); done(bad, false);
  settleRun();
  await fifthRun;
  assert.equal(stateOf(bad), 'failed');
  assert.equal(summary.textContent, '21 / 21 已处理 · 失败 1');
  assert.match(btnText.innerHTML, /1 个失败/, '有失败的要说出来，不能装作全成了');

  const runsBefore = runs.length;
  await context.startCompression(true);
  await flush();
  assert.equal(runs.length, runsBefore, '没有 pending 时「继续压缩」什么都不做');
  assert.equal(stateOf(bad), 'failed', '失败的文件不会被普通「继续压缩」自动重试');

  // 显式重试：失败 → pending → 再压一次，总体已处理数不倒退。
  const beforeRetry = progressOf().processed;
  const retry = context.compressOneFile(bad);
  await flush();
  assert.equal(stateOf(bad), 'pending', '重试先把它放回 pending');
  assert.deepEqual(Array.from(currentRun().paths), [bad], '重试只开一轮含这个文件的会话');
  start(bad);
  assert.equal(stateOf(bad), 'running', '开工事件到达后才写 running');
  done(bad);
  settleRun();
  await retry;
  assert.equal(progressOf().processed, beforeRetry, '重试成功后已处理数不变（失败换成成功）');
  assert.equal(summary.textContent, '21 / 21 已处理', '失败清零后摘要不再写"失败 1"');
  assert.equal(progressOf().failed, 0);

  // ── 用户把某个等待中的文件移出队列：那条 cancelled 才真的出局 ─────
  const removable = Array.from({ length: 3 }, (_, i) => `/remove-${i}.png`);
  await context.handleFilePaths(removable);
  const sixthRun = context.startCompression(false);
  await flush();
  start(removable[0]); done(removable[0]);
  cancelAck(removable[1]);
  start(removable[2]); done(removable[2]);
  settleRun();
  await sixthRun;
  assert.equal(stateOf(removable[1]), 'removed', '明确取消的才是 removed');
  assert.equal(progressOf().total, 23, 'removed 从队列总数里排除');
  assert.equal(progressOf().pending, 0);

  // 同一路径在旧 worker 结束前移除又导入：旧结果不能写到新队列项。
  const reused = '/reused.png';
  await context.handleFilePaths([reused]);
  const seventhRun = context.startCompression(false);
  await flush();
  const oldItem = context.queueItems.get(reused);
  start(reused);
  cancelAck(reused);
  await context.handleFilePaths([reused]);
  assert.notEqual(context.queueItems.get(reused), oldItem);
  done(reused);
  assert.equal(stateOf(reused), 'pending', '旧 worker 的完成事件不能覆盖重新导入的项');
  settleRun();
  await seventhRun;

  console.log('PASS: 会话模型（暂停续跑同轮、停止继续换轮、旧事件隔离、失败不自动重试、进度不倒扣）');
})().catch(error => { console.error(error); process.exitCode = 1; });
