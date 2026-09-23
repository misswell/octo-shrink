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

/// 「压缩状态机 … 暂停 / 继续 / 停止」整段：状态变量 + 写入口 + 三个按钮的动作。
function stateMachine() {
  return slice('// ─── 压缩状态机', '// ─── 历史记录页');
}

/// 把状态机装进测试上下文。必须在其他切片之前调用：它声明
/// compressionState / isCompressing / compressionPaused 三个变量（初值 idle）。
function installStateMachine(context) {
  vm.runInContext(stateMachine(), context);
}

module.exports = { source, slice, stateMachine, installStateMachine };
