// 历史页：密集列表、状态文案、只发 historyId 的恢复调用，以及冲突后的强制重试。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('frontend/app.js', 'utf8');

function makeEl(tag) {
  let html = '';
  const node = {
    tagName: tag, children: [], style: {}, dataset: {}, attrs: {},
    className: '', title: '', hidden: false, handlers: {},
    classList: {
      _set: new Set(),
      add(...names) { names.forEach(name => node.classList._set.add(name)); },
      remove(...names) { names.forEach(name => node.classList._set.delete(name)); },
      toggle(name, force) {
        const on = force === undefined ? !node.classList._set.has(name) : !!force;
        on ? node.classList._set.add(name) : node.classList._set.delete(name);
      },
      contains: name => node.classList._set.has(name),
    },
    appendChild(child) { node.children.push(child); return child; },
    addEventListener(type, fn) { node.handlers[type] = fn; },
    setAttribute(key, value) { node.attrs[key] = value; },
    getAttribute(key) { return node.attrs[key]; },
    querySelector(selector) {
      node._parts = node._parts || {};
      if (!node._parts[selector]) node._parts[selector] = makeEl('span');
      return node._parts[selector];
    },
  };
  Object.defineProperty(node, 'innerHTML', {
    get: () => html,
    set(value) { html = value; if (value === '') node.children.length = 0; },
  });
  Object.defineProperty(node, 'textContent', {
    get: () => node._text || '',
    set(value) { node._text = String(value); node.children.length = 0; },
  });
  return node;
}

const ids = {
  mainView: makeEl('div'), historyView: makeEl('div'), settingsView: makeEl('div'),
  historyViewBtn: makeEl('button'), settingsViewBtn: makeEl('button'),
  historyList: makeEl('div'), historyEmpty: makeEl('div'), historyMeta: makeEl('span'),
  historyClearBtn: makeEl('button'),
  compressBtnText: makeEl('span'), pauseCompressBtn: makeEl('button'), pauseBtnText: makeEl('span'),
  queueSummary: makeEl('span'), restoreAllBtn: makeEl('button'), retentionDays: makeEl('select'),
  retentionCopy: makeEl('span'),
};
const invoked = [];
let historyReply = [];
let retentionReply = 0;   // 后端默认档位：不保留
let restoreReply = { success: true, conflict: false, filePath: '/Pictures/a.png', historyIds: ['1'] };
let restoreAllReply = { success: true, restored: 0, failed: 0, message: '', restoredFiles: [] };
let confirmAnswer = true;
const toasts = [];

const context = vm.createContext({
  console, Set, Map, Promise, JSON, Math, Date, Number, String, Array, Object, isNaN,
  files: ['/Pictures/a.png', '/Pictures/b.png'], results: [], fileRows: {},
  isCompressing: false, processingMode: 'advanced',
  confirm: () => confirmAnswer,
  document: {
    getElementById: id => ids[id] || null,
    createElement: makeEl,
    querySelector: () => null,
    addEventListener() {},
  },
  iconMarkup: name => '<svg>' + name + '</svg>',
  showToast: message => toasts.push(message),
  updateQueueSummary() {}, emitCompareResultsChanged() {}, showResults() {},
  renderRestoredActions() {},
  applyQueueView() {}, updateBulkActionButtons() {}, setPauseButtonVisible() {},
  renderPauseControls() {},
  loadCpuSetting: async () => {},
  invoke: async (command, args) => {
    invoked.push([command, args]);
    if (command === 'list_history') return historyReply;
    if (command === 'get_app_settings') return { originalRetentionDays: retentionReply };
    if (command === 'set_original_retention_days') {
      retentionReply = args.days;
      return { originalRetentionDays: args.days };
    }
    if (command === 'restore_all') return restoreAllReply;
    if (command === 'restore_history_entry' || command === 'restore_original') {
      // 后端只在没被 force 时报冲突，否则就是死循环了。
      return restoreReply.conflict && !args.force
        ? restoreReply
        : { success: true, conflict: false, filePath: '/Pictures/a.png', historyIds: ['e1'] };
    }
    return null;
  },
});
const slice = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));
vm.runInContext(slice('function basename(', 'function imageFileSrc('), context);
vm.runInContext(slice('function formatBytes(', '// ─── 页面导航'), context);
vm.runInContext(slice('var VIEWS = ', '// ─── 暂停 / 继续'), context);
vm.runInContext(slice('var RESTORE_CONFLICT_TEXT', 'async function exportAll('), context);
vm.runInContext(slice('var historyEntries = [];', '// ─── 设置页'), context);
vm.runInContext(
  slice('// ─── 设置页：原图备份保留时间', '// ─── 设置页：CPU 使用上限'), context);

const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
const entry = extra => Object.assign({
  id: 'e1', createdAt: Date.now(), expiresAt: 0,
  sourcePath: '/Pictures/a.png', outputPath: '/Pictures/a.png', fileName: 'a.png',
  outputMode: 'replace', originalSize: 2048576, compressedSize: 204800, savings: 90,
  outType: 'webp', algorithm: 'webp-mozquant', backupPath: '/app/backup/a.png',
  status: 'compressed', restoredAt: null, outputModifiedAt: 0,
  sourceExists: true, backupExists: true,
}, extra);
const text = node => (node.children.length ? node.children.map(text).join(' ') : node.textContent);
const last = name => [...invoked].reverse().find(call => call[0] === name);

(async () => {
  historyReply = [entry({}), entry({ id: 'e2', fileName: 'b.png', sourcePath: '/Pictures/b.png' })];
  await context.refreshHistory();
  assert.deepEqual(ids.historyList.children.map(row => row.className), ['history-item', 'history-item']);
  assert.equal(ids.historyList.children.length, 2, 'renders newest first, as stored');
  assert.equal(ids.historyMeta.textContent, '2 条');
  assert.equal(ids.historyEmpty.hidden, true);
  const row = ids.historyList.children[0];
  assert.match(text(row), /a\.png/);
  assert.match(text(row), /\/Pictures/);
  assert.match(text(row), /2\.0MB → 200\.0KB/);
  assert.match(text(row), /节省 90\.0%/);
  assert.match(text(row), /webp-mozquant/);
  assert.match(text(row), /已压缩/);

  // 只有覆盖原文件、且备份与原位置都在，才给恢复入口。
  assert.equal(row.children[4].children.length, 2, '恢复原图 + 访达');
  const suffix = entry({ id: 'e3', outputMode: 'suffix', status: 'compressed' });
  ids.historyList.children = [];
  context.historyEntries = [suffix];
  context.renderHistory();
  assert.ok(text(ids.historyList.children[0]).includes('原图未覆盖'));
  assert.equal(ids.historyList.children[0].children[4].children.length, 1, '后缀模式没有恢复按钮');
  assert.ok(text(context.historyRow(entry({ status: 'restored', restoredAt: entry().createdAt }))).includes('已恢复 · 今天'));
  assert.ok(text(context.historyRow(entry({ sourceExists: false }))).includes('原文件位置不存在'));
  assert.ok(text(context.historyRow(entry({ backupExists: false }))).includes('原图备份已清理'));

  // ── history.json 损坏后按备份重建出来的条目：明细丢了，但原图还能一键恢复 ──
  const recovery = context.historyRow(
    entry({ id: 'recovery-k1', status: 'recoveryAvailable', savings: 0, algorithm: 'recovery' }));
  const recoveryText = text(recovery);
  assert.match(recoveryText, /检测到可恢复的原图备份/);
  assert.doesNotMatch(recoveryText, /节省/, '没有真实明细就不许报一个算出来的 0.0%');
  assert.match(recoveryText, /按备份重建/);
  assert.equal(recovery.children[4].children.length, 2, '重建条目必须给出恢复按钮');
  assert.equal(
    context.historyRow(entry({ id: 'r2', status: 'recoveryAvailable', backupExists: false }))
      .children[4].children.length,
      1, '备份已被清掉的重建条目不该再挂恢复按钮');

  // 冲突：先确认，再带 force 重来；取消则一发都不发。
  restoreReply = { success: false, conflict: true, filePath: '/Pictures/a.png', error: '这个文件在压缩后又被修改过', historyIds: [] };
  confirmAnswer = false;
  await context.restoreFromHistory(entry());
  assert.equal(last('restore_history_entry')[1].force, false, 'first attempt must not force');
  assert.ok(![...invoked].some(call => call[1] && call[1].force === true), '取消后不得强制覆盖');
  confirmAnswer = true;
  await context.restoreFromHistory(entry());
  const forced = last('restore_history_entry');
  assert.equal(forced[1].force, true, 'confirming retries with force');
  assert.deepEqual(Object.keys(forced[1]).sort(), ['force', 'historyId'], '前端不拼路径，只交 historyId');

  // 主队列的「恢复原图」必须走同一个后端服务：前端只交 filePath，路径由后端从历史里取。
  restoreReply = { success: true, conflict: false, filePath: '/Pictures/a.png', historyIds: ['e1'] };
  const rowA = makeEl('div');
  rowA.classList.add('done');
  context.fileRows['/Pictures/a.png'] = rowA;
  context.results = [{ file: '/Pictures/a.png', success: true, backupPath: '/app/backup/a.png', outputPath: '/Pictures/a.png' }];
  await context.restoreOriginal('/Pictures/a.png');
  assert.deepEqual(Object.keys(last('restore_original')[1]).sort(), ['filePath', 'force'], '主队列只交 filePath');
  assert.equal(context.results.length, 0, 'restored file leaves the result set');
  assert.equal(rowA.classList.contains('restored'), true, '队列行标记为已恢复');
  assert.equal(rowA.classList.contains('done'), false);
  assert.equal(rowA.querySelector('.queue-item-status').textContent, '已恢复');

  // 恢复全部：一次后端调用，按后端回报的文件逐行标记。
  const rowB = makeEl('div');
  rowB.classList.add('done');
  context.fileRows['/Pictures/b.png'] = rowB;
  context.results = [
    { file: '/Pictures/a.png', success: true },
    { file: '/Pictures/b.png', success: true },
    { file: '/Pictures/c.png', success: false },
  ];
  invoked.length = 0;
  restoreAllReply = { success: true, restored: 2, failed: 0, message: '已恢复 2 个文件',
    restoredFiles: ['/Pictures/a.png', '/Pictures/b.png'] };
  await context.restoreAllOriginals();
  const all = last('restore_all');
  assert.equal(all[1].results.length, 3, '整批交给后端，前端不再逐个拼参数');
  assert.ok(!invoked.some(call => call[0] === 'restore_original'), '恢复全部不再走单文件命令');
  assert.equal(rowB.classList.contains('restored'), true);
  assert.deepEqual(context.results.map(item => item.file), ['/Pictures/c.png'], '失败行留在队列里');

  // 页面切换只动 display：队列数据必须原样留着。
  context.showView('history');
  await flush();
  assert.equal(context.currentView, 'history');
  assert.deepEqual(context.files, ['/Pictures/a.png', '/Pictures/b.png']);
  assert.equal(ids.mainView.style.display, 'none');
  assert.equal(ids.historyView.style.display, '');
  context.showView('settings');
  assert.equal(ids.settingsView.style.display, '');
  context.showView('nonsense');
  assert.equal(ids.mainView.style.display, '', 'unknown view falls back to main');

  // ── 原图备份保留时间：「不保留」= 0，是一个真实档位而不是"没设置" ──
  retentionReply = 7;
  await context.loadRetentionSetting();
  assert.equal(ids.retentionDays.value, '7');
  assert.doesNotMatch(ids.retentionCopy.textContent, /关闭应用时清理/, '按天保留不该说退出清理');
  retentionReply = 0;
  await context.loadRetentionSetting();
  assert.equal(ids.retentionDays.value, '0', '0 不能被真值判断吞掉，停在 7 天');
  assert.match(ids.retentionCopy.textContent, /关闭应用时清理/);
  assert.match(ids.retentionCopy.textContent, /恢复原图/, '要说清楚这期间仍可恢复');

  // 选「不保留」必须原样传 0 —— `parseInt(...) || 3` 会把它偷偷变成 3 天。
  invoked.length = 0;
  toasts.length = 0;
  ids.retentionDays.value = '0';
  ids.retentionDays.handlers.change();
  await flush();
  assert.equal(last('set_original_retention_days')[1].days, 0);
  assert.match(toasts[toasts.length - 1], /不保留/);
  assert.doesNotMatch(toasts[toasts.length - 1], /保留 0 天/, '不许说"保留 0 天"这种半截话');

  ids.retentionDays.value = '3';
  ids.retentionDays.handlers.change();
  await flush();
  assert.equal(last('set_original_retention_days')[1].days, 3);
  assert.match(ids.retentionCopy.textContent, /下次启动应用时自动清理/);

  const settingsHtml = fs.readFileSync('frontend/index.html', 'utf8');
  assert.match(settingsHtml, /<option value="0">不保留<\/option>/);
  assert.ok(
    settingsHtml.indexOf('<option value="0">') < settingsHtml.indexOf('<option value="1">'),
    '「不保留」是默认档，排第一');

  // ── 压缩进行中不许清空历史：后端会拒绝，前端先收成不可点，别让人撞报错 ──
  context.historyEntries = [entry({})];
  context.isCompressing = true;
  context.renderHistory();
  assert.equal(ids.historyClearBtn.disabled, true, '批次跑着的时候清空按钮必须不可点');
  assert.match(ids.historyClearBtn.title, /压缩进行中/);
  invoked.length = 0;
  toasts.length = 0;
  await context.clearHistory();
  assert.ok(!invoked.some(call => call[0] === 'clear_history'), '前端就不该发这次清空');
  assert.match(toasts[toasts.length - 1], /压缩进行中/);

  context.isCompressing = false;
  context.renderHistory();
  assert.equal(ids.historyClearBtn.disabled, false, '批次结束后必须恢复可用');
  invoked.length = 0;
  await context.clearHistory();
  assert.ok(invoked.some(call => call[0] === 'clear_history'), '空闲时清空照常走后端');

  console.log('PASS: dense history rows, per-state copy, 重建条目可恢复, restore without paths, conflict force retry, queue restore shares the service, 不保留档位, 压缩中拒绝清空');
})().catch(error => { console.error(error); process.exitCode = 1; });
