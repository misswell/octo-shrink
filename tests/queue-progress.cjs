const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('frontend/app.js', 'utf8');
const summary = { textContent: '' };
const runs = [];
let progress;
const context = vm.createContext({
  console, Set, Map, Promise,
  files: [], results: [], inputPaths: [], isCompressing: false, pendingAutoCompress: false,
  document: { getElementById: id => id === 'queueSummary' ? summary : null, querySelector: () => null },
  settingsPanel: {style:{}}, resultsPanel: {style:{}},
  statOriginal: {}, statCompressed: {}, totalSavings: {}, totalRate: {},
  ensureSystemOutputAccess: async () => true,
  getCurrentCompressionConfig: () => ({ options: {} }),
  listen: async (_, handler) => { progress = payload => handler({payload}); return () => {}; },
  invoke: async (command, args) => {
    if (command === 'expand_image_files') return args.filePaths;
    return new Promise(resolve => runs.push({ paths: args.filePaths, resolve }));
  },
  formatBytes: String, showToast() {}, iconMarkup() {}, renderQueueResultActions() {}, updateStats() {}, showResults() {},
});
vm.runInContext(source.slice(source.indexOf('function uniqueFilePaths('), source.indexOf('async function renderFileQueue(')), context);
vm.runInContext(source.slice(source.indexOf('async function startCompression('), source.indexOf('function updateStats(')), context);
context.renderFileQueue = () => context.files.forEach(file => {
  if (context.fileRows[file]) return;
  const classes = new Set(['waiting']);
  context.fileRows[file] = {
    classList: { contains: c => classes.has(c), add: c => classes.add(c), remove: c => classes.delete(c) },
    querySelector: () => ({style:{}}),
  };
});
const flush = async () => { for (let i=0;i<12;i++) await Promise.resolve(); };
const settle = file => progress({ file, result: {file, success:true, savings:10} });
(async () => {
  const first = Array.from({length:10}, (_,i) => `/first-${i}.png`);
  const next = Array.from({length:10}, (_,i) => `/next-${i}.png`);
  await context.handleFilePaths(first);
  const run = context.startCompression(false);
  await flush();
  first.slice(0,3).forEach(settle);
  assert.equal(summary.textContent, '3 / 10 已完成');
  await context.handleFilePaths(next);
  assert.equal(summary.textContent, '3 / 20 已完成', 'import must immediately update the queue total');
  await context.handleFilePaths(next);
  assert.equal(summary.textContent, '3 / 20 已完成', 'duplicate imports do not inflate total');
  assert.deepEqual(Array.from(runs[0].paths), first, 'active batch stays isolated');
  first.slice(3).forEach(settle);
  runs[0].resolve([]);
  await run;
  assert.equal(summary.textContent, '10 / 20 已完成', 'idle must preserve completed count');
  const second = context.startCompression(true);
  await flush();
  assert.equal(summary.textContent, '10 / 20 已完成', 'next batch must preserve count');
  next.forEach(settle);
  settle(next[0]);
  runs[1].resolve([]);
  await second;
  assert.equal(summary.textContent, '20 / 20 已完成', 'completion persists and duplicate events do not count twice');
  const extra = ['/extra.png'];
  await context.handleFilePaths(extra);
  const third = context.startCompression(false);
  await flush();
  await context.handleFilePaths(['/auto.png']);
  context.pendingAutoCompress = true;
  settle(extra[0]);
  runs[2].resolve([]);
  await third;
  await flush();
  assert.equal(summary.textContent, '21 / 22 已完成', 'automatic continuation preserves count');
  settle('/auto.png');
  runs[3].resolve([]);
  await flush();
  assert.equal(summary.textContent, '22 / 22 已完成');
  context.files = [];
  context.results = [];
  context.updateQueueSummary();
  assert.equal(summary.textContent, '0 个文件');
  console.log('PASS: append 10 during compression, cumulative completion, persistent final summary');
})().catch(error => { console.error(error); process.exitCode = 1; });
