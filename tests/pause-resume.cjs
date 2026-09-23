// 暂停 / 继续 / 停止：四个阶段（idle / running / paused / stopping）怎么画、怎么发信号。
//
// 这一组钉住三件最容易做错的事：
//   1. 暂停后 loading 必须停 —— 转圈的圆环换成静态暂停图标，行文案变「已暂停」；
//   2. 停止是批次级的、且**不可逆**：等待中的作废，已经在跑的跑完，绝不 kill 子进程；
//   3. 前端只发信号，闸门由后端把着；取消 / 停止绝不许顺手解除暂停。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { source, slice, stateMachine, installStateMachine } = require('./app-slices.cjs');
const stateMachineSlice = stateMachine();

// 与 app.js 里 iconMarkup 同构：断言才能直接找 #icon-pause / #icon-stop。
const icon = (name, small) => '<svg class="symbol-icon' + (small ? ' symbol-icon-small' : '')
  + '" aria-hidden="true"><use href="#icon-' + name + '"></use></svg>';

const el = () => ({
  style: {}, title: '', innerHTML: '', textContent: '', disabled: false,
  classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
  setAttribute() {}, querySelector: () => null,
});
const elements = {
  queueSummary: el(), compressBtnText: el(),
  pauseCompressBtn: el(), pauseBtnText: el(), stopCompressBtn: el(), stopBtnText: el(),
  restoreAllBtn: el(),
};
const calls = [];
let failNext = null;   // 下一次 invoke 要失败的命令名
const context = vm.createContext({
  console: { log: console.log, warn: console.warn, error: message => calls.push(['error', message]) },
  Set, Map, Promise, JSON,
  files: Array.from({ length: 20 }, (_, i) => `/img-${i}.png`),
  results: [], processingMode: 'advanced',
  activeBatchRows: new Map(),
  document: { getElementById: id => elements[id] || null },
  applyQueueView() {}, showToast(message) { calls.push(['toast', message]); },
  iconMarkup: icon,
  invoke: async (command, args) => {
    calls.push([command, args]);
    if (failNext === command) { failNext = null; throw new Error('ipc down'); }
    return null;
  },
});
installStateMachine(context);
vm.runInContext(slice('function updateQueueSummary(', 'function toggleQueueSortDirection('), context);
vm.runInContext(slice('function processingActionText(', 'function setProcessingMode('), context);

const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
const last = name => [...calls].reverse().find(call => call[0] === name);
const countOf = needle => source.split(needle).length - 1;

(async () => {
  // ── 文案与按钮：暂停 ↔ 继续 ────────────────────────────────
  assert.match(context.pauseButtonText(false), /暂停/);
  assert.match(context.pauseButtonText(true), /继续/);
  assert.match(context.stopButtonText(false), /停止/);
  assert.match(context.stopButtonText(true), /正在停止…/);

  assert.equal(context.compressionState, 'idle');
  context.setCompressionState('running', true);

  await context.toggleCompressionPause();
  assert.ok(last('pause_compression'), '第一次点击必须请后端暂停');
  assert.equal(context.compressionState, 'paused');
  assert.equal(context.compressionPaused, true);
  assert.equal(context.isCompressing, true, '暂停不是结束：批次还在');
  assert.match(elements.pauseBtnText.innerHTML, /继续/, '按钮要变成「继续」');
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成 · 已暂停');

  // 暂停后动画必须停：进度按钮上是静态暂停图标，不再是转圈的圆环。
  assert.match(elements.compressBtnText.innerHTML, /暂停中…/);
  assert.ok(!elements.compressBtnText.innerHTML.includes('progress-file-spinner'),
    '暂停后进度按钮不许还挂着转圈的 loading');
  assert.match(elements.compressBtnText.innerHTML, /#icon-pause/);

  // 等待中的行：暂停时不写「等待中」、不带 spinner，而是暂停图标 + 已暂停。
  const rowStub = (classes) => {
    const parts = { '.queue-item-icon': { innerHTML: '' }, '.queue-item-status': { textContent: '' } };
    return {
      parts,
      classList: { contains: name => classes.indexOf(name) >= 0 },
      querySelector: selector => parts[selector] || null,
    };
  };
  const waitingRow = rowStub(['waiting']);
  context.activeBatchRows.set('/img-1.png', waitingRow);
  context.activeBatchRows.set('/img-2.png', rowStub(['compressing']));
  context.renderPauseControls();
  assert.equal(waitingRow.parts['.queue-item-status'].textContent, '已暂停');
  assert.match(waitingRow.parts['.queue-item-icon'].innerHTML, /#icon-pause/);
  assert.ok(!waitingRow.parts['.queue-item-icon'].innerHTML.includes('progress-file-spinner'),
    '暂停时排队的行不许还转着圈');
  assert.equal(context.taskStatusMarkup('paused').text, '已暂停');
  assert.match(context.taskStatusMarkup('running').icon, /progress-file-spinner/,
    '真正在压缩的行才该转圈');

  await context.toggleCompressionPause();
  assert.ok(last('resume_compression'), '第二次点击必须请后端继续');
  assert.equal(context.compressionState, 'running');
  assert.equal(context.compressionPaused, false);
  assert.match(elements.compressBtnText.innerHTML, /压缩中…/);
  assert.match(elements.compressBtnText.innerHTML, /progress-file-spinner/,
    '继续之后 loading 必须回来');
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成', '已暂停 必须消失');

  // ── 后端拒绝时不能把 UI 停在错误状态 ────────────────────────
  failNext = 'pause_compression';
  await context.toggleCompressionPause();
  assert.equal(context.compressionState, 'running', '暂停失败必须回滚到 running');
  assert.equal(context.compressionPaused, false);
  assert.ok(last('error'), '失败要写日志');
  assert.deepEqual(last('toast'), ['toast', '暂停失败，请重试']);

  // ── 停止：批次级、立即生效、不可逆 ──────────────────────────
  calls.length = 0;
  context.pendingAutoCompress = true;
  await context.stopCompression();
  assert.ok(last('stop_compression'), '停止必须发 stop_compression');
  assert.equal(calls.filter(call => call[0] === 'stop_compression').length, 1,
    '一次停止只发一次请求');
  assert.ok(!calls.some(call => call[0] === 'resume_compression'),
    '停止路径里绝不许出现 resume_compression');
  assert.equal(context.compressionState, 'stopping');
  assert.equal(context.isCompressing, true, '停止期间批次仍在：还要等已经在跑的收尾');
  assert.equal(context.pendingAutoCompress, false, '停止之后不许自动续跑下一批');
  assert.match(elements.compressBtnText.innerHTML, /正在停止…/);
  assert.match(elements.stopBtnText.innerHTML, /正在停止…/);
  assert.equal(elements.pauseCompressBtn.disabled, true, '停止途中暂停按钮要禁用');
  assert.equal(elements.stopCompressBtn.disabled, true, '停止途中停止按钮要禁用');
  assert.equal(context.taskStatusMarkup('stopping').text, '已跳过',
    '停止后还在排队的文件不会再有产出，行上就该写「已跳过」');

  // 停止途中再点暂停 / 继续：什么都不许发生（闸门已经焊死）。
  calls.length = 0;
  await context.toggleCompressionPause();
  assert.deepEqual(calls, [], '停止途中点暂停必须是无操作');
  assert.equal(context.compressionState, 'stopping');

  // 重复点停止也只发一次。
  calls.length = 0;
  await context.stopCompression();
  assert.deepEqual(calls, [], '重复点停止不该重复发请求');

  // ── 停止失败：回滚到原来那个阶段，别把 UI 卡在"正在停止" ────
  context.setCompressionState('running', true);
  failNext = 'stop_compression';
  await context.stopCompression();
  assert.equal(context.compressionState, 'running', '停止失败必须回滚');
  assert.deepEqual(last('toast'), ['toast', '停止失败，请重试']);

  // ── 后端事件的采纳规则 ────────────────────────────────────
  context.applyCompressionStateEvent({ state: 'paused' });
  assert.equal(context.compressionState, 'paused', '后端说暂停了，UI 就得跟');
  context.applyCompressionStateEvent({ state: 'idle' });
  assert.equal(context.compressionState, 'paused',
    '迟到的 idle 不许把一个还在跑的批次打回空闲');
  context.setCompressionState('idle', true);
  context.applyCompressionStateEvent({ state: 'running' });
  assert.equal(context.compressionState, 'idle', '本地没有批次时不接受别人的 running');
  context.applyCompressionStateEvent({ state: 'nonsense' });
  assert.equal(context.compressionState, 'idle', '未知状态一律忽略');

  // ── 空闲态：摘要说自己的话，按钮不被改写 ────────────────────
  elements.compressBtnText.innerHTML = 'IDLE-SENTINEL';
  context.renderPauseControls();
  assert.equal(elements.queueSummary.textContent, '20 个文件');
  assert.equal(elements.compressBtnText.innerHTML, 'IDLE-SENTINEL',
    '空闲态不许改写进度按钮（那是"开始压缩"该有的样子）');

  context.setPauseButtonVisible(false);
  assert.equal(elements.pauseCompressBtn.style.display, 'none');
  assert.equal(elements.stopCompressBtn.style.display, 'none', '两个按钮一起显示/隐藏');
  context.setPauseButtonVisible(true);
  assert.equal(elements.stopCompressBtn.style.display, 'inline-flex');

  // ── 单写入口：镜像只能由 setCompressionState 写 ─────────────
  // 状态机那一段之外，一个字都不许直接动 isCompressing / compressionPaused，
  // 否则又会出现"两个真相"（暂停了但按钮不知道，正是老 bug 的形状）。
  const outsideStateMachine = source.replace(stateMachineSlice, '');
  ['isCompressing', 'compressionPaused', 'compressionState'].forEach(name => {
    const writes = outsideStateMachine.match(new RegExp(name + '\\s*=[^=]', 'g')) || [];
    assert.deepEqual(writes, [], `状态机之外不许直接给 ${name} 赋值：${writes.join(', ')}`);
  });
  assert.equal(stateMachineSlice.split('isCompressing =').length - 1, 2,
    'isCompressing 只该有声明 + setCompressionState 里那一次赋值');
  assert.equal(countOf('progress-file-spinner'), stateMachineSlice.split('progress-file-spinner').length - 1,
    'spinner 只许出现在状态机那一段的"状态表"与"进度按钮"两处，不许散落各处以 innerHTML 拼');

  // ── 取消整批仍然是"只叫醒、不开门" ──────────────────────────
  assert.equal(countOf("invoke('cancel_file'"), 1, '只有队列里单个文件才逐个取消');
  assert.equal(countOf("invoke('cancel_batch'"), 2, '清空全部与清除结果各发一次批量取消');

  const batchCalls = [];
  const paths = ['/a.png', '/b.png', '/c.png'];
  const batch = vm.createContext({
    console, Set, Map, Promise, JSON,
    files: paths.slice(), results: [], inputPaths: [], fileRows: {},
    queueRevision: 0, pendingAutoCompress: true,
    activeBatchPaths: paths.slice(), activeBatchSet: new Set(paths),
    activeBatchRows: new Map(), activeBatchRevision: 7,
    cancelledFiles: new Set(),
    confirm: () => true,
    document: { getElementById: () => null },
    settingsPanel: { style: {} }, resultsPanel: { style: {} },
    updateQueueSummary() {}, emitCompareResultsChanged() {},
    invoke: async (command, args) => { batchCalls.push([command, args]); return null; },
  });
  installStateMachine(batch);
  batch.setCompressionState('paused', true);
  vm.runInContext(slice('function clearAllFiles(', '// ─── Compression'), batch);
  batch.clearAllFiles();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(batchCalls.length, 1, `清空全部只许发一次取消请求：${JSON.stringify(batchCalls)}`);
  assert.equal(batchCalls[0][0], 'cancel_batch');
  assert.deepEqual(batchCalls[0][1].filePaths, paths);
  assert.deepEqual([...batch.cancelledFiles], paths, '这批路径必须全部标记为已取消');
  assert.equal(batch.pendingAutoCompress, false);
  assert.equal(batch.compressionState, 'paused', '取消不能把暂停闸门打开');
  assert.ok(!batchCalls.some(call => call[0] === 'resume_compression'),
    '取消路径里绝不许出现 resume_compression');

  console.log('PASS: 四态状态机、暂停停动画、停止不可逆且不自动续跑、失败回滚、单写入口');
})().catch(error => { console.error(error); process.exitCode = 1; });
