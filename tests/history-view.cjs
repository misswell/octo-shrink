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
  copyTextToClipboard: () => true,
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
        : { success: true, conflict: false, filePath: '/Pictures/a.png',
            historyIds: ['e1'], outputMode: 'replace' };
    }
    return null;
  },
});
const slice = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));
vm.runInContext(slice('function basename(', 'function imageFileSrc('), context);
vm.runInContext(slice('function formatBytes(', '// ─── 页面导航'), context);
vm.runInContext(slice('var VIEWS = ', '// ─── 暂停 / 继续'), context);
vm.runInContext(slice('var RESTORE_CONFLICT_TEXT', 'async function exportAll('), context);
vm.runInContext(slice('function renderQueueResultActions(', 'function copyCompressLog('), context);
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
  sourceExists: true, backupExists: true, outputExists: true,
}, extra);
const text = node => (node.children.length ? node.children.map(text).join(' ') : node.textContent);
const last = name => [...invoked].reverse().find(call => call[0] === name);
/// 一行的按钮身份：dataset.historyAction 就是它要做的事，比数个数更能说明问题。
const actionsOf = row => row.children[4].children.map(btn => btn.dataset.historyAction);

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

  // 一行的按钮 = 这条记录此刻真能做到的事；只有覆盖过且备份、原位置都在才谈得上恢复。
  assert.deepEqual(actionsOf(row), ['save', 'compare', 'restore', 'finder', 'log'],
    '覆盖模式：与压缩完成那一行同一套动作');

  const suffix = entry({ id: 'e3', outputMode: 'suffix', status: 'compressed',
    outputPath: '/Pictures/a_compressed.png' });
  ids.historyList.children = [];
  context.historyEntries = [suffix];
  context.renderHistory();
  const suffixRow = ids.historyList.children[0];
  assert.ok(text(suffixRow).includes('原图未覆盖'));
  // 后缀模式的原图从没被盖过：给它「恢复原图」是假的，对等的反悔是删掉这次产物。
  assert.deepEqual(actionsOf(suffixRow), ['save', 'compare', 'deleteOutput', 'finder', 'log']);
  assert.ok(!actionsOf(suffixRow).includes('restore'), '后缀模式绝不许出现恢复原图');

  // 删除这次压缩结果 = 同一个后端服务、同样只交 historyId，前端不碰文件路径。
  invoked.length = 0;
  toasts.length = 0;
  suffixRow.children[4].children[2].handlers.click();
  await flush();
  // 跨 vm 上下文的对象比不了引用，逐字段来。
  assert.equal(last('restore_history_entry')[1].historyId, 'e3');
  assert.equal(last('restore_history_entry')[1].force, false,
    '非覆盖模式没有"原图被改过"这回事，不该偷偷 force 什么');
  assert.match(toasts[toasts.length - 1], /已删除这次压缩结果/, '不许把删产物报成恢复原图');
  assert.doesNotMatch(toasts[toasts.length - 1], /已恢复原图/);

  // 用户自己把压缩产物删了：指向它的那几个按钮一起收起。
  assert.deepEqual(
    actionsOf(context.historyRow(entry({ id: 'e4', outputMode: 'suffix',
      outputPath: '/Pictures/a_compressed.png', outputExists: false }))),
    ['finder', 'log'],
    '后缀模式下产物没了，这一行就不配再有反悔按钮');
  // 但覆盖模式不一样：产物被删了，原图备份还在 → 恢复必须照给，那才是这条记录的意义。
  assert.ok(actionsOf(context.historyRow(entry({ outputExists: false }))).includes('restore'),
    '压缩结果被删不影响"换回原图"');
  // 备份被清掉：恢复不许继续挂在页面上骗人，也不能退化成删源文件。
  assert.deepEqual(
    actionsOf(context.historyRow(entry({ backupExists: false }))),
    ['save', 'finder', 'log'],
    '原图备份已清理 → 恢复和对比一起收起');
  // 已恢复的记录：反悔已经用掉了。
  assert.ok(!actionsOf(context.historyRow(entry({ status: 'restored', restoredAt: entry().createdAt })))
    .some(name => name === 'restore' || name === 'deleteOutput'),
    '已恢复的行不再提供反悔按钮');
  assert.ok(text(context.historyRow(entry({ status: 'restored', restoredAt: entry().createdAt }))).includes('已恢复 · 今天'));
  assert.ok(text(context.historyRow(entry({ sourceExists: false }))).includes('原文件位置不存在'));
  assert.ok(text(context.historyRow(entry({ backupExists: false }))).includes('原图备份已清理'));

  // 主队列那一行的反悔按钮同样跟着输出方式走文案：后缀模式删的是产物，不是"恢复原图"。
  vm.runInContext(slice('function renderQueueResultActions(', 'function copyCompressLog('), context);
  const queueTitles = mode => {
    const queueRow = makeEl('div');
    context.renderQueueResultActions(queueRow, {
      file: '/Pictures/a.png', success: true, outputMode: mode,
      outputPath: '/Pictures/a.png',
    });
    return queueRow.querySelector('.queue-item-actions').children.map(b => b.title);
  };
  assert.ok(queueTitles('replace').includes('恢复原图'), '覆盖模式仍然叫恢复原图');
  const suffixTitles = queueTitles('suffix');
  assert.ok(!suffixTitles.includes('恢复原图'), '后缀模式的队列行不许写恢复原图');
  assert.ok(suffixTitles.includes('删除这次压缩结果'));

  // ── history.json 损坏后按备份重建出来的条目：明细丢了，但原图还能一键恢复 ──
  const recovery = context.historyRow(
    entry({ id: 'recovery-k1', status: 'recoveryAvailable', savings: 0, algorithm: 'recovery' }));
  const recoveryText = text(recovery);
  assert.match(recoveryText, /检测到可恢复的原图备份/);
  assert.doesNotMatch(recoveryText, /节省/, '没有真实明细就不许报一个算出来的 0.0%');
  assert.match(recoveryText, /按备份重建/);
  assert.ok(actionsOf(recovery).includes('restore'), '重建条目必须给出恢复按钮');
  assert.deepEqual(
    actionsOf(context.historyRow(
      entry({ id: 'r2', status: 'recoveryAvailable', backupExists: false }))),
    ['save', 'finder', 'log'],
    '备份已被清掉的重建条目不该再挂恢复按钮');

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
  // 清空确认框要数得清这一次带走几份原图备份 —— 「手动清理，不用等过期」是这一键的全部含义。
  let question = '';
  context.confirm = message => { question = message; return true; };
  context.historyEntries = [entry({}), entry({ id: 'e9', backupExists: false })];
  await context.clearHistory();
  context.confirm = () => confirmAnswer;
  assert.match(question, /立即删除 OctoShrink 保存的 1 份原图备份/);
  assert.match(question, /不会删除你的任何图片文件/);
  assert.ok(invoked.some(call => call[0] === 'clear_history'), '空闲时清空照常走后端');

  console.log('PASS: dense history rows, 每行按钮=这条记录真能做的事, 重建条目可恢复, restore without paths, conflict force retry, queue restore shares the service, 不保留档位, 压缩中拒绝清空');
})().catch(error => { console.error(error); process.exitCode = 1; });
