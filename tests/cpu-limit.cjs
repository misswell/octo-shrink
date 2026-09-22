// CPU 使用上限：设备信息、滑杆语义、队列摘要文案，全部对齐方案 §40/§62/§63/§64。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('frontend/app.js', 'utf8');

function field(extra) {
  return Object.assign({
    style: {}, title: '', innerHTML: '', textContent: '', value: '',
    disabled: false, min: '', max: '', handlers: {},
    classList: { _set: new Set(),
      toggle(name, force) {
        const on = force === undefined ? !this._set.has(name) : !!force;
        on ? this._set.add(name) : this._set.delete(name);
      },
      add(name) { this._set.add(name); }, remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); } },
    addEventListener(type, fn) { this.handlers[type] = fn; },
  }, extra);
}

const elements = {
  queueSummary: field(), compressBtnText: field(),
  pauseCompressBtn: field(), pauseBtnText: field(), restoreAllBtn: field(),
  cpuDevice: field(), cpuCoreInfo: field(), cpuSchedulingNote: field(),
  cpuLimitSlider: field({ value: '3' }), cpuLimitValue: field(), cpuLimitAuto: field(),
};
const calls = [];
let status = null;
let settings = { originalRetentionDays: 3 };
const context = vm.createContext({
  console: { log: console.log, warn: console.warn, error: message => calls.push(['error', message]) },
  Set, Map, Promise, JSON, Math, String, Number, parseInt, Object, Array,
  files: Array.from({ length: 20 }, (_, i) => `/img-${i}.png`),
  results: [], isCompressing: true, processingMode: 'advanced',
  document: { getElementById: id => elements[id] || null },
  applyQueueView() {}, showToast(message) { calls.push(['toast', message]); },
  loadRetentionSetting: async () => {},
  invoke: async (command, args) => {
    calls.push([command, args]);
    if (command === 'get_cpu_info') return status;
    if (command === 'get_app_settings') return settings;
    if (command === 'set_cpu_thread_limit') {
      // 后端才是 clamp 的唯一负责者：这里模拟"12 核机器上设 12，换到 8 核机"。
      const ceiling = status.availableParallelism;
      const configured = args.limit === null || args.limit === undefined ? null : args.limit;
      const auto = Math.max(1, Math.min(3, ceiling));
      const effective = Math.min(Math.max(1, configured === null ? auto : configured), ceiling);
      status = Object.assign({}, status, {
        configuredLimit: configured, effectiveLimit: effective,
      });
      return status;
    }
    return null;
  },
});
const slice = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));
vm.runInContext(slice('function updateQueueSummary(', 'function toggleQueueSortDirection('), context);
vm.runInContext(slice('function processingActionText(', 'function setProcessingMode('), context);
vm.runInContext(slice('var compressionPaused = false;', '// ─── 历史记录页'), context);
vm.runInContext(slice('// ─── 设置页：CPU 使用上限', '// ─── Comparison（独立原生窗口）'), context);

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
const last = name => [...calls].reverse().find(call => call[0] === name);
// vm 里造的对象和测试这边不是同一个 realm，只能比原始值。
const lastLimit = () => (last('set_cpu_thread_limit') || [null, {}])[1].limit;
const m1 = {
  architecture: 'aarch64', modelName: 'Apple M5', appleSilicon: true,
  physicalCpus: 10, logicalCpus: 10, performanceCpus: 4, efficiencyCpus: 6,
  availableParallelism: 10, configuredLimit: null, effectiveLimit: 3,
};
const intel = {
  architecture: 'x86_64', modelName: 'Intel Core i7', appleSilicon: false,
  physicalCpus: 6, logicalCpus: 12, performanceCpus: null, efficiencyCpus: null,
  availableParallelism: 12, configuredLimit: 4, effectiveLimit: 4,
};
const winArm = {
  architecture: 'aarch64', modelName: 'Snapdragon X Elite', appleSilicon: false,
  physicalCpus: null, logicalCpus: 8, performanceCpus: null, efficiencyCpus: null,
  availableParallelism: 8, configuredLimit: null, effectiveLimit: 3,
};

(async () => {
  // ── Apple Silicon：设备信息 + P/E 核 + 自动文案 ──
  status = m1;
  await context.loadCpuSetting();
  assert.equal(elements.cpuDevice.textContent, 'Apple M5 · ARM64');
  assert.equal(elements.cpuCoreInfo.textContent, '10 核 CPU（4 性能核 + 6 能效核）');
  assert.equal(elements.cpuLimitSlider.max, '10', '滑杆上限必须是本机可用并行数');
  assert.equal(elements.cpuLimitValue.textContent, '自动（3）');
  assert.ok(elements.cpuLimitAuto.classList.contains('active'), '自动态要高亮自动按钮');
  assert.equal(elements.cpuSchedulingNote.style.display, '', 'Apple Silicon 才显示 P/E 调度说明');

  // 队列摘要：自动时只说"CPU 自动"，不假装知道具体数字。
  context.updateQueueSummary();
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成 · CPU 自动');
  context.compressionPaused = true;
  context.updateQueueSummary();
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成 · 已暂停 · CPU 自动');
  context.compressionPaused = false;

  // ── 显式选 4：摘要变成 4/10，点自动回到 null ──
  await context.saveCpuThreadLimit(4);
  assert.equal(last('set_cpu_thread_limit')[0], 'set_cpu_thread_limit');
  assert.equal(last('set_cpu_thread_limit')[1].limit, 4);
  assert.equal(elements.cpuLimitValue.textContent, '4 / 10');
  context.updateQueueSummary();
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成 · CPU 4/10');
  await context.saveCpuThreadLimit(null);
  assert.equal(elements.cpuLimitValue.textContent, '自动（3）');
  assert.ok(last('set_cpu_thread_limit') && lastLimit() === null, '自动必须传 null，不是 0');

  // ── 滑杆：拖动只预览，松手才落盘 ──
  status = m1;
  elements.cpuLimitSlider.value = '6';
  elements.cpuLimitSlider.handlers.input();
  assert.equal(elements.cpuLimitValue.textContent, '6 / 10');
  assert.equal(context.cpuStatus.configuredLimit, 6, '预览就要改掉本地状态');
  assert.ok(lastLimit() === null, '拖动过程中不能反复写盘');
  elements.cpuLimitSlider.handlers.change();
  await flush();
  assert.equal(last('set_cpu_thread_limit')[0], 'set_cpu_thread_limit');
  assert.equal(lastLimit(), 6);

  // ── Intel：没有大小核，绝不显示 P/E，也绝不显示 Apple 说明 ──
  status = intel;
  await context.loadCpuSetting();
  assert.equal(elements.cpuDevice.textContent, 'Intel Core i7 · x86_64');
  assert.equal(elements.cpuCoreInfo.textContent, '6 个物理核心 · 12 个逻辑处理器');
  assert.match(elements.cpuLimitValue.textContent, /^4 \/ 12$/);
  assert.equal(elements.cpuSchedulingNote.style.display, 'none', 'Intel 无 P/E 核可调度');
  context.updateQueueSummary();
  assert.equal(elements.queueSummary.textContent, '0 / 20 已完成 · CPU 4/12');

  // ── Windows ARM64：同为 aarch64，不能被认成 Apple Silicon ──
  status = winArm;
  await context.loadCpuSetting();
  assert.equal(elements.cpuDevice.textContent, 'Snapdragon X Elite · ARM64');
  assert.doesNotMatch(elements.cpuCoreInfo.textContent, /性能核/, '非 Apple 不得声称大小核');
  assert.equal(elements.cpuSchedulingNote.style.display, 'none');

  // ── 非 macOS：sysctl 全部拿不到，Rust 那边回落到 modelName/physicalCpus = null ──
  // 这正是 Windows / Linux 用户真会收到的那份数据，不能显示成残缺文案。
  status = Object.assign({}, winArm, {
    architecture: 'x86_64', modelName: null, appleSilicon: false,
    physicalCpus: null, logicalCpus: 12, availableParallelism: 12, effectiveLimit: 3,
  });
  await context.loadCpuSetting();
  assert.equal(elements.cpuDevice.textContent, 'x86_64', '拿不到型号时只报架构，不留悬点分隔符');
  assert.equal(elements.cpuCoreInfo.textContent, '12 个逻辑处理器', '物理核数未知就只报逻辑处理器，不猜');
  assert.doesNotMatch(elements.cpuCoreInfo.textContent, /物理核心|性能核/, '没有 physicalcpu 就别猜物理核数');
  assert.equal(elements.cpuSchedulingNote.style.display, 'none');
  assert.equal(elements.cpuLimitValue.textContent, '自动（3）');

  // ── 换到核更少的机器：后端 clamp 后前端照抄，不报错也不越界 ──
  status = Object.assign({}, m1, { availableParallelism: 8, configuredLimit: 10, effectiveLimit: 8 });
  await context.loadCpuSetting();
  assert.equal(elements.cpuLimitSlider.max, '8');
  assert.equal(elements.cpuLimitSlider.value, '8', '滑杆不能停在超出本机的位置');
  assert.equal(elements.cpuLimitValue.textContent, '8 / 8（全部）');
  assert.ok(elements.cpuLimitAuto.classList.contains('active') === false);

  // ── 设置失败要回滚到后端真值，不能把假数字留在界面上 ──
  status = m1;
  await context.loadCpuSetting();
  const broken = context.invoke;
  context.invoke = async (command, args) => {
    if (command === 'set_cpu_thread_limit') throw new Error('ipc down');
    return broken(command, args);
  };
  await context.saveCpuThreadLimit(9);
  assert.match(last('toast')[1], /设置失败/);
  assert.equal(elements.cpuLimitValue.textContent, '自动（3）', '失败后必须重新读回真值');

  // ── 文案红线：方案禁止写成"绑定几个性能核" ──
  const html = fs.readFileSync('frontend/index.html', 'utf8');
  assert.match(html, /限制 OctoShrink 同时使用的 CPU 并行能力/);
  assert.match(html, /较低的数值会降低压缩速度，但可为其他应用保留更多性能/);
  assert.match(html, /系统会自动在性能核与能效核之间调度任务/);
  assert.doesNotMatch(html, /使用 \d+ 个性能核/, '不能承诺绑定具体核心');
  assert.doesNotMatch(source, /hw\.perflevel\d?\.logicalcpu\b/, '调度按并行预算，不做绑核');
  console.log('PASS: CPU device info, slider semantics, summary copy, clamp and rollback');
})().catch(error => { console.error(error); process.exitCode = 1; });
