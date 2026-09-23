// 更新面板：从标题栏气泡搬进设置页之后的两条不变量。
// ① 结构：更新控件只活在 #settingsView 里，标题栏一个都不剩（含样式不许留死规则）。
// ② 行为：App Store 版不加载 updater 插件 —— 那一行必须整行消失，
//    而不是留一个按下去只会失败的按钮；下载停下来（取消/失败）必须把进度收干净。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

const html = fs.readFileSync('frontend/index.html', 'utf8');
const css = fs.readFileSync('frontend/style.css', 'utf8');
const source = fs.readFileSync('frontend/app.js', 'utf8');

// ── 结构 ──────────────────────────────────────────────────────────────
const settingsStart = html.indexOf('id="settingsView"');
assert.ok(settingsStart > 0, '找不到设置页容器');
['updateVersion', 'updateStatus', 'updateCheckRow', 'updateCheckBtn',
 'updateDownloadRow', 'updateProgressFill', 'updateProgressText',
 'updateDirectNote', 'updateAppStoreNote'].forEach(id => {
  assert.ok(html.indexOf('id="' + id + '"') > settingsStart, id + ' 必须在设置页容器内');
});
['titlebarUpdate', 'titlebarUpdateText', 'aboutUpdateBtn', 'aboutUpdateStatus'].forEach(id =>
  assert.equal(html.indexOf('id="' + id + '"'), -1, id + ' 已经搬走，不许回流'));
['.titlebar-update', '.titlebar-info-status', '.titlebar-info-link'].forEach(rule =>
  assert.equal(css.indexOf(rule), -1, rule + ' 是死规则，标记没了就该一起删'));
['update-col', 'update-version', 'update-status', 'update-link',
 'update-progress', 'update-progress-fill', 'update-progress-text'].forEach(name =>
  assert.ok(css.includes('.' + name), '.' + name + ' 在 HTML 里用了，样式必须还在'));
// 标题栏只剩窗口级进度条：下载时切回队列页也看得见动静。
assert.ok(html.includes('id="titlebarProgress"'));
assert.ok(css.includes('.titlebar-progress'));

// ── 行为 ──────────────────────────────────────────────────────────────
function field(extra) {
  return Object.assign({
    style: {}, dataset: {}, textContent: '', disabled: false, onclick: null,
    classList: { _set: new Set(),
      add(name) { this._set.add(name); }, remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); } },
  }, extra);
}

function makeEnv(variant) {
  const els = {};
  ['updateVersion', 'updateStatus', 'updateCheckRow', 'updateCheckBtn', 'updateDownloadRow',
   'updateProgressFill', 'updateProgressText', 'updateDirectNote', 'updateAppStoreNote',
   'titlebarProgress'].forEach(id => { els[id] = field(); });
  const calls = [];
  const env = {
    els, calls, updateReply: null, installMode: 'pending', progress: null,
  };
  const context = vm.createContext({
    console: { warn() {}, log() {} }, Set, Promise, String, Math, Object,
    BUILD_VARIANT: variant,
    window: { appVersion: '2.5.35' },
    document: { getElementById: id => els[id] || null },
    invoke: async (command, args) => {
      calls.push([command, args]);
      if (command === 'check_for_update') return env.updateReply;
      if (command === 'install_update') {
        if (env.installMode === 'fail') throw new Error('更新失败');
        if (env.installMode === 'cancelled') throw new Error('用户取消下载');
        return null;
      }
      return null;
    },
    listen: async (event, callback) => { env.progress = callback; return () => { env.progress = null; }; },
  });
  const slice = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));
  vm.runInContext(slice('/// 更新面板在设置页里', 'function updateSettingsSummary('), context);
  env.ctx = context;
  const last = name => [...calls].reverse().find(call => call[0] === name);
  env.last = last;
  return env;
}

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

(async () => {
  // ── App Store 版：整行消失 + 一句实话 ──
  const store = makeEnv('App Store');
  store.ctx.initUpdatePanel();
  assert.equal(store.els.updateVersion.textContent, 'v2.5.35 App Store');
  assert.equal(store.els.updateCheckRow.style.display, 'none', 'App Store 版不许挂检查更新按钮');
  assert.equal(store.els.updateDirectNote.style.display, 'none');
  assert.equal(store.els.updateAppStoreNote.style.display, '', '要说明更新归 App Store 管');
  await store.ctx.checkDirectUpdate();
  await flush();
  assert.ok(!store.calls.some(call => call[0] === 'check_for_update'),
    'App Store 版连请求都不该发出去');

  // ── Direct 版：面板可用，静默检查与用户点击共用同一块状态 ──
  const direct = makeEnv('Direct');
  direct.ctx.initUpdatePanel();
  assert.equal(direct.els.updateVersion.textContent, 'v2.5.35 Direct');
  assert.equal(direct.els.updateCheckRow.style.display, '', 'Direct 版这一行要出现');
  assert.equal(direct.els.updateDirectNote.style.display, '');
  assert.equal(direct.els.updateAppStoreNote.style.display, 'none');

  // 版本号是异步取的：没取到之前宁可留占位，不许写出半截「 Direct」。
  const early = makeEnv('Direct');
  early.ctx.window.appVersion = null;
  early.ctx.initUpdatePanel();
  assert.equal(early.els.updateVersion.textContent, '', '取不到版本就别说版本');
  assert.equal(early.els.updateCheckRow.style.display, '', '显隐不该依赖版本号到没到');

  // 最新：给出「已是最新版本」，而不是把按钮摆成还能按的样子。
  direct.updateReply = null;
  await direct.ctx.manualCheckUpdate();
  await flush();
  assert.equal(direct.els.updateStatus.textContent, '已是最新版本');
  assert.equal(direct.els.updateCheckBtn.textContent, '检查更新');
  assert.equal(direct.els.updateCheckBtn.disabled, false);

  // 静默启动检查可能先于用户进设置页就发现新版本：谁先来谁写，写上的不许被抹掉。
  direct.updateReply = { version: '9.9.9' };
  await direct.ctx.checkDirectUpdate();
  await flush();
  assert.equal(direct.els.updateCheckBtn.textContent, '立即更新');
  assert.equal(direct.els.updateStatus.textContent, 'v9.9.9 可用');
  assert.equal(direct.els.updateStatus.classList.contains('has-update'), true);
  direct.ctx.initUpdatePanel();
  assert.equal(direct.els.updateStatus.textContent, 'v9.9.9 可用', '进设置页不该把发现结果清掉');

  // 下载中：面板进度行 + 标题栏窗口级进度条同时动。
  direct.installMode = 'pending';
  direct.els.updateCheckBtn.onclick();
  await flush();
  assert.ok(direct.calls.some(call => call[0] === 'install_update'));
  assert.equal(direct.els.updateDownloadRow.style.display, '');
  assert.equal(typeof direct.progress, 'function', '下载必须订阅 update-progress');
  direct.progress({ payload: 42 });
  assert.equal(direct.els.updateProgressFill.style.width, '42%');
  assert.equal(direct.els.titlebarProgress.style.width, '42%');
  assert.equal(direct.els.updateProgressText.textContent, '下载中 42%');
  assert.equal(direct.els.updateCheckBtn.disabled, true);

  // 下载中再点检查更新必须被挡：按钮此刻的活儿是「立即更新」，不是重新检查。
  direct.calls.length = 0;
  await direct.ctx.manualCheckUpdate();
  assert.ok(!direct.calls.some(call => call[0] === 'check_for_update'),
    'dataset.downloading 必须真挡住重入');

  // 取消：进度行收起、两根条归零、按钮回到「立即更新」。
  await direct.ctx.cancelUpdateDownload();
  await flush();
  assert.ok(direct.last('cancel_update'), '取消要真的通知后端');
  assert.equal(direct.els.updateDownloadRow.style.display, 'none');
  assert.equal(direct.els.updateProgressFill.style.width, '0%');
  assert.equal(direct.els.titlebarProgress.style.width, '0%');
  assert.equal(direct.els.updateCheckBtn.disabled, false);
  assert.equal(direct.els.updateCheckBtn.textContent, '立即更新');
  assert.equal(direct.els.updateStatus.textContent, '已取消', '说的是刚刚发生的事');

  // 失败：文案要说「更新失败」，不许伪装成已取消。
  direct.installMode = 'fail';
  direct.els.updateCheckBtn.onclick();
  await flush();
  assert.equal(direct.els.updateStatus.textContent, '更新失败');
  assert.equal(direct.els.updateDownloadRow.style.display, 'none');
  assert.equal(direct.els.updateCheckBtn.disabled, false);

  console.log('PASS: 更新面板只在设置页、App Store 版整行消失、下载进度用完收干净');
})().catch(error => { console.error(error); process.exit(1); });
