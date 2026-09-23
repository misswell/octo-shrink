// 压缩设置面板：默认折叠。
//
// 用户导入图片后先看到的应该是「压缩设置 + 当前参数摘要」这一行，想改再点开 ——
// 而不是每次都被一屏设置项顶到队列前面。三条不变量：
//   ① 初始就带 collapsed（HTML 上写死，不靠 JS 事后补）；
//   ② 只有用户点标题才切换（没有任何代码路径在启动 / 导入 / 清空时自动展开，
//      否则"默认折叠"会在那些路径上悄悄失效）；
//   ③ 折叠起来的那一行必须真有话可说（摘要函数在启动时跑过、CSS 规则在），
//      不然收起来就成了一个什么都不告诉用户的空壳。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

const html = fs.readFileSync('frontend/index.html', 'utf8');
const css = fs.readFileSync('frontend/style.css', 'utf8');
const { source, slice } = require('./app-slices.cjs');

// ── ① 初始折叠：写在 HTML 的 class 里 ─────────────────────────────────
const panelTag = html.match(/<div[^>]*id="settingsPanel"[^>]*>/);
assert.ok(panelTag, '找不到压缩设置面板 #settingsPanel');
const classes = (panelTag[0].match(/class="([^"]*)"/) || [])[1] || '';
assert.ok(classes.split(/\s+/).includes('collapsed'),
  '#settingsPanel 必须带着 collapsed 起手，否则一导入就是展开的一屏设置项');
assert.match(panelTag[0], /style="display:none;"/,
  '导入之前整块面板仍然不显示（显示时机没变，只是显示的默认形态变了）');

// 标题行仍挂着点击切换；摘要元素仍在标题里（折叠时显示的就是它）。
assert.ok(html.includes('class="settings-header" onclick="toggleSettings()"'));
assert.ok(html.indexOf('id="settingsSummary"') > panelTag.index, '摘要在面板标题里');

// ── ② 只有点击能改：全文只有 toggleSettings 一处写这个 class ──────────
const writes = source.match(/classList\.(?:add|remove|toggle)\(\s*'collapsed'/g) || [];
assert.deepEqual(writes, ["classList.toggle('collapsed'"],
  `collapsed 只许由 toggleSettings 的 toggle 写一次，实际：${writes.join(', ')}`);
assert.doesNotMatch(source, /settingsPanel'\)\.classList\.remove\('collapsed'\)/,
  '不许有任何代码路径自动展开设置面板');
assert.equal((html.match(/id="settingsPanel"/g) || []).length, 1, '面板只有一个');

// 另外三个 .settings-panel 是设置页里的静态卡片（历史记录与原图 / 性能 / 更新），
// 它们没有折叠这回事，别被顺手加上 collapsed。
const otherPanels = (html.match(/<div class="settings-panel"/g) || []).length;
assert.equal(otherPanels, 3, '设置页那三张卡片保持原样（不带 collapsed）');

// ── ③ 折叠时那一行真有摘要 ───────────────────────────────────────────
assert.ok(css.includes('.settings-panel.collapsed .settings-body { display: none; }'),
  '折叠就该把 body 收起来');
assert.ok(/\.settings-panel\.collapsed \.settings-summary \{[^}]*display:\s*inline/.test(css),
  '折叠时摘要那一行必须显示出来，否则面板收起来就什么都不说了');

// 真实跑一遍 updateSettingsSummary：默认参数下摘要不能是空的。
const elements = {
  autoCompress: { checked: false },
  qualitySlider: { value: '75' },
  outputFormat: { value: 'original' },
  smartMode: { checked: true },
  settingsSummary: { textContent: '' },
};
const context = vm.createContext({
  console, Set, Map, Promise, JSON, String, Array, Object, Number,
  processingMode: 'advanced',
  document: {
    getElementById: id => elements[id] || null,
    querySelector: () => ({ value: 'replace' }),
  },
  getOutputSuffix: () => '_compressed',
});
vm.runInContext(slice('function updateSettingsSummary(', 'function resetSettings('), context);
context.updateSettingsSummary();
assert.equal(elements.settingsSummary.textContent, 'Q75 · 原格式 · 智能 · 覆盖',
  '折叠起来的那一行要报出当前参数，用户不用展开就知道现在是什么设置');

// 启动时确实跑过它：不跑的话上面那行是空的。
const initBlock = source.slice(source.indexOf('// Init'), source.indexOf('})();', source.indexOf('// Init')));
assert.ok(initBlock.includes('updateSettingsSummary()'),
  '启动流程里必须调 updateSettingsSummary()，否则默认折叠的那一行是空白');

// ── 点击仍然能展开 / 收起（默认折叠不等于点不开）──────────────────────
const panel = { classList: { _has: true, toggle(name) { if (name === 'collapsed') this._has = !this._has; }, contains: () => true } };
const toggleContext = vm.createContext({
  console, document: { getElementById: id => (id === 'settingsPanel' ? panel : null) },
});
vm.runInContext(slice('function toggleSettings()', '// State'), toggleContext);
toggleContext.toggleSettings();
assert.equal(panel.classList._has, false, '点一下标题要展开');
toggleContext.toggleSettings();
assert.equal(panel.classList._has, true, '再点一下收回折叠');

console.log('PASS: 压缩设置默认折叠、只有点击能改、摘要那一行有内容、点得开也收得回');
