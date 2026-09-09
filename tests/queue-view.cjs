const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('frontend/app.js', 'utf8');
const files = ['/image10.png', '/image2.png', '/image1.png', '/pending.png'];
const states = ['done', 'failed', 'done', 'waiting'];
const rows = Object.fromEntries(files.map((file, i) => [file, {
  file, originalSize: [100, 2000, 300, undefined][i],
  classList: { contains: state => states[i] === state },
}]));
const list = { children: Object.values(rows), insertBefore(row, before) {
  this.children = this.children.filter(item => item !== row);
  const index = before ? this.children.indexOf(before) : this.children.length;
  this.children.splice(index, 0, row);
}};
const controls = {
  fileQueueList: list, queueFailedOnly: {checked:false}, queueSortKey: {value:'import'},
  queueSortDirection: {setAttribute() {}}, queueFilterEmpty: {},
};
const context = vm.createContext({
  files, fileRows: rows, queueSortDescending: false,
  results: [
    {file:files[0],success:true,originalSize:100,compressedSize:90,savings:10},
    {file:files[1],success:false,originalSize:2000},
    {file:files[2],success:true,originalSize:300,compressedSize:30,savings:90},
  ],
  basename: file => file.split('/').pop(),
  document: {getElementById: id => controls[id]},
});
vm.runInContext(source.slice(source.indexOf('function toggleQueueSortDirection('), source.indexOf('async function renderFileQueue(')), context);
const order = () => list.children.filter(row => !row.hidden).map(row => row.file);
const sort = (key, descending = false) => {
  controls.queueSortKey.value = key;
  context.queueSortDescending = descending;
  context.applyQueueView();
};
sort('name'); assert.deepEqual(order(), [files[2],files[1],files[0],files[3]]);
sort('name',true); assert.deepEqual(order(), [files[3],files[0],files[1],files[2]]);
sort('original'); assert.deepEqual(order(), [files[0],files[2],files[1],files[3]]);
sort('original',true); assert.deepEqual(order(), [files[1],files[2],files[0],files[3]]);
sort('compressed'); assert.deepEqual(order(), [files[2],files[0],files[1],files[3]]);
sort('ratio',true); assert.deepEqual(order(), [files[2],files[0],files[1],files[3]]);
sort('status'); assert.deepEqual(order(), [files[1],files[3],files[0],files[2]]);
controls.queueFailedOnly.checked = true;
context.applyQueueView(); assert.deepEqual(order(), [files[1]]);
assert.equal(controls.queueFilterEmpty.hidden, true);
states[1] = 'compressing'; context.applyQueueView();
assert.deepEqual(order(), []); assert.equal(controls.queueFilterEmpty.hidden, false);
states[3] = 'failed'; context.applyQueueView(); assert.deepEqual(order(), [files[3]]);
controls.queueFailedOnly.checked = false;
sort('import'); assert.deepEqual(order(), files);
assert.deepEqual(files, ['/image10.png','/image2.png','/image1.png','/pending.png']);
console.log('PASS: all sort fields, numeric filenames, missing values, live failure filter, queue isolation');
