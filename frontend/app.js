// OctoShrink - Tauri frontend
// Uses window.__TAURI__ global API (withGlobalTauri: true)

const { invoke, convertFileSrc } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

function iconMarkup(name, small) {
  return '<svg class="symbol-icon' + (small ? ' symbol-icon-small' : '') + '" aria-hidden="true"><use href="#icon-' + name + '"></use></svg>';
}

// ─── Path utilities (replace Node's path module) ────────────────
function basename(p) {
  const parts = String(p).replace(/\\/g, '/').split('/');
  return parts[parts.length - 1] || p;
}
function extname(p) {
  const base = basename(p);
  const idx = base.lastIndexOf('.');
  return idx >= 0 ? base.substring(idx) : '';
}
function dirname(p) {
  const parts = String(p).replace(/\\/g, '/').split('/');
  parts.pop();
  return parts.join('/') || '.';
}

function imageFileSrc(filePath) {
  if (typeof convertFileSrc !== 'function') return null;
  return convertFileSrc(filePath);
}

function setImageSource(img, src, timeoutMs) {
  return new Promise((resolve, reject) => {
    var timer = null;
    var done = function(ok) {
      if (timer) clearTimeout(timer);
      img.onload = null;
      img.onerror = null;
      ok ? resolve(true) : reject(new Error('image load failed'));
    };
    img.onload = () => done(true);
    img.onerror = () => done(false);
    if (timeoutMs) {
      timer = setTimeout(function() { done(false); }, timeoutMs);
    }
    img.src = src;
  });
}

async function loadOriginalImage(img, filePath) {
  img.removeAttribute('src');
  const directSrc = imageFileSrc(filePath);
  if (directSrc) {
    try {
      await setImageSource(img, directSrc, 1500);
      return true;
    } catch (_) {
      img.removeAttribute('src');
    }
  }

  const dataUrl = await invoke('read_image_dataurl', { filePath: filePath, preview: false });
  if (!dataUrl) return false;
  await setImageSource(img, dataUrl, 5000);
  return true;
}

// ─── 主题管理（自动/亮色/暗黑）──────────────────────────────────
// 三种模式：auto（跟随系统）、light、dark，循环切换
const THEMES = ['auto', 'light', 'dark'];
let currentTheme = localStorage.getItem('octoshrink-theme') || 'auto';
if (!THEMES.includes(currentTheme)) currentTheme = 'auto';

function getResolvedTheme(theme) {
  if (theme === 'auto') {
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  return theme;
}

function updateTitlebarIcon(resolvedTheme) {
  const icon = document.querySelector('.titlebar-icon-img');
  if (!icon) return;
  const src = resolvedTheme === 'dark' ? icon.dataset.darkSrc : icon.dataset.lightSrc;
  if (src && icon.getAttribute('src') !== src) icon.setAttribute('src', src);
}

function applyTheme(theme) {
  currentTheme = theme;
  localStorage.setItem('octoshrink-theme', theme);

  const resolvedTheme = getResolvedTheme(theme);
  invoke('set_startup_theme', { theme: resolvedTheme }).catch(() => {});
  document.documentElement.setAttribute('data-theme-mode', theme);
  if (resolvedTheme === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
  } else {
    document.documentElement.setAttribute('data-theme', 'light');
  }
  updateTitlebarIcon(resolvedTheme);

  // 更新图标显示
  const icons = document.querySelectorAll('.theme-icon');
  icons.forEach(ic => ic.style.display = 'none');
  const activeIcon = document.querySelector('.theme-icon-' + theme);
  if (activeIcon) activeIcon.style.display = '';

  // 更新按钮提示
  const btn = document.getElementById('themeToggleBtn');
  if (btn) {
    const labels = { auto: '自动（跟随系统）', light: '亮色模式', dark: '暗黑模式' };
    btn.title = '当前: ' + labels[theme] + ' · 点击切换';
  }
}

function cycleTheme() {
  const idx = THEMES.indexOf(currentTheme);
  const next = THEMES[(idx + 1) % THEMES.length];
  applyTheme(next);
  const labels = { auto: '自动', light: '亮色', dark: '暗黑' };
  showToast('主题: ' + labels[next]);
}

// 监听系统主题变化（auto 模式下实时响应）
if (window.matchMedia) {
  const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
  const handler = () => {
    if (currentTheme === 'auto') {
      applyTheme('auto');
    }
  };
  if (mediaQuery.addEventListener) {
    mediaQuery.addEventListener('change', handler);
  } else if (mediaQuery.addListener) {
    mediaQuery.addListener(handler);
  }
}

// 初始化主题
applyTheme(currentTheme);
var BUILD_VARIANT = (window.location.origin.indexOf('http://localhost') === 0) ? 'App Store' : 'Direct';
(function() {
  var tb = document.querySelector('.titlebar-text');
  if (tb) tb.textContent = 'OctoShrink (' + BUILD_VARIANT + ')';
  try { document.title = 'OctoShrink (' + BUILD_VARIANT + ')'; } catch(e) {}
})();

// ─── 设置面板折叠 ─────────────────────────────────────────────────
function toggleSettings() {
  const panel = document.getElementById('settingsPanel');
  if (!panel) return;
  panel.classList.toggle('collapsed');
}

// State
//
// 队列 = 唯一真相。`queueItems` 记住每个文件**此刻**处于哪一步，
// `files` 只是它在界面上的顺序（同一批路径，按导入先后排列）。
//
// 老实现里"这个文件还需不需要处理"要靠 DOM class（row.classList.contains('cancelled')）、
// 一个 results[] 数组和一个批次计数器互相推测 —— 停止、继续、重新导入三次之后
// 三份数据就对不上了（这正是"停止后剩下的图再也压不动"的来源）。现在只认 queueItems。
//
// 持久状态只有六种（暂停 / 停止是**会话**的状态，不写进这里）：
//   pending   还需要压缩（首次没开始、暂停中等待、停止后留待下一轮、新导入 —— 都是它）
//   running   真的在压
//   done      压完了（成功）
//   failed    压完了（失败），只有显式「重试」才会回到 pending
//   removed   用户把它移出了队列
//   restored  用户把这次压缩撤销了（原图回来了），要压得重新点
let files = [];
let inputPaths = [];
var queueItems = new Map();
// isCompressing / compressionPaused 都在「压缩状态机」那一节声明：
// 它们是 compressionState 的派生镜像，唯一的写入口是 setCompressionState。
let pendingAutoCompress = false;
let outputDir = null;
let currentCompressOptions = null;
let processingMode = 'advanced';

// DOM Elements
const dropzone = document.getElementById('dropzone');
const settingsPanel = document.getElementById('settingsPanel');
const resultsPanel = document.getElementById('resultsPanel');
const resultsList = document.getElementById('resultsList');
const qualitySlider = document.getElementById('qualitySlider');
const qualityValue = document.getElementById('qualityValue');
const statOriginal = document.getElementById('statOriginal');
const statCompressed = document.getElementById('statCompressed');
const totalSavings = document.getElementById('totalSavings');
const totalRate = document.getElementById('totalRate');
const resultCount = document.getElementById('resultCount');
const resultTotalSavings = document.getElementById('resultTotalSavings');
const outputDirDisplay = document.getElementById('outputDirDisplay');
const outputDirRow = document.getElementById('outputDirRow');
const outputSuffixRow = document.getElementById('outputSuffixRow');
const outputSuffixInput = document.getElementById('outputSuffix');

// Quality slider
qualitySlider.addEventListener('input', () => {
  updateQualitySlider();
});

function updateQualitySlider() {
  if (!qualitySlider) return;
  qualityValue.textContent = qualitySlider.value + '%';
  const pct = qualitySlider.value;
  qualitySlider.style.background = 'linear-gradient(90deg, var(--primary) ' + pct + '%, var(--slider-track) ' + pct + '%)';
}

function processingActionText(stage) {
  var systemMode = processingMode === 'system';
  if (stage === 'progress') return systemMode ? '转换中…' : '压缩中…';
  if (stage === 'done') return systemMode ? '转换完成' : '压缩完成';
  // 「继续」= 队列里还有没处理的（停止之后又重新开始一轮）。
  if (stage === 'continue') return systemMode ? '继续转换' : '继续压缩';
  return systemMode ? '开始转换' : '开始压缩';
}

function setProcessingMode(mode, skipSave) {
  var isMac = /Macintosh|Mac OS X/.test(navigator.userAgent);
  processingMode = (mode === 'system' && isMac) ? 'system' : 'advanced';

  document.querySelectorAll('.processing-mode-label').forEach(function(label) {
    label.classList.toggle('active', label.dataset.mode === processingMode);
  });
  var modeToggle = document.getElementById('processingModeToggle');
  if (modeToggle) {
    var advancedActive = processingMode === 'advanced';
    modeToggle.classList.toggle('active', advancedActive);
    modeToggle.setAttribute('aria-checked', advancedActive ? 'true' : 'false');
    modeToggle.setAttribute('aria-label', '切换处理方式，当前为' + (advancedActive ? '高级压缩' : '系统转换'));
  }
  document.querySelectorAll('[data-processing-mode]').forEach(function(row) {
    row.style.display = row.dataset.processingMode === processingMode ? 'flex' : 'none';
  });

  var autoLabel = document.getElementById('autoCompressLabel');
  if (autoLabel) autoLabel.textContent = processingMode === 'system'
    ? '拖入或选择后自动转换'
    : '拖入或选择后自动压缩';
  if (!isCompressing) {
    var btnText = document.getElementById('compressBtnText');
    if (btnText) btnText.innerHTML = '<svg class="symbol-icon"><use href="#icon-compress"/></svg> ' + processingActionText('idle');
  }
  if (!skipSave) saveCompressSettings();
  updateSettingsSummary();
}

function toggleProcessingMode() {
  setProcessingMode(processingMode === 'system' ? 'advanced' : 'system');
}

// Output mode radio
function updateOutputModeControls() {
  var selected = document.querySelector('input[name="outputMode"]:checked');
  var mode = selected ? selected.value : 'replace';
  if (outputDirRow) outputDirRow.style.display = mode === 'folder' ? 'flex' : 'none';
  if (outputSuffixRow) outputSuffixRow.style.display = mode === 'suffix' ? 'flex' : 'none';
}
document.querySelectorAll('input[name="outputMode"]').forEach(radio => {
  radio.addEventListener('change', () => {
    updateOutputModeControls();
    saveCompressSettings();
    updateSettingsSummary();
  });
});

function getOutputSuffix() {
  var suffix = outputSuffixInput ? outputSuffixInput.value.trim() : '';
  return suffix || '_compressed';
}

function getResultOutputSuffix(result) {
  return result && result.compressOptions && result.compressOptions.outputSuffix
    ? result.compressOptions.outputSuffix
    : getOutputSuffix();
}

function openSystemConversionInfo() {
  var backdrop = document.getElementById('systemInfoBackdrop');
  var panel = document.getElementById('systemInfoPanel');
  if (!backdrop || !panel) return;
  backdrop.style.display = 'block';
  panel.style.display = 'block';
  document.body.style.overflow = 'hidden';
}

function closeSystemConversionInfo() {
  var backdrop = document.getElementById('systemInfoBackdrop');
  var panel = document.getElementById('systemInfoPanel');
  if (backdrop) backdrop.style.display = 'none';
  if (panel) panel.style.display = 'none';
  document.body.style.overflow = '';
}

// ─── Drag and drop via Tauri ────────────────────────────────────
async function setupDragDrop() {
  try {
    const { getCurrentWebview } = window.__TAURI__.webview;
    const webview = getCurrentWebview();
    await webview.onDragDropEvent((event) => {
      const payload = event.payload;
      if (payload.type === 'drop') {
        dropzone.classList.remove('dragover');
        if (payload.paths && payload.paths.length > 0) {
          handleFilePaths(payload.paths);
        }
      } else if (payload.type === 'enter' || payload.type === 'over') {
        dropzone.classList.add('dragover');
      } else if (payload.type === 'leave') {
        dropzone.classList.remove('dragover');
      }
    });
  } catch (e) {
    console.error('Tauri drag-drop setup failed, falling back to HTML5:', e);
    // Fallback: HTML5 drag-drop (paths won't be available in Tauri)
    dropzone.addEventListener('dragover', (e) => { e.preventDefault(); dropzone.classList.add('dragover'); });
    dropzone.addEventListener('dragleave', () => { dropzone.classList.remove('dragover'); });
    dropzone.addEventListener('drop', (e) => {
      e.preventDefault();
      dropzone.classList.remove('dragover');
      const droppedFiles = Array.from(e.dataTransfer.files);
      handleFiles(droppedFiles);
    });
  }
}
setupDragDrop();

// File selection
async function selectFiles() {
  try {
    const filePaths = await invoke('select_files');
    if (filePaths && filePaths.length > 0) {
      handleFilePaths(filePaths);
    }
  } catch (error) {
    console.error('File selection failed:', error);
    showToast('选择图片失败，请重试');
  }
}

async function selectFolder() {
  try {
    const folderPaths = await invoke('select_folder');
    if (folderPaths && folderPaths.length > 0) {
      handleFilePaths(folderPaths);
    }
  } catch (error) {
    console.error('Folder selection failed:', error);
    showToast('选择文件夹失败，请重试');
  }
}

async function selectOutputDir() {
  const dirs = await invoke('select_output_dir');
  if (dirs && dirs.length > 0) {
    outputDir = dirs[0];
    outputDirDisplay.textContent = outputDir;
    outputDirDisplay.title = outputDir;
    return true;
  }
  return false;
}

async function ensureSystemOutputAccess() {
  if (processingMode !== 'system' || BUILD_VARIANT !== 'App Store') return true;
  var selectedMode = document.querySelector('input[name="outputMode"]:checked');
  if (selectedMode && selectedMode.value === 'folder' && outputDir) return true;

  showToast('请选择系统转换文件的输出文件夹');
  if (!await selectOutputDir()) return false;
  var folderMode = document.querySelector('input[name="outputMode"][value="folder"]');
  if (folderMode) folderMode.checked = true;
  if (outputDirRow) outputDirRow.style.display = 'flex';
  saveCompressSettings();
  updateSettingsSummary();
  return true;
}

function handleFiles(fileList) {
  const filePaths = [];
  for (const file of fileList) {
    if (file.path) filePaths.push(file.path);
  }
  if (filePaths.length === 0 && fileList.length > 0) {
    showToast('无法读取拖入文件，请使用“选择文件”');
    return Promise.resolve([]);
  }
  return handleFilePaths(filePaths);
}

function uniqueFilePaths(paths) {
  var seen = new Set();
  var unique = [];
  (paths || []).forEach(function(path) {
    if (typeof path !== 'string') return;
    var value = path.trim();
    if (!value || seen.has(value)) return;
    seen.add(value);
    unique.push(value);
  });
  return unique;
}

function appendUniquePaths(target, paths) {
  var result = target.slice();
  var seen = new Set(result);
  uniqueFilePaths(paths).forEach(function(path) {
    if (!seen.has(path)) {
      seen.add(path);
      result.push(path);
    }
  });
  return result;
}

function mergeQueueFiles(newFiles) {
  var known = new Set(files);
  var added = [];
  uniqueFilePaths(newFiles).forEach(function(filePath) {
    if (known.has(filePath)) return;
    known.add(filePath);
    files.push(filePath);
    // 重新导入 = 全新的 pending 项：旧的移除记录在这里被覆盖，
    // 不会复活成"已跳过"那种再也压不动的状态。
    queueItems.set(filePath, {
      path: filePath, state: 'pending', result: null, originalSize: null,
    });
    added.push(filePath);
  });
  return added;
}

function handleFilePaths(filePaths) {
  var incoming = uniqueFilePaths(filePaths);
  if (incoming.length === 0) return Promise.resolve([]);

  // Serialize directory expansion and queue commits. This keeps a slow scan
  // from finishing after a later, faster scan and overwriting the queue.
  pendingImports = pendingImports.then(async function() {
    var expanded;
    try {
      expanded = await invoke('expand_image_files', { filePaths: incoming });
    } catch (e) {
      console.error('Image expansion failed:', e);
      showToast('读取图片失败，请重试');
      return [];
    }

    expanded = uniqueFilePaths(expanded);
    if (expanded.length === 0) {
      showToast('文件夹中没有找到可压缩的图片');
      return [];
    }

    var added = mergeQueueFiles(expanded);
    inputPaths = appendUniquePaths(inputPaths, incoming);

    var queuePanel = document.getElementById('queuePanel');
    if (queuePanel) queuePanel.style.display = 'block';
    settingsPanel.style.display = 'block';
    resultsPanel.style.display = 'none';
    updateQueueSummary();
    renderFileQueue();
    var container = document.querySelector('.container');
    if (container) container.scrollTop = 0;

    if (added.length === 0) {
      showToast('所选图片已在队列中');
      return added;
    }

    var ac = document.getElementById('autoCompress');
    if (ac && ac.checked) {
      if (isCompressing) {
        pendingAutoCompress = true;
      } else {
        startCompression(false);
      }
    }
    return added;
  }).catch(function(error) {
    console.error('Queue import failed:', error);
    showToast('添加图片失败，请重试');
    return [];
  });
  return pendingImports;
}

// Global state for compression
var fileRows = {};
var queueSortDescending = false;
var pendingImports = Promise.resolve();
var queueRevision = 0;

// ─── 队列状态（唯一真相，DOM 只能照着它画）───────────────────────
// 这一段是"这个文件还需不需要处理"的**唯一**判据，前端测试直接切这段真实代码来跑。

/// 队列状态的读入口。DOM 只能**照着它**画，不许反过来当状态用。
function queueItem(file) {
  return queueItems.get(file) || null;
}

function queueState(file) {
  var item = queueItems.get(file);
  return item ? item.state : null;
}

function setQueueState(file, state) {
  var item = queueItems.get(file);
  if (!item) return null;
  item.state = state;
  return item;
}

/// 队列里此刻该处理的文件 = state 为 pending 的那些，按队列顺序。
/// `requestedPaths` 给"只处理这几个"用（单文件重试）。
function getPendingQueuePaths(requestedPaths) {
  var wanted = Array.isArray(requestedPaths) ? new Set(requestedPaths) : null;
  return files.filter(function(file) {
    if (wanted && !wanted.has(file)) return false;
    return queueState(file) === 'pending';
  });
}

/// 队列里全部结果（按队列顺序）。压缩产物的一切操作（另存为/对比/恢复/导出）
/// 都从队列读，不再维护一个平行的 results 数组。
function queueResults() {
  var out = [];
  files.forEach(function(file) {
    var item = queueItems.get(file);
    if (item && item.result) out.push(item.result);
  });
  return out;
}

/// 用户看到的总进度。**这是队列的属性，不是某一轮的属性**：
/// 停止后重新开始一轮时，这一轮的目标会变小（只含 pending），但这里的 total
/// 一直是整个队列（100 → 100），所以进度绝不会从 40/100 掉回 0/60。
function getQueueProgress() {
  var progress = { total: 0, processed: 0, done: 0, failed: 0, running: 0, pending: 0 };
  files.forEach(function(file) {
    var item = queueItems.get(file);
    if (!item) return;
    // removed / restored 已经离开了这套账：一个被移出队列，一个被用户撤销了。
    if (item.state === 'removed' || item.state === 'restored') return;
    progress.total += 1;
    if (item.state === 'done') progress.done += 1;
    else if (item.state === 'failed') progress.failed += 1;
    else if (item.state === 'running') progress.running += 1;
    else if (item.state === 'pending') progress.pending += 1;
  });
  // failed 也算"处理过"：它确实跑完了一次，只是没成。否则 98 成功 + 2 失败
  // 的队列会永远停在 98%，那条进度条就成了假的。
  progress.processed = progress.done + progress.failed;
  return progress;
}

function updateQueueSummary() {
  var summary = document.getElementById('queueSummary');
  if (!summary) return;
  var p = getQueueProgress();
  if (p.total === 0) {
    summary.textContent = files.length + ' 个文件';
  } else {
    // 「已处理」而不是「已完成」：失败的文件也算处理过，说"完成"会把失败藏起来。
    summary.textContent = p.processed + ' / ' + p.total + ' 已处理'
      + (p.failed > 0 ? ' · 失败 ' + p.failed : '')
      + compressionStateSuffix()
      + cpuLimitText();
  }
  updateBulkActionButtons();
  applyQueueView();
  renderQueueProgressFill();
  renderStartButton();
}

/// 摘要里跟着阶段走的那一小段。只有「已暂停 / 正在停止」两种，
/// 不往里塞"还有几个在跑"的数字：那个数字在事件之后就没有下一个事件来更新它了。
function compressionStateSuffix() {
  if (!isCompressing) return '';
  if (compressionState === COMPRESSION_PAUSED) return ' · 已暂停';
  if (compressionState === COMPRESSION_STOPPING) return ' · 正在停止';
  return '';
}

/// 进度条填充宽度 = 已处理 / 总数。不靠 CSS 动画假装有进度：
/// 停止之后它停在真实比例上，继续时从这个比例接着长。
function renderQueueProgressFill() {
  var fill = document.getElementById('compressBtnFill');
  if (!fill) return;
  var p = getQueueProgress();
  fill.style.width = p.total === 0 ? '0%' : (p.processed / p.total * 100) + '%';
}

function updateBulkActionButtons() {
  var restoreBtn = document.getElementById('restoreAllBtn');
  if (!restoreBtn) return;
  var hasRestorable = queueResults().some(function(r) { return r && r.success; });
  restoreBtn.style.display = hasRestorable ? 'inline-flex' : 'none';
}

// ─── 队列渲染（排序 / 视图 / 每一行的画法）──────────────────────

// CPU 上限的展示口径：后端负责算生效值，前端只渲染"上限 / 可用并行数"。
// 这里没有任何绑核语义 —— 数字只是"同时允许几份 CPU 并行压缩工作"。
var cpuStatus = null;

function cpuCeiling() {
  return Math.max(1, (cpuStatus && cpuStatus.availableParallelism) || 1);
}

function cpuLimitText() {
  if (!cpuStatus) return '';
  if (cpuStatus.configuredLimit === null || cpuStatus.configuredLimit === undefined) {
    return ' · CPU 自动';
  }
  var ceiling = cpuCeiling();
  var limit = Math.min(Math.max(1, cpuStatus.effectiveLimit || 1), ceiling);
  return ' · CPU ' + limit + '/' + ceiling;
}

function toggleQueueSortDirection() {
  queueSortDescending = !queueSortDescending;
  applyQueueView();
}

function applyQueueView() {
  var list = document.getElementById('fileQueueList');
  if (!list) return;
  var filter = document.getElementById('queueFailedOnly');
  var failedOnly = !!(filter && filter.checked);
  var sort = document.getElementById('queueSortKey');
  var key = sort ? sort.value : 'import';
  var direction = document.getElementById('queueSortDirection');
  if (direction) {
    direction.innerHTML = iconMarkup(queueSortDescending ? 'sort-desc' : 'sort-asc', true) + (queueSortDescending ? ' 降序' : ' 升序');
    direction.setAttribute('aria-label', queueSortDescending ? '当前降序，点击切换升序' : '当前升序，点击切换降序');
  }
  // 排序键也全部从 queueItems 读：DOM class 只负责画，不参与任何判断。
  var states = ['failed', 'running', 'pending', 'done', 'restored', 'removed'];
  var entries = files.map(function(file, index) {
    var row = fileRows[file];
    var item = queueItems.get(file);
    var result = item && item.result;
    var value = index;
    if (key === 'name') value = basename(file);
    if (key === 'original') value = result ? result.originalSize : item && item.originalSize;
    if (key === 'compressed') value = result && result.success ? result.compressedSize : null;
    if (key === 'ratio') value = result && result.success ? result.savings : null;
    if (key === 'status') value = states.indexOf(item ? item.state : 'pending');
    return { file: file, row: row, index: index, value: value };
  });
  entries.sort(function(a, b) {
    // Unknown sizes and unfinished compression ratios stay last in either direction.
    var aMissing = a.value == null || (typeof a.value === 'number' && !Number.isFinite(a.value));
    var bMissing = b.value == null || (typeof b.value === 'number' && !Number.isFinite(b.value));
    if (aMissing !== bMissing) return aMissing ? 1 : -1;
    var compared = aMissing ? 0 : typeof a.value === 'string'
      ? a.value.localeCompare(b.value, 'zh-CN', { numeric: true, sensitivity: 'base' })
      : a.value - b.value;
    return (queueSortDescending ? -compared : compared) || a.index - b.index;
  });
  var visible = 0;
  Object.keys(fileRows).forEach(function(file) {
    // 「只看失败」也按 queueItems 判，不按 DOM class：类名只是画出来的结果，
    // 拿它当判据，一旦某处忘了同步 class，筛出来的东西就是错的。
    var failedRow = queueState(file) === 'failed';
    fileRows[file].hidden = !files.includes(file) || (failedOnly && !failedRow);
  });
  entries.forEach(function(entry, index) {
    if (!entry.row) return;
    if (!entry.row.hidden) visible++;
    if (list.children[index] !== entry.row) list.insertBefore(entry.row, list.children[index] || null);
  });
  var empty = document.getElementById('queueFilterEmpty');
  if (empty) empty.hidden = !failedOnly || visible > 0;
}

async function renderFileQueue() {
  var list = document.getElementById('fileQueueList');
  if (!list) return;
  var wanted = new Set(files);

  Object.keys(fileRows).forEach(function(filePath) {
    if (!wanted.has(filePath)) {
      var staleRow = fileRows[filePath];
      if (staleRow) staleRow.remove();
      delete fileRows[filePath];
    }
  });

  var newFiles = [];
  for (var i = 0; i < files.length; i++) {
    if (!fileRows[files[i]]) {
      var row = createQueueRow(files[i]);
      fileRows[files[i]] = row;
      newFiles.push(files[i]);
    }
    // appendChild also moves an existing row, preserving the queue order.
    list.appendChild(fileRows[files[i]]);
  }
  applyQueueView();
  // Fetch file sizes for newly added rows only (preserve existing row state)
  if (newFiles.length > 0) {
    try {
      const sizes = await invoke('get_file_sizes', { filePaths: newFiles });
      for (var j = 0; j < newFiles.length; j++) {
        var item = queueItems.get(newFiles[j]);
        var row = fileRows[newFiles[j]];
        if (item && sizes[j] !== undefined) item.originalSize = sizes[j];
        if (row && sizes[j] !== undefined && (!item || item.state === 'pending')) {
          var sizeEl = row.querySelector('.queue-item-size');
          if (sizeEl) sizeEl.textContent = formatBytes(sizes[j]);
        }
      }
    } catch (e) { /* ignore */ }
    applyQueueView();
  }
}

/// 把一个队列项此刻的状态**画**到它那一行上：图标、文案、尺寸、操作按钮。
/// 唯一的方向是 queueItems → DOM；DOM class 不许反过来影响任何判断。
function paintQueueRow(filePath) {
  var row = fileRows[filePath];
  var item = queueItems.get(filePath);
  if (!row || !item) return;
  var state = item.state;
  ['pending', 'running', 'done', 'failed', 'restored', 'removed'].forEach(function(name) {
    row.classList.toggle(name, name === state);
  });
  // 兼容既有样式表里的 .waiting / .compressing 两个名字。
  row.classList.toggle('waiting', state === 'pending');
  row.classList.toggle('compressing', state === 'running');

  var rmBtn = row.querySelector('.queue-item-remove');
  if (rmBtn) rmBtn.style.display = state === 'pending' ? '' : 'none';

  var icon = row.querySelector('.queue-item-icon');
  var sizeEl = row.querySelector('.queue-item-size');
  var statusEl = row.querySelector('.queue-item-status');
  var actions = row.querySelector('.queue-item-actions');
  var errIcon = actions ? actions.querySelector('.error-info-btn') : null;
  if (statusEl) {
    // 只改文案节点，保住里面那个已经挂上去的错误图标。
    statusEl.textContent = '';
  }
  if (actions) actions.innerHTML = '';

  var result = item.result;
  if (state === 'done' && result) {
    if (icon) icon.innerHTML = iconMarkup('check', true);
    if (sizeEl) {
      sizeEl.textContent = formatBytes(result.originalSize) + ' → ' + formatBytes(result.compressedSize);
    }
    if (statusEl) {
      statusEl.textContent = (result.savings >= 0 ? '-' : '+') + Math.abs(result.savings).toFixed(1) + '%';
      if (result.error) appendErrorIcon(statusEl, result);
    }
    renderQueueResultActions(row, result);
    return;
  }
  if (state === 'failed' && result) {
    if (icon) icon.innerHTML = iconMarkup('error', true);
    if (statusEl) {
      statusEl.textContent = '失败';
      appendErrorIcon(statusEl, result);
    }
    renderQueueResultActions(row, result);
    return;
  }
  if (state === 'restored') {
    if (icon) icon.innerHTML = iconMarkup('restore', true);
    if (statusEl) statusEl.textContent = '已恢复';
    renderRestoredActions(row, filePath);
    return;
  }

  if (state === 'removed') {
    if (icon) icon.innerHTML = iconMarkup('minus', true);
    if (statusEl) statusEl.textContent = '已移除';
  }
  // pending 的行此刻该写什么，交给同一张状态表（暂停时是「已暂停」）。
  renderTaskStatus(row, state === 'pending' ? waitingRowStatus() : state);
  // 重新排队（重试 / 继续压缩）时把尺寸还原成原图大小：
  // 上一轮那个「1.2MB → 800KB」留在这儿就是在报一个已经不成立的结果。
  if (sizeEl) sizeEl.textContent = item.originalSize ? formatBytes(item.originalSize) : '';
}

/// 失败行上那个小三角：鼠标悬停有 title，点一下把完整错误说出来。
/// （此前这里调的 showErrorDetail 根本没定义过，点一下就是抛异常。）
function showErrorDetail(filePath, message) {
  showToast(basename(filePath) + ': ' + message);
}

function appendErrorIcon(statusEl, result) {
  if (!statusEl || !result.error) return;
  var errIcon = document.createElement('span');
  errIcon.className = 'error-info-btn';
  errIcon.title = result.error;
  errIcon.innerHTML = iconMarkup('warning', true);
  errIcon.onclick = function(e) { e.stopPropagation(); showErrorDetail(result.file, result.error); };
  statusEl.appendChild(errIcon);
}

function createQueueRow(filePath) {
  var row = document.createElement('div');
  row.className = 'file-queue-item';
  row.dataset.file = filePath;
  var name = basename(filePath);
  row.innerHTML =
    '<span class="queue-item-icon">' + iconMarkup('queue', true) + '</span>' +
    '<span class="queue-item-name"></span>' +
    '<span class="queue-item-size"></span>' +
    '<span class="queue-item-status">等待中</span>' +
    '<span class="queue-item-actions"></span>' +
    '<button class="queue-item-remove" title="移除">' + iconMarkup('close', true) + '</button>' +
    '<div class="progress-file-bar"></div>';
  var nameEl = row.querySelector('.queue-item-name');
  if (nameEl) nameEl.textContent = name;
  var rmBtn = row.querySelector('.queue-item-remove');
  rmBtn.addEventListener('click', function(e) {
    e.stopPropagation();
    removeQueueFile(filePath);
  });
  paintQueueRow(filePath);
  return row;
}

/// 把一个文件移出队列。**只有等待中（还没开始）的可以移**：已经在压的那一行
/// 没有 × 按钮，因为半路扔掉一个正在跑的编码器会留下写了一半的产物。
function removeQueueFile(filePath) {
  if (queueState(filePath) !== 'pending') return;
  if (isCompressing) {
    // 后端也要知道：它可能正堵在闸门上等着，得让那个 worker 自己退出。
    invoke('cancel_file', { filePath: filePath }).catch(function() {});
  }
  setQueueState(filePath, 'removed');
  var idx = files.indexOf(filePath);
  if (idx >= 0) files.splice(idx, 1);
  var row = fileRows[filePath];
  if (row) {
    if (row.parentNode) row.parentNode.removeChild(row);
    delete fileRows[filePath];
  }
  updateQueueSummary();
}

function renderQueueResultActions(row, result) {
  var actions = row.querySelector('.queue-item-actions');
  if (!actions) return;
  actions.innerHTML = '';
  if (!result) return;

  var actionDefs = [];
  if (result.success) {
    // 后缀 / 目录模式的原图从没被覆盖过：那一行按下去删的是这次生成的产物，
    // 按钮就不能写着「恢复原图」。历史页同一套判据（historyRowActionDefs）。
    var undo = result.outputMode === 'replace'
      ? { action: 'restore', title: '恢复原图', icon: iconMarkup('restore', true) }
      : { action: 'restore', title: '删除这次压缩结果', icon: iconMarkup('trash', true), danger: true };
    actionDefs = [
      { action: 'save', title: '另存为', icon: iconMarkup('save', true) },
      { action: 'compare', title: '对比查看', icon: iconMarkup('compare', true) },
      undo,
      { action: 'finder', title: '在访达中显示', icon: iconMarkup('finder', true) },
    ];
  } else {
    actionDefs = [
      { action: 'retry', title: '重试', icon: iconMarkup('recompress', true) },
    ];
  }
  actionDefs.push({ action: 'log', title: '复制日志', icon: iconMarkup('copy', true) });

  actionDefs.forEach(function(def) {
    var btn = document.createElement('button');
    btn.className = 'queue-action-btn' + (def.danger ? ' danger' : '');
    btn.type = 'button';
    btn.title = def.title;
    btn.innerHTML = def.icon;
    btn.addEventListener('click', function(e) {
      e.stopPropagation();
      if (def.action === 'save') saveResult(result.file);
      else if (def.action === 'compare') openCompareByFile(result.file);
      else if (def.action === 'restore') restoreOriginal(result.file);
      else if (def.action === 'finder') openInFinder(result.file);
      else if (def.action === 'retry') compressOneFile(result.file);
      else if (def.action === 'log') copyCompressLog(result);
    });
    actions.appendChild(btn);
  });
}

function copyCompressLog(result) {
  var opts = result.compressOptions || {};
  var lines = [];
  lines.push('版本: ' + BUILD_VARIANT);
  lines.push('=== OctoShrink \u538b\u7f29\u65e5\u5fd7 ===');
  lines.push('');
  lines.push('\u6587\u4ef6: ' + (result.file || ''));
  lines.push('\u72b6\u6001: ' + (result.success ? '\u6210\u529f' : '\u5931\u8d25'));
  lines.push('');
  lines.push('--- \u538b\u7f29\u53c2\u6570 ---');
  lines.push('quality: ' + (opts.quality !== undefined ? opts.quality : '(\u672a\u8bbe\u7f6e)'));
  lines.push('smartMode: ' + (opts.smartMode !== undefined ? opts.smartMode : '(\u672a\u8bbe\u7f6e)'));
  lines.push('outputFormat: ' + (opts.outputFormat || '(\u672a\u8bbe\u7f6e)'));
  lines.push('backend: ' + (opts.backend || '(\u672a\u8bbe\u7f6e)'));
  lines.push('effort: ' + (opts.effort !== undefined ? opts.effort : '(\u672a\u8bbe\u7f6e)'));
  lines.push('convertToWebp: ' + (opts.convertToWebp !== undefined ? opts.convertToWebp : '(\u672a\u8bbe\u7f6e)'));
  lines.push('outputMode: ' + (opts.outputMode || '(\u672a\u8bbe\u7f6e)'));
  lines.push('outputSuffix: ' + (opts.outputSuffix || '(\u672a\u8bbe\u7f6e)'));
  lines.push('');
  lines.push('--- \u538b\u7f29\u7ed3\u679c ---');
  if (result.success) {
    lines.push('\u539f\u59cb\u5927\u5c0f: ' + formatBytes(result.originalSize) + ' (' + result.originalSize + ' bytes)');
    lines.push('\u538b\u7f29\u540e\u5927\u5c0f: ' + formatBytes(result.compressedSize) + ' (' + result.compressedSize + ' bytes)');
    lines.push('\u538b\u7f29\u7387: ' + (result.savings >= 0 ? '-' : '+') + Math.abs(result.savings).toFixed(1) + '%');
    lines.push('\u8f93\u51fa\u683c\u5f0f: ' + (result.type || '(\u672a\u77e5)'));
    lines.push('\u7b97\u6cd5: ' + (result.algorithm || '(\u672a\u77e5)'));
  } else {
    lines.push('\u538b\u7f29\u5931\u8d25');
  }
  lines.push('');
  lines.push('--- \u9519\u8bef\u4fe1\u606f ---');
  lines.push(result.error ? result.error : '(\u65e0)');
  var ok = copyTextToClipboard(lines.join('\n'));
  showToast(ok ? '\u538b\u7f29\u65e5\u5fd7\u5df2\u590d\u5236\u5230\u526a\u8d34\u677f' : '\u590d\u5236\u5931\u8d25\uff0c\u8bf7\u624b\u52a8\u9009\u4e2d\u65e5\u5fd7\u6587\u672c');
}

/// \u590d\u5236\u6587\u672c\u5230\u526a\u8d34\u677f\u3002execCommand \u662f\u6c99\u76d2 WebKit \u91cc\u552f\u4e00\u7a33\u7684\u8def\u5f84\uff1a
/// navigator.clipboard \u8981\u7528\u6237\u624b\u52bf + \u6743\u9650\uff0cApp Store \u7248\u62ff\u4e0d\u5230\u3002\u8fd4\u56de\u662f\u5426\u6210\u529f\uff0c\u6587\u6848\u7531\u8c03\u7528\u65b9\u51b3\u5b9a\u3002
function copyTextToClipboard(text) {
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.top = '0';
  ta.style.left = '0';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  var ok = false;
  try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
  document.body.removeChild(ta);
  return ok;
}

function renderRestoredActions(row, filePath) {
  var actions = row.querySelector('.queue-item-actions');
  if (!actions) return;
  actions.innerHTML = '';

  var btn = document.createElement('button');
  btn.className = 'queue-action-btn';
  btn.type = 'button';
  btn.title = '重新压缩';
  btn.innerHTML = iconMarkup('recompress', true);
  btn.addEventListener('click', function(e) {
    e.stopPropagation();
    compressOneFile(filePath);
  });
  actions.appendChild(btn);
}

function getCurrentCompressionConfig() {
  const outputMode = document.querySelector('input[name="outputMode"]:checked').value;
  const outputFormat = processingMode === 'system'
    ? document.getElementById('systemOutputFormat').value
    : document.getElementById('outputFormat').value;
  const backend = document.getElementById('compressionBackend').value;
  const effort = parseInt(document.getElementById('compressionEffort').value);
  const smartMode = document.getElementById('smartMode').checked;
  const convertToWebp = document.getElementById('convertToWebp').checked;

  let effectiveFormat = outputFormat;
  if (processingMode === 'advanced' && convertToWebp && outputFormat === 'original') {
    effectiveFormat = 'webp';
  }

  if (outputMode === 'folder' && !outputDir) {
    return { error: '请先选择输出目录' };
  }

  return {
    useSmartIpc: processingMode === 'advanced' && (smartMode || effectiveFormat !== 'original'),
    options: {
      processingMode,
      systemImageSize: document.getElementById('systemImageSize').value,
      preserveMetadata: document.getElementById('preserveMetadata').checked,
      quality: parseInt(qualitySlider.value),
      smartMode: processingMode === 'advanced' && smartMode,
      outputFormat: effectiveFormat,
      backend,
      effort,
      convertToWebp: processingMode === 'advanced' && convertToWebp,
      outputMode,
      outputSuffix: getOutputSuffix(),
      outputDir: outputMode === 'folder' ? outputDir : null,
      sourceRoots: inputPaths.slice(),
    },
  };
}

function clearAllFiles() {
  if (files.length === 0 && !isCompressing) return;
  if (!confirm('确定要清空全部 ' + files.length + ' 个文件吗？')) return;

  // 正在跑的那次 invoke 不能提前作废：这里只把队列**标记**成不要了，
  // 真正把它收回来的仍然是发起它的那次调用（它会在 finally 里收尾）。
  var wasCompressing = isCompressing;
  queueRevision++;
  if (wasCompressing && executionSession) {
    // 一次调用取消整批：逐个 invoke 会让每个请求都顺手动一次暂停闸门，
    // 队列会在清空过程中被重新放行。
    invoke('cancel_batch', { filePaths: executionSession.targetPaths.slice() }).catch(function() {});
  }

  files = [];
  inputPaths = [];
  queueItems = new Map();
  fileRows = {};
  pendingAutoCompress = false;
  var queuePanel = document.getElementById('queuePanel');
  if (queuePanel) queuePanel.style.display = 'none';
  settingsPanel.style.display = 'block';
  resultsPanel.style.display = 'none';
  var list = document.getElementById('fileQueueList');
  if (list) list.innerHTML = '';
  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'none';
  updateQueueSummary();
  emitCompareResultsChanged();
}

// ─── Compression ────────────────────────────────────────────────

// ─── 执行会话（一轮）─────────────────────────────────────────────
// 一次执行会话**不是队列**：队列是长期存在的（导入 100 张就在那儿），
// 会话是"用户按下开始 / 继续压缩"到"这一轮结束"之间那一段。
//
// 两者分开是这套行为稳定的前提：
//  - 队列（queueItems）决定"这个文件还需不需要处理"；
//  - 会话决定"当前这一轮在不在跑、跑的是哪些文件"；
//  - 每一轮的目标是开始时拍下的快照（targetPaths），中途导入不会塞进来；
//  - 界面的总进度属于**队列**，所以停止后重新开始一轮，进度绝不会归零。

var executionSession = null;
var sessionSeq = 0;

/// 开一轮：目标 = 调用方给的这批（只会是 pending），并记下当时的队列版本。
function beginExecutionSession(targetPaths) {
  sessionSeq += 1;
  executionSession = {
    id: 'session-' + sessionSeq + '-' + Date.now(),
    queueRevision: queueRevision,
    targetPaths: targetPaths.slice(),
    phase: COMPRESSION_RUNNING,
  };
  return executionSession;
}

function endExecutionSession() {
  executionSession = null;
}

/// 这条事件属不属于当前这一轮。带上会话号之后，"上一轮迟到的收尾事件"
/// 再也污染不了下一轮 —— 光靠 queueRevision 挡不住"同一队列里的两轮"。
function eventBelongsToCurrentSession(data) {
  return !!(executionSession && data && data.sessionId === executionSession.id);
}

// ─── 压缩主流程 ─────────────────────────────────────────────────

async function startCompression(isIncrement) {
  return startCompressionForPaths(isIncrement, null);
}

async function startCompressionForPaths(isIncrement, requestedPaths) {
  if (isCompressing) return;
  // 只提交 pending：已经压完的绝不重压，失败的要用户显式点「重试」。
  var batchPaths = getPendingQueuePaths(requestedPaths);
  if (batchPaths.length === 0) return;

  // 先占住批次位（静默）：真正开跑之前还有几步可能提前 return，
  // 那几步里不该亮出"暂停/停止"按钮和「压缩中…」。
  setCompressionState(COMPRESSION_RUNNING, true);
  var runRevision = queueRevision;

  var hasOutputAccess = false;
  try {
    hasOutputAccess = await ensureSystemOutputAccess();
  } catch (error) {
    console.error('Output access check failed:', error);
    showToast('无法确认输出目录，请重试');
  }
  if (!hasOutputAccess) {
    setCompressionState(COMPRESSION_IDLE, true);
    updateQueueSummary();
    return;
  }
  if (runRevision !== queueRevision) {
    setCompressionState(COMPRESSION_IDLE, true);
    updateQueueSummary();
    return;
  }

  setCompressionState(COMPRESSION_RUNNING, true);
  currentCompressOptions = null;

  const config = getCurrentCompressionConfig();
  if (config.error) {
    showToast(config.error);
    setCompressionState(COMPRESSION_IDLE, true);
    updateQueueSummary();
    return;
  }
  // 队列在等待这几步的工夫被清空了：这一轮没有目标，直接收场。
  batchPaths = batchPaths.filter(function(filePath) { return queueState(filePath) === 'pending'; });
  if (batchPaths.length === 0) {
    setCompressionState(COMPRESSION_IDLE, true);
    updateQueueSummary();
    return;
  }

  var batchOptions = config.options;
  currentCompressOptions = batchOptions;
  var session = beginExecutionSession(batchPaths);
  var settled = new Set();

  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'flex';
  updateStats();

  updateQueueSummary();

  // 一轮开始 = 未暂停、未停止；按钮与文案全部由状态机说了算。
  setCompressionState(COMPRESSION_RUNNING);
  setPauseButtonVisible(true);
  session.phase = COMPRESSION_RUNNING;

  renderFileQueue();

  /// 事件 → 队列状态。**每一层判据都来自 queueItems**，不看 DOM class：
  /// 从前"这一行是不是被取消过"要靠 row.classList.contains('cancelled')，
  /// 结果停止一轮再继续时，新事件全被那行旧 class 挡在门外。
  const progressHandler = (data) => {
    if (!data) return;
    // 会话身份先对齐：上一轮迟到的 deferred / cancelled 事件绝不许碰这一轮。
    if (!executionSession || data.sessionId !== executionSession.id) return;
    if (runRevision !== queueRevision) return;
    var file = data.file;
    var item = queueItems.get(file);
    if (!item) return;

    if (data.status === 'starting') {
      if (item.state === 'pending') item.state = 'running';
      settled.delete(file);
      paintQueueRow(file);
      applyQueueView();
      updateQueueSummary();
      return;
    }

    if (data.status === 'completed' || data.status === 'failed') {
      var result = data.result;
      if (!result || settled.has(result.file)) return;
      settled.add(result.file);
      result.compressOptions = batchOptions;
      item.result = result;
      item.state = result.success ? 'done' : 'failed';
      paintQueueRow(file);
      updateStats();
      updateQueueSummary();
      emitCompareResultsChanged();
      return;
    }

    if (data.status === 'cancelled') {
      // 用户明确把它移出了队列：它本轮到此为止，不回到 pending。
      if (settled.has(file)) return;
      settled.add(file);
      item.state = 'removed';
      var idx = files.indexOf(file);
      if (idx >= 0) files.splice(idx, 1);
      var row = fileRows[file];
      if (row) {
        if (row.parentNode) row.parentNode.removeChild(row);
        delete fileRows[file];
      }
      updateQueueSummary();
      return;
    }

    if (data.status === 'deferred') {
      // 整批被停止，这一轮没轮到它：**状态保持 pending**，
      // 下一次「继续压缩」自然还会带上它。行上照旧写「等待中」。
      if (item.state === 'running') return;
      paintQueueRow(file);
      updateQueueSummary();
      return;
    }

    // queued：只是告诉大家它排上了，状态仍然是 pending。
    paintQueueRow(file);
  };

  var unlisten = function() {};

  try {
    unlisten = await listen('compress-progress', function(event) {
      progressHandler(event.payload);
    });
    var sessionResult = await invoke(config.useSmartIpc ? 'compress_smart' : 'compress_files', {
      sessionId: session.id,
      filePaths: batchPaths,
      options: batchOptions,
    });
    // 事件是实时路径，返回值是补救路径：某一轮结束了却没有把事件送到时，
    // 靠它把结果补齐（会话号对不上就直接不认）。
    var results = sessionResult && Array.isArray(sessionResult.results) ? sessionResult.results : [];
    results.forEach(function(result) {
      progressHandler({
        sessionId: sessionResult.sessionId,
        file: result.file,
        status: result.success ? 'completed' : 'failed',
        result: result,
      });
    });
    if (runRevision === queueRevision) {
      updateStats();
      showResults();
    }
  } catch (err) {
    console.error('Compression error:', err);
    showToast((processingMode === 'system' ? '转换出错: ' : '压缩出错: ') + (err.message || err));
  } finally {
    try { unlisten(); } catch (e) {}
    if (executionSession === session) endExecutionSession();
    // 用户按了停止：这一轮就地结束，绝不被"自动压缩"再拉起来跑下一批。
    var stoppedByUser = compressionState === COMPRESSION_STOPPING;
    setCompressionState(COMPRESSION_IDLE);
    setPauseButtonVisible(false);
    updateQueueSummary();
    var shouldContinue = !stoppedByUser && pendingAutoCompress
      && getPendingQueuePaths().length > 0;
    pendingAutoCompress = false;
    if (shouldContinue) {
      startCompression(true);
    } else {
      updateQueueSummary();
    }
    refreshHistoryIfOpen();
  }
}

function updateStats() {
  let totalOriginal = 0;
  let totalCompressed = 0;

  const all = queueResults();
  for (const r of all) {
    if (r.success) {
      totalOriginal += r.originalSize || 0;
      totalCompressed += r.compressedSize || 0;
    }
  }

  const savings = totalOriginal - totalCompressed;
  const rate = totalOriginal > 0 ? ((savings / totalOriginal) * 100) : 0;

  statOriginal.textContent = formatBytes(totalOriginal);
  statCompressed.textContent = formatBytes(totalCompressed);
  totalSavings.textContent = formatBytes(savings);
  totalRate.textContent = rate.toFixed(1) + '%';
}

function showResults() {
  resultsPanel.style.display = 'none';
  resultsList.innerHTML = '';
}

/// 单个文件重新压一次 = 把它放回 pending，然后开一轮只含它的会话。
/// 失败文件走的就是这条路（显式「重试」），普通「继续压缩」不碰失败项。
async function compressOneFile(filePath) {
  if (isCompressing) return;
  var item = queueItems.get(filePath);
  if (!item) return;
  item.result = null;
  item.state = 'pending';
  paintQueueRow(filePath);
  emitCompareResultsChanged();
  await startCompressionForPaths(true, [filePath]);
  var after = queueItems.get(filePath);
  if (after && after.state === 'done') {
    showToast('已重新压缩: ' + basename(filePath));
  }
}

async function saveResult(filePath) {
  const item = queueItems.get(filePath);
  const result = item && item.result;
  if (!result || !result.outputPath) {
    showToast('无法保存：找不到压缩文件');
    return;
  }
  const savedPath = await invoke('save_file', { sourcePath: result.outputPath });
  if (savedPath) {
    showToast('已保存到: ' + basename(savedPath));
  }
}

function openInFinder(filePath) {
  // Reveal the compressed output if available, else the original
  const item = queueItems.get(filePath);
  const result = item && item.result;
  const target = (result && result.outputPath) ? result.outputPath : filePath;
  invoke('open_in_finder', { filePath: target });
}

// 压缩后又用别的 App 改过图：恢复会覆盖那个新版本，必须先问。
var RESTORE_CONFLICT_TEXT = '这个文件在压缩后又被修改过。\n恢复原图会覆盖当前版本。';

/// 恢复成功后的统一收尾：主队列、历史页、对比窗口都只走这里。
/// skipRefresh 供批量恢复使用，避免每个文件重绘一次结果列表。
function afterRestore(filePath, skipRefresh) {
  markQueueRowRestored(filePath);
  if (skipRefresh) return;
  showResults();
  updateQueueSummary();
  emitCompareResultsChanged();
  refreshHistoryIfOpen();
}

async function restoreOriginal(filePath, force) {
  var outcome;
  try {
    outcome = await invoke('restore_original', { filePath: filePath, force: !!force });
  } catch (error) {
    showToast('恢复失败: ' + (error.message || error));
    return;
  }
  if (outcome.conflict) {
    if (!confirm(RESTORE_CONFLICT_TEXT)) return;
    await restoreOriginal(filePath, true);
    return;
  }
  if (!outcome.success) {
    showToast(outcome.error || '恢复失败');
    return;
  }
  // 「这条记录到底是什么模式」以后端说的为准：缓存里的 result 可能已经不是这一批的了。
  var cachedItem = queueItems.get(filePath);
  var mode = outcome.outputMode
    || (cachedItem && cachedItem.result ? cachedItem.result.outputMode : null);
  showToast(mode === 'replace'
    ? '已恢复原图: ' + basename(filePath)
    : '已删除这次压缩结果: ' + basename(filePath));
  afterRestore(outcome.filePath || filePath);
}

function markQueueRowRestored(filePath) {
  var item = queueItems.get(filePath);
  if (item) {
    item.result = null;
    item.state = 'restored';
  }
  paintQueueRow(filePath);
}

async function restoreAllOriginals() {
  var stash = queueResults();
  if (stash.length === 0) return;
  if (!confirm('确定要恢复全部已压缩成功的原图吗？')) return;
  var outcome;
  try {
    outcome = await invoke('restore_all', { results: stash.slice() });
  } catch (error) {
    showToast('恢复失败: ' + (error.message || error));
    return;
  }
  showToast(outcome.message);
  (outcome.restoredFiles || []).forEach(function(filePath) {
    afterRestore(filePath, true);
  });
  showResults();
  updateQueueSummary();
  emitCompareResultsChanged();
}

async function exportAll() {
  var stash = queueResults();
  if (stash.length === 0) return;
  const suffix = getResultOutputSuffix(stash[0]);
  const count = await invoke('export_all', { results: stash, outputSuffix: suffix });
  showToast('已导出 ' + count + ' 个文件到原目录（' + suffix + ' 后缀）');
}

function clearResults() {
  var wasCompressing = isCompressing;
  queueRevision++;
  if (wasCompressing && executionSession) {
    invoke('cancel_batch', { filePaths: executionSession.targetPaths.slice() }).catch(function() {});
  }
  files = [];
  inputPaths = [];
  queueItems = new Map();
  fileRows = {};
  pendingAutoCompress = false;
  resultsList.innerHTML = '';
  resultsPanel.style.display = 'none';
  var queuePanel = document.getElementById('queuePanel');
  if (queuePanel) queuePanel.style.display = 'none';
  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'none';
  settingsPanel.style.display = 'block';
  var list = document.getElementById('fileQueueList');
  if (list) list.innerHTML = '';
  updateQueueSummary();
  emitCompareResultsChanged();
}

function formatBytes(bytes) {
  if (bytes === 0) return '0B';
  if (bytes < 1024) return bytes.toFixed(1) + 'B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + 'KB';
  return (bytes / (1024 * 1024)).toFixed(1) + 'MB';
}

// ─── 页面导航（main / history / settings）───────────────────────
// 只切换 display：文件队列 DOM 与正在跑的压缩任务都不动，所以压缩中途也能进历史/设置。
var VIEWS = ['main', 'history', 'settings'];
var currentView = 'main';

function showView(name) {
  var view = VIEWS.indexOf(name) >= 0 ? name : 'main';
  currentView = view;
  VIEWS.forEach(function(id) {
    var el = document.getElementById(id + 'View');
    if (el) el.style.display = id === view ? '' : 'none';
  });
  var historyBtn = document.getElementById('historyViewBtn');
  if (historyBtn) historyBtn.classList.toggle('active', view === 'history');
  var settingsBtn = document.getElementById('settingsViewBtn');
  if (settingsBtn) settingsBtn.classList.toggle('active', view === 'settings');
  // 每次进入都重新读盘：历史是后端状态，不能只信启动时那份快照。
  if (view === 'history') refreshHistory();
  if (view === 'settings') { loadRetentionSetting(); loadCpuSetting(); initUpdatePanel(); }
}

// ─── 压缩状态机（idle / running / paused / stopping）───────────────
// 值域与后端 `CompressionScheduler::state()` 逐字一致：后端每次真的变化都发
// compression-state-change，前端只负责照着画。
//
// 从前只有 `isCompressing` 一个布尔值，于是「暂停中」和「压缩中」在界面上没有任何区别，
// loading 照转、文案照写 —— 用户点了暂停却看不出暂停了，这是那一堆体验问题的根因。
var COMPRESSION_IDLE = 'idle';
var COMPRESSION_RUNNING = 'running';
var COMPRESSION_PAUSED = 'paused';
var COMPRESSION_STOPPING = 'stopping';
var COMPRESSION_STATES = [COMPRESSION_IDLE, COMPRESSION_RUNNING, COMPRESSION_PAUSED, COMPRESSION_STOPPING];

var compressionState = COMPRESSION_IDLE;
// 下面两个是 compressionState 的派生镜像，供既有读点使用。
// **只有 setCompressionState 能写它们**（tests/pause-resume.cjs 钉住这条），
// 别处一律只读，否则又会出现"两个真相"。
var isCompressing = false;
var compressionPaused = false;

/// 唯一的写入口。silent 供"先占住批次、UI 稍后再画"的中间态使用
/// （与旧实现里那些提前 return 的路径一一对应）。
function setCompressionState(next, silent) {
  if (COMPRESSION_STATES.indexOf(next) < 0) return false;
  compressionState = next;
  isCompressing = next !== COMPRESSION_IDLE;
  compressionPaused = next === COMPRESSION_PAUSED;
  if (!silent) renderPauseControls();
  return true;
}

/// 后端阶段变化的确认。批次的收尾由发起它的那次 invoke 负责，所以：
/// - 非 idle 的状态只在本地确实有批次时采纳（否则是上一批的迟到事件）；
/// - idle **永远不采纳**，绝不把一个刚起跑的新批次打回空闲。
function applyCompressionStateEvent(payload) {
  if (!payload || COMPRESSION_STATES.indexOf(payload.state) < 0) return;
  if (payload.state === COMPRESSION_IDLE || !isCompressing) return;
  setCompressionState(payload.state);
}

// ─── 暂停 / 继续 / 停止 ──────────────────────────────────────────
// 三者都只决定"要不要再启动新文件"：暂停时正在压的那张继续跑完，
// 停止时也一样 —— 绝不 kill 已经在跑的子进程（那会留下写了一半的临时文件、
// 悬空的覆盖事务和对不上账的历史）。区别在闸门关多久：暂停关到用户点继续，
// 停止是永久关闭，等已经开跑的那几个收尾就结束整批。

function pauseButtonText(paused) {
  return paused
    ? '<svg class="symbol-icon symbol-icon-small"><use href="#icon-play"/></svg> 继续'
    : '<svg class="symbol-icon symbol-icon-small"><use href="#icon-pause"/></svg> 暂停';
}

function stopButtonText(stopping) {
  return '<svg class="symbol-icon symbol-icon-small"><use href="#icon-stop"/></svg> '
    + (stopping ? '正在停止…' : '停止');
}

/// 队列行的图标 + 文案，一处说了算 —— 不许再散落 `innerHTML = '<span class="spinner">'`。
/// 入参是**队列状态**（pending / running / done / failed / removed / restored）
/// 或会话状态（paused / stopping）。停止不改变队列状态：被延后的文件仍然是
/// pending，界面上照旧写「等待中」，因为它真的还在等下一轮。
function taskStatusMarkup(status) {
  switch (status) {
    case 'running':
      // 会话已经暂停 / 正在停止，但它真的还在跑：照实写「收尾中…」并留着 spinner。
      // 把一张确实在压缩的图假装成停下来，比让它多转一会儿圈更糟。
      if (compressionState === COMPRESSION_PAUSED || compressionState === COMPRESSION_STOPPING) {
        return { icon: '<span class="progress-file-spinner"></span>', text: '收尾中…' };
      }
      return { icon: '<span class="progress-file-spinner"></span>', text: processingActionText('progress') };
    case 'paused':
      // 暂停不用"停住的转圈"：一个静止的圆环看着像卡死，暂停图标才是它的意思。
      return { icon: iconMarkup('pause', true), text: '已暂停' };
    case 'removed':
      return { icon: iconMarkup('minus', true), text: '已移除' };
    case 'restored':
      return { icon: iconMarkup('restore', true), text: '已恢复' };
    default:
      return { icon: iconMarkup('queue', true), text: '等待中' };
  }
}

function renderTaskStatus(row, status) {
  if (!row) return;
  var markup = taskStatusMarkup(status);
  var icon = row.querySelector('.queue-item-icon');
  if (icon) icon.innerHTML = markup.icon;
  var text = row.querySelector('.queue-item-status');
  if (text) text.textContent = markup.text;
}

/// 还没开始的行此刻该显示什么：暂停时不该还写着「等待中」。
/// **停止时它仍然是 pending**（下一轮还会带上），所以照旧是「等待中」——
/// 「已跳过」那种写法是把"这一轮没轮到"说成了"这个文件出局了"。
function waitingRowStatus() {
  return compressionPaused ? 'paused' : 'pending';
}

function repaintWaitingRows() {
  files.forEach(function(filePath) {
    if (queueState(filePath) === 'running') {
      // 正在跑的行在暂停 / 停止时写「收尾中…」，那才是它此刻的真面目。
      var runningRow = fileRows[filePath];
      if (runningRow) renderTaskStatus(runningRow, 'running');
      return;
    }
    if (queueState(filePath) !== 'pending') return;
    var row = fileRows[filePath];
    if (row) renderTaskStatus(row, waitingRowStatus());
  });
}

/// 进度按钮上那段"图标 + 文案"。暂停时换掉转圈的圆环改用静态暂停图标 ——
/// "动画还在转"本身就是用户判断"到底暂停了没有"的依据。
function progressButtonMarkup() {
  if (compressionState === COMPRESSION_PAUSED) {
    return iconMarkup('pause', true) + ' 暂停中…';
  }
  if (compressionState === COMPRESSION_STOPPING) {
    return '<span class="progress-file-spinner"></span> 正在停止…';
  }
  return '<span class="progress-file-spinner"></span> ' + processingActionText('progress');
}

function renderPauseControls() {
  var stopping = compressionState === COMPRESSION_STOPPING;
  var btn = document.getElementById('pauseCompressBtn');
  var text = document.getElementById('pauseBtnText');
  if (text) text.innerHTML = pauseButtonText(compressionPaused);
  if (btn) {
    btn.title = compressionPaused ? '继续压缩剩余文件' : '暂停：不再启动新文件';
    btn.disabled = stopping;
  }
  var stopBtn = document.getElementById('stopCompressBtn');
  var stopText = document.getElementById('stopBtnText');
  if (stopText) stopText.innerHTML = stopButtonText(stopping);
  if (stopBtn) {
    stopBtn.disabled = !isCompressing || stopping;
    stopBtn.title = '停止：正在处理的文件会先完成，其余文件保留在队列中';
  }
  repaintWaitingRows();
  updateQueueSummary();
}

/// 主按钮。三件事一起看：**会话在不在跑**（compressionState）、
/// **还有没有要处理的**（队列 pending）、**有没有失败的**（队列 failed）。
/// 从前的 finally 一律写死「压缩完成 ✓」，停止之后明明还剩 58 张也照写不误。
function renderStartButton() {
  var startBtn = document.getElementById('startCompressBtn');
  if (!startBtn) return;
  var btnText = document.getElementById('compressBtnText');
  var icon = '<svg class="symbol-icon"><use href="#icon-compress"/></svg> ';
  startBtn.classList.toggle('compressing', isCompressing);
  startBtn.classList.toggle('paused', compressionState === COMPRESSION_PAUSED);
  startBtn.classList.toggle('stopping', compressionState === COMPRESSION_STOPPING);
  startBtn.classList.remove('done');

  if (isCompressing) {
    startBtn.disabled = true;
    if (btnText) btnText.innerHTML = progressButtonMarkup();
    return;
  }
  // 这一轮结束了：按钮该说什么，全看队列还剩什么。
  startBtn.disabled = false;
  var p = getQueueProgress();
  if (!btnText) return;
  if (p.pending > 0 && p.processed > 0) {
    // 停止 / 中途收场之后：还有活没干完，主按钮就是「继续压缩」。
    btnText.innerHTML = icon + processingActionText('continue');
    return;
  }
  if (p.pending > 0) {
    btnText.innerHTML = icon + processingActionText('idle');
    return;
  }
  if (p.total > 0 && p.failed > 0) {
    btnText.innerHTML = iconMarkup('warning', true) + ' 处理完成 · ' + p.failed + ' 个失败';
    return;
  }
  if (p.total > 0) {
    startBtn.classList.add('done');
    btnText.innerHTML = '<svg class="symbol-icon"><use href="#icon-check"/></svg> ' + processingActionText('done');
    return;
  }
  btnText.innerHTML = icon + processingActionText('idle');
}

function setPauseButtonVisible(visible) {
  ['pauseCompressBtn', 'stopCompressBtn'].forEach(function(id) {
    var btn = document.getElementById(id);
    if (btn) btn.style.display = visible ? 'inline-flex' : 'none';
  });
}

async function toggleCompressionPause() {
  // 停止在收尾途中不许再切换暂停：闸门已经焊死，按下去只会让文案和真相分叉。
  if (!isCompressing || compressionState === COMPRESSION_STOPPING) return;
  var previous = compressionState;
  var next = previous === COMPRESSION_PAUSED ? COMPRESSION_RUNNING : COMPRESSION_PAUSED;
  setCompressionState(next);
  try {
    await invoke(next === COMPRESSION_PAUSED ? 'pause_compression' : 'resume_compression');
  } catch (error) {
    console.error('Pause toggle failed:', error);
    setCompressionState(previous);
    showToast(next === COMPRESSION_PAUSED ? '暂停失败，请重试' : '继续失败，请重试');
  }
}

/// 停止**这一轮**：还没轮到的文件不再启动，已经在压的几个跑完各自收尾。
///
/// 停止不是取消：没轮到的文件留在队列里（仍然是 pending），主按钮随后变成
/// 「继续压缩」。停止之后**不许**自动续跑下一轮（pendingAutoCompress 在这里就清掉）：
/// 用户刚说"停下"，再被"自动压缩"拉起来就是没听他说话。
async function stopCompression() {
  if (!isCompressing || compressionState === COMPRESSION_STOPPING) return;
  var previous = compressionState;
  pendingAutoCompress = false;
  setCompressionState(COMPRESSION_STOPPING);
  showToast('正在停止：正在处理的文件会先完成，其余文件保留在队列中');
  try {
    // 闸门在后端焊死，不需要把路径一条条传过去。
    await invoke('stop_compression');
  } catch (error) {
    console.error('Stop failed:', error);
    setCompressionState(previous);
    showToast('停止失败，请重试');
  }
}

// ─── 历史记录页 ─────────────────────────────────────────────────
var historyEntries = [];
var retentionDays = 0;   // 与后端默认一致：不保留（本次退出时清理）

function pad2(value) {
  return String(value).length < 2 ? '0' + value : String(value);
}

function historyTime(millis) {
  if (!millis) return '';
  var date = new Date(millis);
  var today = new Date();
  var yesterday = new Date(today.getTime() - 86400000);
  var clock = pad2(date.getHours()) + ':' + pad2(date.getMinutes());
  if (date.toDateString() === today.toDateString()) return '今天 ' + clock;
  if (date.toDateString() === yesterday.toDateString()) return '昨天 ' + clock;
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) + ' ' + clock;
}

function canRestoreHistory(entry) {
  // recoveryAvailable = history.json 损坏后从备份目录重建出来的条目：
  // 压缩明细已经无从得知，但备份确实还在，原图仍然可以一键恢复。
  if (entry.status === 'recoveryAvailable') {
    return !!entry.backupExists && !!entry.sourceExists;
  }
  return entry.status === 'compressed'
    && entry.outputMode === 'replace'
    && !!entry.backupExists
    && !!entry.sourceExists;
}

function historyStatusText(entry) {
  if (entry.status === 'restored') {
    return '已恢复' + (entry.restoredAt ? ' · ' + historyTime(entry.restoredAt) : '');
  }
  if (entry.status === 'recoveryAvailable') {
    return entry.backupExists ? '检测到可恢复的原图备份' : '原图备份已清理';
  }
  if (entry.outputMode !== 'replace') return '原图未覆盖';
  if (!entry.sourceExists) return '原文件位置不存在';
  if (!entry.backupExists) return '原图备份已清理';
  return '已压缩';
}

/// 历史行的按钮，与队列「压缩完成」那一行同一套动作 —— 判据必须和 Swift 的
/// `historyRowActions` 逐条一致：按下去不成立的按钮一个都不许出现。
/// 后缀模式的原图从没被覆盖过，给它「恢复原图」是假的；对等的反悔是删掉产物。
function historyRowActionDefs(entry) {
  var isReplace = entry.outputMode === 'replace';
  // 「原图还摸得着吗」按模式判：覆盖模式只有备份算数（源位置此刻躺着的是压缩结果），
  // 后缀 / 目录模式的源文件本身就没被动过。
  var originalAvailable = isReplace ? !!entry.backupExists : !!entry.sourceExists;
  var defs = [];
  if (entry.outputExists) {
    defs.push({ action: 'save', title: '另存为', icon: 'save' });
  }
  // 两边都真实存在才比得出差别 —— 备份没了还挂一个「对比」，比的是那张压缩图和它自己。
  if (entry.outputExists && originalAvailable) {
    defs.push({ action: 'compare', title: '对比查看', icon: 'compare' });
  }
  if (canRestoreHistory(entry)) {
    defs.push({ action: 'restore', title: '恢复原图', icon: 'restore' });
  } else if (entry.status === 'compressed' && !isReplace && entry.outputExists) {
    defs.push({ action: 'deleteOutput', title: '删除这次压缩结果', icon: 'trash' });
  }
  defs.push({ action: 'finder', title: '在访达中显示', icon: 'finder' });
  defs.push({ action: 'log', title: '复制日志', icon: 'copy' });
  return defs;
}

/// 历史条目 → 对比窗口的载荷。字段名必须对齐 Rust 的 `CompressResult`
/// （`type` 而不是 `outType`，尺寸还要给已经格式化好的字符串），
/// 且只有备份真在的时候才填 `backupPath` —— 否则 compare_window.js 会把
/// "已被压缩结果占着的源文件"当成原图来比。
function historyCompareResult(entry) {
  return {
    file: entry.sourcePath,
    success: true,
    originalSize: entry.originalSize,
    compressedSize: entry.compressedSize,
    originalSizeFormatted: formatBytes(entry.originalSize),
    compressedSizeFormatted: formatBytes(entry.compressedSize),
    savings: entry.savings,
    type: entry.outType,
    algorithm: entry.algorithm,
    outputMode: entry.outputMode,
    outputPath: entry.outputPath || entry.sourcePath,
    backupPath: entry.backupExists ? entry.backupPath : null,
  };
}

function openCompareFromHistory(entry) {
  if (!entry.outputExists) {
    showToast('压缩结果已不存在');
    refreshHistory();
    return;
  }
  invoke('open_compare_window', {
    payload: { results: [historyCompareResult(entry)], index: 0 },
  }).catch(function(err) {
    showToast('打开对比窗口失败: ' + (err.message || err));
  });
}

async function saveHistoryOutput(entry) {
  if (!entry.outputExists || !entry.outputPath) {
    showToast('压缩结果已不存在');
    refreshHistory();
    return;
  }
  const savedPath = await invoke('save_file', { sourcePath: entry.outputPath });
  if (savedPath) showToast('已保存到: ' + basename(savedPath));
}

/// 后缀 / 目录模式的对等「反悔」= 删掉这次生成的压缩结果。
/// 删的是用户目录里的真实文件，所以必须二次确认；原图从头到尾没动过。
async function deleteHistoryOutput(entry) {
  if (!confirm('删除这次压缩结果？\n将删除 ' + entry.outputPath
    + '，并移除这条历史记录。原图未被覆盖，不受影响。')) return;
  // 后缀 / 目录模式没有"原图被改过"这回事，force 在这儿没有意义，照默认走同一个服务。
  await restoreFromHistory(entry);
}

/// 历史行的复制日志：记录里没有本批次的压缩参数快照，只报历史上记下来的那些事实。
function copyHistoryLog(entry) {
  var lines = [];
  lines.push('版本: ' + BUILD_VARIANT);
  lines.push('=== OctoShrink 压缩历史 ===');
  lines.push('');
  lines.push('文件: ' + entry.sourcePath);
  lines.push('时间: ' + historyTime(entry.createdAt));
  lines.push('状态: ' + historyStatusText(entry));
  lines.push('');
  lines.push('--- 压缩结果 ---');
  lines.push('输出: ' + (entry.outputPath || entry.sourcePath));
  lines.push('输出方式: ' + entry.outputMode);
  if (entry.status === 'recoveryAvailable') {
    lines.push('明细: 已丢失（这条记录是按原图备份重建出来的）');
  } else {
    lines.push('原始大小: ' + formatBytes(entry.originalSize) + ' (' + entry.originalSize + ' bytes)');
    lines.push('压缩后大小: ' + formatBytes(entry.compressedSize) + ' (' + entry.compressedSize + ' bytes)');
    lines.push('压缩率: ' + (entry.savings >= 0 ? '-' : '+') + Math.abs(entry.savings).toFixed(1) + '%');
    lines.push('输出格式: ' + (entry.outType || '(未知)'));
    lines.push('算法: ' + (entry.algorithm || '(未知)'));
  }
  lines.push('');
  lines.push('--- 原图备份 ---');
  lines.push(entry.backupPath || '(无)');
  copyTextToClipboard(lines.join('\n'));
  showToast('压缩日志已复制到剪贴板');
}

function historyRow(entry) {
  var row = document.createElement('div');
  var isRecovery = entry.status === 'recoveryAvailable';
  row.className = 'history-item'
    + (entry.status === 'restored' || isRecovery ? ' restored' : '');

  var icon = document.createElement('span');
  icon.className = 'history-icon';
  icon.innerHTML = iconMarkup(
    isRecovery ? 'warning' : (entry.status === 'restored' ? 'restore' : 'check'),
    true);

  var main = document.createElement('span');
  main.className = 'history-main';
  var name = document.createElement('span');
  name.className = 'history-name';
  name.textContent = entry.fileName;
  name.title = entry.sourcePath;
  var sub = document.createElement('span');
  sub.className = 'history-sub';
  sub.textContent = dirname(entry.sourcePath) + ' · ' + historyStatusText(entry);
  main.appendChild(name);
  main.appendChild(sub);

  var metrics = document.createElement('span');
  metrics.className = 'history-metrics';
  var sizes = document.createElement('span');
  sizes.textContent = formatBytes(entry.originalSize) + ' → ' + formatBytes(entry.compressedSize);
  var saving = document.createElement('span');
  // 重建条目没有这次压缩的明细，报一个算出来的 0.0% 节省率是假数字。
  saving.textContent = isRecovery ? '明细已丢失' : '节省 ' + Math.abs(entry.savings).toFixed(1) + '%';
  metrics.appendChild(sizes);
  metrics.appendChild(saving);

  var when = document.createElement('span');
  when.className = 'history-when';
  var created = document.createElement('span');
  created.textContent = historyTime(entry.createdAt);
  var algo = document.createElement('span');
  algo.textContent = isRecovery ? '按备份重建' : (entry.algorithm || entry.outType || '');
  when.appendChild(created);
  when.appendChild(algo);

  var actions = document.createElement('span');
  actions.className = 'history-actions';
  historyRowActionDefs(entry).forEach(function(def) {
    var btn = document.createElement('button');
    btn.className = 'queue-action-btn';
    btn.type = 'button';
    btn.title = def.title;
    btn.dataset.historyAction = def.action;
    btn.innerHTML = iconMarkup(def.icon, true);
    btn.addEventListener('click', function() { runHistoryAction(entry, def.action); });
    actions.appendChild(btn);
  });

  row.appendChild(icon);
  row.appendChild(main);
  row.appendChild(metrics);
  row.appendChild(when);
  row.appendChild(actions);
  return row;
}

/// 历史页那一行按下去要做的事。恢复和「删除这次压缩结果」共用 restore_history_entry
/// 这一个服务：后端按 outputMode 决定是写回原图还是删掉产物，前端不自己判断文件该怎么动。
function runHistoryAction(entry, action) {
  if (action === 'save') { saveHistoryOutput(entry); return; }
  if (action === 'compare') { openCompareFromHistory(entry); return; }
  if (action === 'restore') { restoreFromHistory(entry); return; }
  if (action === 'deleteOutput') { deleteHistoryOutput(entry); return; }
  if (action === 'log') { copyHistoryLog(entry); return; }
  var target = entry.outputExists ? (entry.outputPath || entry.sourcePath) : entry.sourcePath;
  invoke('open_in_finder', { filePath: target }).catch(function() {});
}

function renderHistory() {
  var list = document.getElementById('historyList');
  if (!list) return;
  list.innerHTML = '';
  historyEntries.forEach(function(entry) { list.appendChild(historyRow(entry)); });
  var empty = document.getElementById('historyEmpty');
  if (empty) empty.hidden = historyEntries.length > 0;
  var meta = document.getElementById('historyMeta');
  if (meta) meta.textContent = historyEntries.length + ' 条';
  // 后端在批次/事务进行中会拒绝清空，这里提前收成不可点，别让用户撞上报错。
  var clearBtn = document.getElementById('historyClearBtn');
  if (clearBtn) {
    clearBtn.disabled = isCompressing;
    clearBtn.title = isCompressing ? '压缩进行中，这一批结束后才能清空历史' : '清空历史记录';
  }
}

async function refreshHistory() {
  try {
    historyEntries = await invoke('list_history');
  } catch (error) {
    console.error('History load failed:', error);
    historyEntries = [];
    showToast('读取历史记录失败');
  }
  renderHistory();
}

function refreshHistoryIfOpen() {
  if (currentView === 'history') refreshHistory();
}

async function restoreFromHistory(entry, force) {
  var outcome;
  try {
    outcome = await invoke('restore_history_entry', { historyId: entry.id, force: !!force });
  } catch (error) {
    showToast('恢复失败: ' + (error.message || error));
    return;
  }
  if (outcome.conflict) {
    if (!confirm(RESTORE_CONFLICT_TEXT)) return;
    await restoreFromHistory(entry, true);
    return;
  }
  if (!outcome.success) {
    showToast(outcome.error || '恢复失败');
    return;
  }
  // 非 replace 模式的原图从没被盖过，后端做的是"删掉这次的压缩产物" ——
  // 报「已恢复原图」等于把一件没发生过的事说给用户听。
  showToast(entry.outputMode === 'replace'
    ? '已恢复原图: ' + basename(entry.fileName)
    : '已删除这次压缩结果: ' + basename(entry.fileName));
  afterRestore(outcome.filePath || entry.sourcePath);
}

async function clearHistory() {
  if (historyEntries.length === 0) return;
  // 按钮通常已被收成不可点；这里兜住"渲染时机没赶上"的那一次点击。
  if (isCompressing) {
    showToast('压缩进行中，这一批结束后才能清空历史');
    return;
  }
  // 清空就是手动到期：备份立刻删掉、不必等保留期。要数清楚这一次带走几份，
  // 也要说清楚"不会删除你的任何图片文件"——那是事实，不是安抚。
  var pendingBackups = historyEntries.filter(function(e) { return e.backupExists; }).length;
  var question = '确定要清空 ' + historyEntries.length + ' 条历史记录吗？\n';
  question += pendingBackups > 0
    ? '同时立即删除 OctoShrink 保存的 ' + pendingBackups + ' 份原图备份，不必等保留期到期。不会删除你的任何图片文件。'
    : 'OctoShrink 目前没有保存原图备份，这次只清记录。不会删除你的任何图片文件。';
  if (!confirm(question)) return;
  try {
    var removed = await invoke('clear_history');
    showToast('已清空 ' + removed + ' 条历史记录');
  } catch (error) {
    showToast('清空失败: ' + (error.message || error));
    return;
  }
  await refreshHistory();
}

// ─── 设置页：原图备份保留时间 ───────────────────────────────────
async function loadRetentionSetting() {
  try {
    var settings = await invoke('get_app_settings');
    // 0 是真实档位（不保留），不能用真值判断，否则会被当成"没设置"回落成 3 天。
    if (settings && settings.originalRetentionDays != null) {
      retentionDays = settings.originalRetentionDays;
    }
    applyRetentionSetting();
  } catch (error) {
    console.error('Settings load failed:', error);
  }
}

async function saveRetentionDays(days) {
  try {
    var settings = await invoke('set_original_retention_days', { days: days });
    retentionDays = settings.originalRetentionDays;
    showToast(retentionDays === 0
      ? '原图备份改为不保留，关闭应用时清理记录和备份'
      : '原图备份保留 ' + retentionDays + ' 天，关闭应用时清理过期项');
  } catch (error) {
    showToast('设置失败: ' + (error.message || error));
  }
  // 失败也要回到 retentionDays 那份真值，不能把选错的档位停在半路上。
  applyRetentionSetting();
}

// 「不保留」不是"关掉备份"：覆盖前照旧备份，只是寿命到本次退出为止。
// 清理只有一个时机 —— 关闭应用，所以文案不许再承诺"下次启动"。
// 文案必须把这件事说清楚，也不能写成吓人的措辞。
function applyRetentionSetting() {
  var select = document.getElementById('retentionDays');
  if (select) select.value = String(retentionDays);
  var copy = document.getElementById('retentionCopy');
  if (copy) {
    copy.textContent = retentionDays === 0
      ? '本次运行的压缩记录和原图备份都会在关闭应用时清理；期间可以随时恢复原图。'
      : '过期的历史记录和原图备份将在关闭应用时自动清理。';
  }
}

(function wireRetentionSelect() {
  var select = document.getElementById('retentionDays');
  if (!select) return;
  select.addEventListener('change', function() {
    var days = parseInt(select.value, 10);
    // || 3 会把"不保留"吞成 3 天 —— 0 必须原样传下去。
    saveRetentionDays(Number.isNaN(days) ? 0 : days);
  });
})();

// ─── 设置页：CPU 使用上限 ───────────────────────────────────────
// 后端负责检测与 clamp（含"换到核更少的机器"），前端只呈现与回传用户选择。

function cpuArchitectureLabel(architecture) {
  return architecture === 'aarch64' ? 'ARM64' : (architecture || '');
}

function cpuDeviceText(status) {
  if (!status) return '检测中…';
  return [status.modelName, cpuArchitectureLabel(status.architecture)]
    .filter(function(part) { return !!part; }).join(' · ');
}

// 核心构成。Apple Silicon 才报 P/E 核，其他平台不能假装知道。
function cpuCoreText(status) {
  if (!status) return '';
  var ceiling = Math.max(1, status.availableParallelism || 1);
  if (status.appleSilicon && status.performanceCpus && status.efficiencyCpus) {
    return (status.physicalCpus || ceiling) + ' 核 CPU（'
      + status.performanceCpus + ' 性能核 + ' + status.efficiencyCpus + ' 能效核）';
  }
  if (status.physicalCpus && status.logicalCpus > status.physicalCpus) {
    return status.physicalCpus + ' 个物理核心 · ' + status.logicalCpus + ' 个逻辑处理器';
  }
  if (status.logicalCpus) return status.logicalCpus + ' 个逻辑处理器';
  return '最多 ' + ceiling + ' 份并行计算';
}

function cpuSliderLabel() {
  var ceiling = cpuCeiling();
  if (!cpuStatus) return '';
  var configured = cpuStatus.configuredLimit;
  var limit = Math.min(Math.max(1, cpuStatus.effectiveLimit || 1), ceiling);
  if (configured === null || configured === undefined) return '自动（' + limit + '）';
  return limit + ' / ' + ceiling + (limit >= ceiling ? '（全部）' : '');
}

function renderCpuSetting(status) {
  if (status) cpuStatus = status;
  var device = document.getElementById('cpuDevice');
  if (device) device.textContent = cpuDeviceText(cpuStatus);
  var cores = document.getElementById('cpuCoreInfo');
  if (cores) cores.textContent = cpuCoreText(cpuStatus);
  // 「系统会自动在性能核与能效核之间调度任务」只对大小核架构成立。
  var note = document.getElementById('cpuSchedulingNote');
  if (note) note.style.display = cpuStatus && cpuStatus.appleSilicon ? '' : 'none';
  var slider = document.getElementById('cpuLimitSlider');
  if (slider && cpuStatus) {
    var ceiling = cpuCeiling();
    slider.min = '1';
    slider.max = String(ceiling);
    slider.disabled = ceiling <= 1;
    var configured = cpuStatus.configuredLimit;
    slider.value = String(Math.min(Math.max(1,
      configured == null ? cpuStatus.effectiveLimit : configured), ceiling));
  }
  var label = document.getElementById('cpuLimitValue');
  if (label) label.textContent = cpuSliderLabel();
  var autoBtn = document.getElementById('cpuLimitAuto');
  if (autoBtn) {
    var isAuto = !cpuStatus || cpuStatus.configuredLimit == null;
    autoBtn.classList.toggle('active', isAuto);
    autoBtn.disabled = isAuto;
  }
}

async function loadCpuSetting() {
  try {
    renderCpuSetting(await invoke('get_cpu_info'));
  } catch (error) {
    console.error('CPU info load failed:', error);
  }
}

async function saveCpuThreadLimit(limit) {
  try {
    renderCpuSetting(await invoke('set_cpu_thread_limit', { limit: limit }));
    updateQueueSummary();
    showToast(limit == null
      ? 'CPU 上限改为自动（' + cpuStatus.effectiveLimit + '）'
      : 'CPU 上限改为 ' + cpuStatus.effectiveLimit + ' / ' + cpuCeiling());
  } catch (error) {
    showToast('设置失败: ' + (error.message || error));
    // 失败就回到后端那份真值，不能把预览值留在滑杆上骗用户。
    await loadCpuSetting();
  }
}

(function wireCpuLimitControls() {
  var slider = document.getElementById('cpuLimitSlider');
  if (slider) {
    slider.addEventListener('input', function() {
      // 拖动过程中只改本地预览，松手（change）才写盘 + 下发给调度器。
      if (!cpuStatus) return;
      var picked = Math.min(Math.max(1, parseInt(slider.value, 10) || 1), cpuCeiling());
      cpuStatus = Object.assign({}, cpuStatus, { configuredLimit: picked, effectiveLimit: picked });
      var label = document.getElementById('cpuLimitValue');
      if (label) label.textContent = cpuSliderLabel();
      var autoBtn = document.getElementById('cpuLimitAuto');
      if (autoBtn) { autoBtn.classList.toggle('active', false); autoBtn.disabled = false; }
    });
    slider.addEventListener('change', function() {
      saveCpuThreadLimit(parseInt(slider.value, 10));
    });
  }
  var autoBtn = document.getElementById('cpuLimitAuto');
  if (autoBtn) autoBtn.addEventListener('click', function() { saveCpuThreadLimit(null); });
})();

// ─── Comparison（独立原生窗口）─────────────────────────────────
// 对比视图已迁移到独立窗口 compare.html + compare_window.js：
// 可自由缩放（可大于主窗口）、拥有自己的红绿灯，避免误关主窗口。
// 本侧只负责组装载荷、打开/聚焦窗口，并把结果集变化推送给该窗口。

function comparableResults() {
  return queueResults().filter(function(r) { return r && r.success; });
}

function openCompare(result) {
  const okResults = comparableResults();
  if (!okResults.length) {
    showToast('没有可对比的结果');
    return;
  }
  let index = okResults.findIndex(function(r) { return r.file === result.file; });
  if (index < 0) index = 0;
  invoke('open_compare_window', { payload: { results: okResults, index: index } })
    .catch(function(err) {
      showToast('打开对比窗口失败: ' + (err.message || err));
    });
}

function openCompareByFile(filePath) {
  const item = queueItems.get(filePath);
  if (item && item.result) openCompare(item.result);
}

// 结果集变化（恢复/清空/压缩完成等）时推送快照，对比窗口据此刷新或置空
function emitCompareResultsChanged() {
  try {
    window.__TAURI__.event.emit('compare-results-changed', { results: comparableResults() });
  } catch (_) {}
}

listen('compare-recompressed', function(event) {
  const payload = event.payload || {};
  const updated = payload.result;
  if (!payload.filePath || !updated) return;
  const item = queueItems.get(payload.filePath);
  if (!item || !item.result) return;
  const existing = item.result;
  item.result = Object.assign({}, existing, updated, {
    // compress_single writes a temporary preview. Keep the real output
    // and backup metadata so Restore still targets the original result.
    outputPath: existing.outputPath,
    backupPath: existing.backupPath,
    outputMode: existing.outputMode,
  });
});

listen('compare-restored', function(event) {
  const filePath = event.payload && event.payload.filePath;
  if (!filePath) return;
  afterRestore(filePath);
  showToast('已恢复原图: ' + basename(filePath));
});

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  var systemInfoPanel = document.getElementById('systemInfoPanel');
  if (systemInfoPanel && systemInfoPanel.style.display !== 'none') {
    closeSystemConversionInfo();
    return;
  }
  // Esc = 离开历史/设置页，回到主视图；压缩任务不受影响。
  if (currentView !== 'main') showView('main');
});

function showToast(message) {
  const existing = document.querySelector('.toast');
  if (existing) existing.remove();

  const toast = document.createElement('div');
  toast.className = 'toast';
  toast.textContent = message;
  document.body.appendChild(toast);

  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transition = 'opacity 0.3s';
    setTimeout(() => toast.remove(), 300);
  }, 2500);
}

function toggleTitlebarInfo() {
  var info = document.getElementById('titlebarInfo');
  if (!info) return;
  var open = info.style.display !== 'none';
  if (open) {
    info.style.display = 'none';
    return;
  }
  info.style.display = 'inline-flex';
  var ver = document.getElementById('titlebarInfoVersion');
  if (ver) ver.textContent = 'v' + (window.appVersion || '2.0.0') + ' ' + BUILD_VARIANT;
}

/// 更新面板在设置页里，但启动时的静默检查可能先于用户进设置页就发现了新版本，
/// 所以元素一律先按产物线摆好，谁先来谁写。
/// App Store 版不加载 updater 插件 —— 那一行直接不出现，改说一句实话，
/// 而不是留一个按下去只会失败的按钮。
function initUpdatePanel() {
  var version = document.getElementById('updateVersion');
  // 版本号是异步取的：没取到之前宁可留 HTML 里的「—」，别显示半截「 Direct」。
  if (version && window.appVersion) version.textContent = 'v' + window.appVersion + ' ' + BUILD_VARIANT;
  var isDirect = BUILD_VARIANT === 'Direct';
  var checkRow = document.getElementById('updateCheckRow');
  var directNote = document.getElementById('updateDirectNote');
  var appStoreNote = document.getElementById('updateAppStoreNote');
  if (checkRow) checkRow.style.display = isDirect ? '' : 'none';
  if (directNote) directNote.style.display = isDirect ? '' : 'none';
  if (appStoreNote) appStoreNote.style.display = isDirect ? 'none' : '';
}

function getUpdateStatusEl() {
  return document.getElementById('updateStatus');
}

async function manualCheckUpdate() {
  var btn = document.getElementById('updateCheckBtn');
  if (!btn || btn.dataset.downloading === '1') return;
  var statusEl = getUpdateStatusEl();
  btn.disabled = true;
  btn.textContent = '检查中';
  if (statusEl) { statusEl.textContent = ''; statusEl.classList.remove('has-update'); }
  try {
    const update = await invoke('check_for_update');
    if (update) {
      btn.textContent = '立即更新';
      btn.disabled = false;
      if (statusEl) { statusEl.textContent = 'v' + update.version + ' 可用'; statusEl.classList.add('has-update'); }
      btn.onclick = function() { startUpdateDownload(btn, statusEl, update.version); };
    } else {
      btn.textContent = '检查更新';
      btn.disabled = false;
      if (statusEl) statusEl.textContent = '已是最新版本';
    }
  } catch (error) {
    btn.textContent = '检查更新';
    btn.disabled = false;
    if (statusEl) statusEl.textContent = '检查失败';
  }
}

function startUpdateDownload(btn, statusEl, version) {
  btn.dataset.downloading = '1';
  var row = document.getElementById('updateDownloadRow');
  var text = document.getElementById('updateProgressText');
  var fill = document.getElementById('updateProgressFill');
  // 标题栏那根窗口级进度条照旧推：下载中途切回队列页也看得见动静。
  var tbBar = document.getElementById('titlebarProgress');
  if (row) row.style.display = '';
  if (fill) fill.style.width = '0%';
  if (tbBar) tbBar.style.width = '0%';
  if (text) text.textContent = '下载中 0%';
  if (statusEl) statusEl.textContent = '';
  btn.disabled = true;

  var unlistenFn = null;
  listen('update-progress', function(event) {
    var pct = event.payload || 0;
    if (tbBar) tbBar.style.width = pct + '%';
    if (fill) fill.style.width = pct + '%';
    if (text) text.textContent = '下载中 ' + pct + '%';
  }).then(function(fn) { unlistenFn = fn; });

  invoke('install_update')
    .then(function() {
      if (text) text.textContent = '安装中…';
      if (fill) fill.style.width = '100%';
      if (tbBar) tbBar.style.width = '100%';
    })
    .catch(function(err) {
      if (unlistenFn) unlistenFn();
      if (btn.dataset.downloading !== '1') return;
      btn.dataset.downloading = '';
      endUpdateDownload();
      btn.disabled = false;
      btn.textContent = '立即更新';
      var cancelled = String(err).indexOf('取消') >= 0;
      if (statusEl) statusEl.textContent = cancelled ? 'v' + version + ' 可用' : '更新失败';
    });
}

/// 下载停下来了（取消、失败都算）：面板那一行收起来，窗口进度条归零。
/// 成功安装时不调用它 —— 那一刻界面正等着被替换掉。
function endUpdateDownload() {
  var row = document.getElementById('updateDownloadRow');
  var fill = document.getElementById('updateProgressFill');
  var tbBar = document.getElementById('titlebarProgress');
  if (row) row.style.display = 'none';
  if (fill) fill.style.width = '0%';
  if (tbBar) tbBar.style.width = '0%';
}

function cancelUpdateDownload() {
  invoke('cancel_update').catch(function(){});
  endUpdateDownload();
  var btn = document.getElementById('updateCheckBtn');
  var statusEl = getUpdateStatusEl();
  if (btn && btn.dataset.downloading === '1') {
    btn.dataset.downloading = '';
    btn.disabled = false;
    btn.textContent = '立即更新';
    if (statusEl) statusEl.textContent = '已取消';
  }
}

async function checkDirectUpdate() {
  if (BUILD_VARIANT !== 'Direct' || window.updateCheckStarted) return;
  window.updateCheckStarted = true;
  try {
    const update = await invoke('check_for_update');
    if (!update) return;
    var btn = document.getElementById('updateCheckBtn');
    if (btn) {
      var statusEl = getUpdateStatusEl();
      btn.textContent = '立即更新';
      if (statusEl) { statusEl.textContent = 'v' + update.version + ' 可用'; statusEl.classList.add('has-update'); }
      btn.onclick = function() { startUpdateDownload(btn, statusEl, update.version); };
    }
  } catch (error) {
    console.warn('在线更新检查失败:', error);
  }
}

function updateSettingsSummary() {
  var ac = document.getElementById('autoCompress');
  var q = document.getElementById('qualitySlider');
  var of = document.getElementById('outputFormat');
  var sm = document.getElementById('smartMode');
  var om = document.querySelector('input[name="outputMode"]:checked');
  var parts = [];
  if (ac && ac.checked) parts.push('自动');
  if (processingMode === 'system') {
    var systemFormatSelect = document.getElementById('systemOutputFormat');
    var systemSizeSelect = document.getElementById('systemImageSize');
    parts.push('系统');
    if (systemFormatSelect) parts.push(systemFormatSelect.options[systemFormatSelect.selectedIndex].text);
    if (systemSizeSelect) parts.push(systemSizeSelect.options[systemSizeSelect.selectedIndex].text.split('（')[0]);
  } else {
    if (q) parts.push('Q' + q.value);
    if (of) parts.push(of.value === 'original' ? '\u539f\u683c\u5f0f' : of.value.toUpperCase());
    if (sm) parts.push(sm.checked ? '\u667a\u80fd' : '\u6807\u51c6');
  }
  if (om) {
    parts.push(om.value === 'replace' ? '\u8986\u76d6' : (om.value === 'suffix' ? '\u540e\u7f00' : '\u76ee\u5f55'));
    if (om.value === 'suffix') parts.push(getOutputSuffix());
  }
  var el = document.getElementById('settingsSummary');
  if (el) el.textContent = parts.join(' \u00b7 ');
}

function resetSettings() {
  try { localStorage.removeItem('octoshrink-settings'); } catch(e) {}
  location.reload();
}

function saveCompressSettings() {
  var data = {};
  data.processingMode = processingMode;
  var systemFormatSelect = document.getElementById('systemOutputFormat');
  if (systemFormatSelect) data.systemOutputFormat = systemFormatSelect.value;
  var systemSizeSelect = document.getElementById('systemImageSize');
  if (systemSizeSelect) data.systemImageSize = systemSizeSelect.value;
  var preserveMetadataToggle = document.getElementById('preserveMetadata');
  if (preserveMetadataToggle) data.preserveMetadata = preserveMetadataToggle.checked;
  var q = document.getElementById('qualitySlider');
  if (q) data.quality = q.value;
  var of = document.getElementById('outputFormat');
  if (of) data.outputFormat = of.value;
  var cb = document.getElementById('compressionBackend');
  if (cb) data.backend = cb.value;
  var ce = document.getElementById('compressionEffort');
  if (ce) data.effort = ce.value;
  var ac = document.getElementById('autoCompress');
  if (ac) data.autoCompress = ac.checked;
  var sm = document.getElementById('smartMode');
  if (sm) data.smartMode = sm.checked;
  var cw = document.getElementById('convertToWebp');
  if (cw) data.convertToWebp = cw.checked;
  var om = document.querySelector('input[name="outputMode"]:checked');
  if (om) data.outputMode = om.value;
  if (outputSuffixInput) data.outputSuffix = outputSuffixInput.value;
  try { localStorage.setItem('octoshrink-settings', JSON.stringify(data)); } catch(e) {}
}

function loadCompressSettings() {
  var raw;
  try { raw = localStorage.getItem('octoshrink-settings'); } catch(e) { return; }
  if (!raw) return;
  var data;
  try { data = JSON.parse(raw); } catch(e) { return; }
  if (!data) return;
  if (data.systemOutputFormat != null) { var systemFormatSelect = document.getElementById('systemOutputFormat'); if (systemFormatSelect) systemFormatSelect.value = data.systemOutputFormat; }
  if (data.systemImageSize != null) { var systemSizeSelect = document.getElementById('systemImageSize'); if (systemSizeSelect) systemSizeSelect.value = data.systemImageSize; }
  if (data.preserveMetadata != null) { var preserveMetadataToggle = document.getElementById('preserveMetadata'); if (preserveMetadataToggle) preserveMetadataToggle.checked = data.preserveMetadata; }
  if (data.quality != null) { var q = document.getElementById('qualitySlider'); if (q) q.value = data.quality; }
  if (data.outputFormat != null) { var of = document.getElementById('outputFormat'); if (of) of.value = data.outputFormat; }
  if (data.backend != null) { var cb = document.getElementById('compressionBackend'); if (cb) cb.value = data.backend; }
  if (data.effort != null) { var ce = document.getElementById('compressionEffort'); if (ce) ce.value = data.effort; }
  if (data.autoCompress != null) { var ac = document.getElementById('autoCompress'); if (ac) ac.checked = data.autoCompress; }
  if (data.smartMode != null) { var sm = document.getElementById('smartMode'); if (sm) sm.checked = data.smartMode; }
  if (data.convertToWebp != null) { var cw = document.getElementById('convertToWebp'); if (cw) cw.checked = data.convertToWebp; }
  if (data.outputMode != null) { var om = document.querySelector('input[name="outputMode"][value="' + data.outputMode + '"]'); if (om) om.checked = true; }
  if (data.outputSuffix != null && outputSuffixInput) { outputSuffixInput.value = String(data.outputSuffix); }
  processingMode = data.processingMode === 'system' ? 'system' : 'advanced';
}

// Init
(function() {
  // 后端是阶段状态的权威：暂停 / 继续 / 停止的真实结果由它播报，
  // 前端点按钮时只是先乐观地画一遍（失败会回滚）。
  listen('compression-state-change', function(event) {
    applyCompressionStateEvent(event.payload);
  }).catch(function() {});
  loadCompressSettings();
  // 队列摘要里的「CPU 4/10」需要在进入设置页之前就拿到，所以启动即检测一次。
  loadCpuSetting().then(function() { updateQueueSummary(); }).catch(function() {});
  var modeSwitch = document.getElementById('processingModeSwitch');
  var isMac = /Macintosh|Mac OS X/.test(navigator.userAgent);
  if (modeSwitch && !isMac) modeSwitch.style.display = 'none';
  setProcessingMode(processingMode, true);
  updateOutputModeControls();
  var sp = document.getElementById('settingsPanel');
  if (sp) sp.style.display = 'block';
  ['autoCompress','qualitySlider','outputFormat','compressionBackend','compressionEffort','smartMode','convertToWebp','systemOutputFormat','systemImageSize','preserveMetadata','outputSuffix'].forEach(function(id){
    var el = document.getElementById(id);
    if (el) el.addEventListener('change', function(){ saveCompressSettings(); updateSettingsSummary(); });
  });
  if (outputSuffixInput) outputSuffixInput.addEventListener('input', function(){ saveCompressSettings(); updateSettingsSummary(); });
  document.querySelectorAll('input[name="outputMode"]').forEach(function(r){
    r.addEventListener('change', function(){ saveCompressSettings(); updateSettingsSummary(); });
  });
  updateSettingsSummary();
  updateQualitySlider();
  invoke('get_app_version').then(v => {
    window.appVersion = v;
    initUpdatePanel();
    setTimeout(checkDirectUpdate, 1500);
  }).catch(() => {});
})();
