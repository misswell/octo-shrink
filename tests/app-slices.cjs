// 前端是单文件脚本，测试靠"按标记切一段真实代码 + 给上下文补桩"来跑。
// 状态机（compressionState / setCompressionState / 暂停·继续·停止按钮）被四个测试共用，
// 切片标记只写在这里一处 —— 免得某个测试的范围悄悄漂掉，跑的已经不是真实代码。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'frontend', 'app.js'), 'utf8');

function slice(from, to) {
  const start = source.indexOf(from);
  const end = source.indexOf(to);
  if (start < 0 || end < 0 || end <= start) {
    throw new Error(`切片标记找不到（${from} → ${to}）`);
  }
  return source.slice(start, end);
}

/// 「队列状态（唯一真相）」整段：queueItems + 派生进度 + 队列摘要。
/// 任何跟"这个文件还需不需要处理"有关的判断都必须从这里读，所以测试也只切这里。
function queueCore() {
  return slice('// ─── 队列状态（唯一真相，DOM 只能照着它画）', '// ─── 队列渲染（排序 / 视图 / 每一行的画法）');
}

/// 「把队列项画到那一行上」整段：paintQueueRow + 错误图标。
/// 方向只有一个：queueItems → DOM；这一段是唯一允许写行内状态的地方。
function queueRowPainter() {
  return slice('/// 把一个队列项此刻的状态', 'function createQueueRow(');
}

/// 「执行会话（一轮）」整段：executionSession + 会话身份判定。
function sessionModel() {
  return slice('// ─── 执行会话（一轮）', '// ─── 压缩主流程');
}

/// 「压缩状态机 … 暂停 / 继续 / 停止」整段：状态变量 + 写入口 + 三个按钮的动作。
function stateMachine() {
  return slice('// ─── 压缩状态机', '// ─── 历史记录页');
}

function installQueueCore(context) {
  vm.runInContext(queueCore(), context);
}

function installQueueRowPainter(context) {
  vm.runInContext(queueRowPainter(), context);
}

/// 把状态机装进测试上下文。必须在其他切片之前调用：它声明
/// compressionState / isCompressing / compressionPaused 三个变量（初值 idle）。
function installStateMachine(context) {
  vm.runInContext(stateMachine(), context);
}

/// 把执行会话装进上下文。必须在状态机之后（beginExecutionSession 读 compressionState）。
function installSessionModel(context) {
  vm.runInContext(sessionModel(), context);
}

module.exports = {
  source, slice,
  queueCore, installQueueCore,
  queueRowPainter, installQueueRowPainter,
  sessionModel, installSessionModel,
  stateMachine, installStateMachine,
};
