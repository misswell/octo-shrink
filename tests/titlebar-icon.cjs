// 顶栏小图标必须就是应用图标同一张图 —— 不许各维护一份。
//
// v2.5.42 把应用图标换成了亮色设计，但顶栏还在用 v2.5.31 那版旧图标：因为
// frontend/octo-icon-*.png 是另存的一份拷贝，换图标时没人想起它。这组断言把它钉死：
// 顶栏那两个文件（light/dark 按主题换）必须与 assets/icon-light.png 逐字节相同。
//
// 如果哪天真要给顶栏做一张单独的画（比如 16px 简化版），改这里并把原因写清楚。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (...p) => fs.readFileSync(path.join(root, ...p));
const APP_ICON = path.join('assets', 'icon-light.png');
const TITLEBAR_ICONS = ['frontend/octo-icon-light.png', 'frontend/octo-icon-dark.png'];

const appIcon = read(APP_ICON);
assert.ok(appIcon.length > 0, `${APP_ICON} 是空的`);

for (const icon of TITLEBAR_ICONS) {
  assert.ok(fs.existsSync(path.join(root, icon)), `${icon} 不存在`);
  assert.ok(
    read(icon).equals(appIcon),
    `${icon} 与应用图标（${APP_ICON}）不是同一张图 —— 顶栏图标又忘了跟着换（cp ${APP_ICON} ${icon}）`
  );
}

// 两个文件名必须真的被用上，否则换了图也没人显示。
const html = read('frontend', 'index.html').toString('utf8');
assert.match(html, /data-light-src="octo-icon-light\.png"/, 'index.html 没引用 light 版顶栏图标');
assert.match(html, /data-dark-src="octo-icon-dark\.png"/, 'index.html 没引用 dark 版顶栏图标');
const app = read('frontend', 'app.js').toString('utf8');
assert.match(app, /resolvedTheme === 'dark' \? icon\.dataset\.darkSrc : icon\.dataset\.lightSrc/,
  '按主题换顶栏图标的逻辑不见了：两个文件会有一个永远不显示');
assert.match(app, /className\.includes\('titlebar-icon-img'\)|titlebar-icon-img/,
  '换图标的逻辑找不到 .titlebar-icon-img');

console.log(`PASS: 顶栏图标与应用图标同源（${TITLEBAR_ICONS.length} 个变体逐字节一致），主题换图链路完整`);
