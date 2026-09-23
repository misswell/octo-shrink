const assert = require('node:assert/strict');
const fs = require('node:fs');

// 图标是每页内联一份 sprite：漏定义 = 页面上那个 <svg> 直接画不出来，且不会报错。
// 这里把「引用 ↔ 定义」「两页共享 glyph 不漂移」「描边渲染模式」三件事钉住。
const PAGES = {
  'frontend/index.html': ['frontend/app.js'],
  'frontend/compare.html': ['frontend/compare_window.js'],
};

const spriteOf = html => html.match(/<svg class="icon-library"[\s\S]*?<\/svg>/)[0];
const symbolsOf = block => new Map([...block.matchAll(/<symbol id="icon-([a-z0-9-]+)"[\s\S]*?<\/symbol>/g)]
  .map(m => [m[1], m[0]]));

const blocks = Object.fromEntries(Object.keys(PAGES)
  .map(page => [page, spriteOf(fs.readFileSync(page, 'utf8'))]));
// glyph 名表由两页 sprite 自己给出，不需要再抄一份清单。
const ALL_GLYPHS = new Set(Object.values(blocks).flatMap(b => [...symbolsOf(b).keys()]));

function usedIn(files) {
  const names = new Set();
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    for (const m of text.matchAll(/#icon-([a-z0-9-]+)/g)) names.add(m[1]);
    // iconMarkup(name) 的实参可以是三元表达式，一次调用能带出多个 glyph。
    for (const call of text.matchAll(/iconMarkup\(([^;]*)\)/g)) {
      for (const m of call[1].matchAll(/'([a-z0-9-]+)'/g)) {
        if (ALL_GLYPHS.has(m[1])) names.add(m[1]);
      }
    }
  }
  return names;
}

const perPage = new Map();
for (const [page, scripts] of Object.entries(PAGES)) {
  const symbols = symbolsOf(blocks[page]);
  const used = usedIn([page, ...scripts]);
  assert.deepEqual([...used].filter(name => !symbols.has(name)), [],
    `${page}: 引用了未定义的 glyph`);
  assert.deepEqual([...symbols.keys()].filter(name => !used.has(name)), [],
    `${page}: sprite 里有没人引用的 glyph`);
  perPage.set(page, symbols);
}

// 两页都用到的 glyph 必须逐字节一致，否则一次改动只会修好一个窗口。
const shared = [...perPage.get('frontend/index.html').keys()]
  .filter(name => perPage.get('frontend/compare.html').has(name));
// 对比窗口的 close / restore / compare / recompress 与主窗口是同一批按钮语义。
assert.ok(shared.length >= 4, `两页共享 glyph 过少（${shared.join(', ')}）`);
for (const name of shared) {
  assert.equal(perPage.get('frontend/index.html').get(name),
    perPage.get('frontend/compare.html').get(name), `icon-${name} 在两页的几何不一致`);
}

const css = fs.readFileSync('frontend/style.css', 'utf8');
const rule = css.match(/\.symbol-icon\s*\{[^}]*\}/)[0];
assert.match(rule, /fill:\s*none/, 'glyph 是描边系统：.symbol-icon 必须 fill:none');
assert.match(rule, /stroke:\s*currentColor/, 'glyph 必须 stroke:currentColor，否则跟随语义色失效');
assert.match(rule, /stroke-width/, '.symbol-icon 缺少 stroke-width');
assert.doesNotMatch(css, /fill='%23888'/, '<select> 箭头仍是旧的实心灰块');

// 加载指示器：55b2a4c 曾把它改成圆角方块 + ease-in-out，画出来是个 ∩ 形断口块
const spinner = css.match(/\.progress-file-spinner\s*\{[^}]*\}/)[0];
assert.match(spinner, /border-radius:\s*50%/, 'spinner 必须是圆环：非 50% 会画成圆角方形的断口块');
assert.match(spinner, /animation:\s*spin[^;]*\blinear\b/, 'spinner 必须 linear 匀速：ease-in-out 每圈加减速，看着像卡顿');
assert.match(spinner, /border[^;]*color-mix/, 'spinner 需要有半透明轨道，四边同色只剩一个硬缺口');

console.log(`PASS: ${shared.length} 个共享 glyph 两页一致，sprite 无缺失/无死 glyph，描边渲染模式在位，spinner 为匀速圆环`);
