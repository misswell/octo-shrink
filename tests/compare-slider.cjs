// 对比窗口的分割线：只有"拖动图片"这一个入口，不再有压住图片底边的那根白线。
//
// 那根白线是 <input type=range id="compareRange">，被 compare.css 画成了可见滑条；
// 它和拖拽是同一件事的两种入口，视觉上却像一条莫名其妙的装饰线。现在输入框删掉、
// 状态挪进 compareSplitPercent，这组断言守住两件事：白线不许回来、分割数学照常工作。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');

// ── 1. 白线（含它的样式）必须彻底消失，而不是藏起来 ──────────────
const filesWithSlider = ['frontend/compare.html', 'frontend/compare.css', 'frontend/compare_window.js', 'frontend/style.css'];
for (const file of filesWithSlider) {
  const text = read(file);
  assert.doesNotMatch(text, /compare-slider-bar|compareRange|sliderBar/,
    `${file} 里还留着底部滑条的痕迹`);
}
assert.doesNotMatch(read('frontend/compare.html'), /type="range"[^>]*compareRange/,
  'compare.html 不该再有那个悬浮的 range 输入框');

// ── 2. 分割数学仍然工作（状态现在在 compareSplitPercent 里）────────
const source = read('frontend/compare_window.js');
const slice = source.slice(
  source.indexOf('function updateCompareSlider('),
  source.indexOf('function syncZoomControls('));
assert.ok(slice.includes('scheduleCompareSlider'), '切片里应当同时包含两个函数');

const frames = [];
const context = vm.createContext({
  console, Math, parseFloat,
  compareSplitPercent: 50,
  compareSliderFrame: 0,
  pendingCompareSliderValue: null,
  compareOriginalImg: { style: {}, getBoundingClientRect: () => ({ left: 0, width: 1000 }) },
  compareHandle: { style: {} },
  document: { getElementById: () => ({ getBoundingClientRect: () => ({ left: 0, width: 1000 }) }) },
  requestAnimationFrame: fn => { frames.push(fn); return frames.length; },
});
vm.runInContext(slice, context);

context.updateCompareSlider(30);
assert.equal(context.compareSplitPercent, 30, '分割位置要记住，缩放重算时才接得上');
assert.equal(context.compareOriginalImg.style.clipPath, 'inset(0 70% 0 0)', '还原图裁到左 30%');
assert.equal(context.compareHandle.style.left, '300px', '手柄跟着走到 30%');
assert.equal(context.compareHandle.style.display, 'block');

context.updateCompareSlider(150);
assert.equal(context.compareOriginalImg.style.clipPath, 'inset(0 0% 0 0)', '越界值夹到 100');
context.updateCompareSlider('看不懂');
assert.equal(context.compareOriginalImg.style.clipPath, 'inset(0 100% 0 0)', '非法值当 0，不能算出 NaN');

// ── 3. 连续移动合并到一帧（拖动时不至于每像素算一次）─────────────
frames.length = 0;
context.compareSliderFrame = 0;
context.scheduleCompareSlider(10);
context.scheduleCompareSlider(20);
context.scheduleCompareSlider(40);
assert.equal(frames.length, 1, '一帧只排一次重算');
frames.shift()();
assert.equal(context.compareSplitPercent, 40, '重算用的是最后一次的值');
assert.equal(context.compareSliderFrame, 0, '帧跑完要复位，否则后续 move 全被吞掉');

// ── 4. 拖拽入口还在（这条线唯一的入口），平移图片时不抢手势 ────────
assert.match(source, /outer\.addEventListener\('mousemove'/, '拖拽分割线的监听不能被删掉');
assert.match(source, /compareViewer\.drag\) return/, '平移图片时不能同时拖动分割线');

console.log('PASS: 对比窗口底部白线已移除，分割仍由拖拽驱动，状态改由 compareSplitPercent 承载');
