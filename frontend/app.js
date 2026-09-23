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
let files = [];
let inputPaths = [];
let results = [];
let isCompressing = false;
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

    // A removed row is only visual history. Re-adding the path creates a
    // fresh waiting row instead of resurrecting the old cancelled state.
    var oldRow = fileRows[filePath];
    if (oldRow && oldRow.classList.contains('cancelled')) {
      oldRow.remove();
      delete fileRows[filePath];
    }

    known.add(filePath);
    files.push(filePath);
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
var cancelledFiles = new Set();
var queueSortDescending = false;
var pendingImports = Promise.resolve();
var queueRevision = 0;
var activeBatchPaths = [];
var activeBatchSet = new Set();
var activeBatchRows = new Map();
var activeBatchRevision = 0;
var startButtonTimer = null;

function updateQueueSummary() {
  var summary = document.getElementById('queueSummary');
  if (!summary) return;
  var queued = new Set(files);
  var completed = new Set(results.filter(function(result) {
    return result && queued.has(result.file);
  }).map(function(result) { return result.file; }));
  if (isCompressing || completed.size > 0) {
    summary.textContent = completed.size + ' / ' + queued.size + ' 已完成'
      + (isCompressing && compressionPaused ? ' · 已暂停' : '')
      + cpuLimitText();
  } else {
    summary.textContent = files.length + ' 个文件';
  }
  updateBulkActionButtons();
  applyQueueView();
}

function updateBulkActionButtons() {
  var restoreBtn = document.getElementById('restoreAllBtn');
  if (!restoreBtn) return;
  var hasRestorable = results.some(function(r) { return r && r.success; });
  restoreBtn.style.display = hasRestorable ? 'inline-flex' : 'none';
}

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
  var byFile = new Map(results.map(function(result) { return [result.file, result]; }));
  var states = ['failed', 'compressing', 'waiting', 'done', 'restored', 'cancelled'];
  var entries = files.map(function(file, index) {
    var row = fileRows[file];
    var result = byFile.get(file);
    var value = index;
    if (key === 'name') value = basename(file);
    if (key === 'original') value = result ? result.originalSize : row && row.originalSize;
    if (key === 'compressed') value = result && result.success ? result.compressedSize : null;
    if (key === 'ratio') value = result && result.success ? result.savings : null;
    if (key === 'status') value = states.findIndex(function(state) { return row && row.classList.contains(state); });
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
    if (!files.includes(file)) fileRows[file].hidden = failedOnly;
  });
  entries.forEach(function(entry, index) {
    if (!entry.row) return;
    entry.row.hidden = failedOnly && !entry.row.classList.contains('failed');
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
        var row = fileRows[newFiles[j]];
        if (row && sizes[j] !== undefined) row.originalSize = sizes[j];
        if (row && sizes[j] !== undefined && row.classList.contains('waiting')) {
          var sizeEl = row.querySelector('.queue-item-size');
          if (sizeEl) sizeEl.textContent = formatBytes(sizes[j]);
        }
      }
    } catch (e) { /* ignore */ }
    applyQueueView();
  }
}

function createQueueRow(filePath) {
  var row = document.createElement('div');
  row.className = 'file-queue-item waiting';
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
    if (row.classList.contains('waiting')) {
      if (isCompressing) {
        cancelledFiles.add(filePath);
        invoke('cancel_file', { filePath: filePath }).catch(function() {});
      }
      var idx = files.indexOf(filePath);
      if (idx >= 0) files.splice(idx, 1);
      row.classList.remove('waiting');
      row.classList.add('cancelled');
      row.querySelector('.queue-item-icon').innerHTML = iconMarkup('minus', true);
      row.querySelector('.queue-item-status').textContent = '已移除';
      row.querySelector('.queue-item-remove').style.display = 'none';
      if (!isCompressing) {
        updateQueueSummary();
      } else {
        updateQueueSummary();
      }
    }
  });
  return row;
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

  // Keep the active invocation alive until the backend returns. Marking the
  // UI idle here would allow a second batch to overlap the first one.
  var wasCompressing = isCompressing;
  queueRevision++;
  if (wasCompressing) {
    activeBatchPaths.forEach(function(filePath) { cancelledFiles.add(filePath); });
    // 一次调用取消整批：逐个 invoke 会让每个请求都顺手动一次暂停闸门，
    // 队列会在清空过程中被重新放行。
    invoke('cancel_batch', { filePaths: activeBatchPaths }).catch(function() {});
  }

  files = [];
  inputPaths = [];
  results = [];
  fileRows = {};
  if (!wasCompressing) cancelledFiles.clear();
  pendingAutoCompress = false;
  if (!wasCompressing) {
    activeBatchPaths = [];
    activeBatchSet.clear();
    activeBatchRows.clear();
    activeBatchRevision = 0;
  }
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
async function startCompression(isIncrement) {
  return startCompressionForPaths(isIncrement, null);
}

function getPendingQueuePaths(candidatePaths) {
  var done = new Set(results.map(function(result) { return result && result.file; }));
  var seen = new Set();
  return uniqueFilePaths(candidatePaths).filter(function(filePath) {
    if (seen.has(filePath) || done.has(filePath) || !files.includes(filePath)) return false;
    seen.add(filePath);
    return true;
  });
}

async function startCompressionForPaths(isIncrement, requestedPaths) {
  if (isCompressing) return;
  var candidates = Array.isArray(requestedPaths) ? requestedPaths.slice() : files.slice();
  if (candidates.length === 0) return;

  isCompressing = true;
  var runRevision = queueRevision;
  if (startButtonTimer) {
    clearTimeout(startButtonTimer);
    startButtonTimer = null;
  }

  var hasOutputAccess = false;
  try {
    hasOutputAccess = await ensureSystemOutputAccess();
  } catch (error) {
    console.error('Output access check failed:', error);
    showToast('无法确认输出目录，请重试');
  }
  if (!hasOutputAccess) {
    isCompressing = false;
    updateQueueSummary();
    return;
  }
  if (runRevision !== queueRevision) {
    isCompressing = false;
    updateQueueSummary();
    return;
  }

  isCompressing = true;
  currentCompressOptions = null;

  const config = getCurrentCompressionConfig();
  if (config.error) {
    showToast(config.error);
    isCompressing = false;
    updateQueueSummary();
    return;
  }

  var batchPaths = getPendingQueuePaths(candidates);
  if (batchPaths.length === 0) {
    isCompressing = false;
    updateQueueSummary();
    return;
  }

  var batchOptions = config.options;
  currentCompressOptions = batchOptions;
  activeBatchPaths = batchPaths.slice();
  activeBatchSet = new Set(batchPaths);
  activeBatchRows = new Map(batchPaths.map(function(filePath) {
    return [filePath, fileRows[filePath]];
  }));
  activeBatchRevision = runRevision;
  var batchSettled = new Set();

  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'flex';
  updateStats();

  cancelledFiles.clear();
  updateQueueSummary();

  var startBtn = document.getElementById('startCompressBtn');
  if (startBtn) {
    startBtn.disabled = true;
    startBtn.classList.remove('done');
    startBtn.classList.add('compressing');
    var btnText = document.getElementById('compressBtnText');
    if (btnText) btnText.innerHTML = '<span class="progress-file-spinner"></span> ' + processingActionText('progress');
  }
  compressionPaused = false;
  setPauseButtonVisible(true);
  renderPauseControls();

  renderFileQueue();

  // Progress handler - updates existing rows in place
  const progressHandler = (data) => {
    if (runRevision !== queueRevision || activeBatchRevision !== runRevision) return;
    var file = data.file, result = data.result, status = data.status;
    if (!activeBatchSet.has(file)) return;
    var row = fileRows[file];
    // A row can be removed and re-added while the backend is still working.
    // Only the row captured for this batch may consume its late events.
    if (!row || !files.includes(file) || row.classList.contains('cancelled') || activeBatchRows.get(file) !== row) return;

    if (status === 'starting' && row) {
      row.classList.remove('waiting');
      row.classList.add('compressing');
      row.querySelector('.queue-item-icon').innerHTML = '<span class="progress-file-spinner"></span>';
      row.querySelector('.queue-item-status').textContent = processingActionText('progress');
      var rmBtn = row.querySelector('.queue-item-remove');
      if (rmBtn) rmBtn.style.display = 'none';
      applyQueueView();
    }

    if (result && !batchSettled.has(result.file)) {
      batchSettled.add(result.file);
      if (!row) return;
      row.classList.remove('compressing');
      row.classList.add(result.success ? 'done' : 'failed');
      row.querySelector('.queue-item-icon').innerHTML = iconMarkup(result.success ? 'check' : 'error', true);
      var rmBtnDone = row.querySelector('.queue-item-remove');
      if (rmBtnDone) rmBtnDone.style.display = 'none';
      var sizeEl = row.querySelector('.queue-item-size');
      if (result.success && sizeEl) {
        sizeEl.textContent = formatBytes(result.originalSize) + ' → ' + formatBytes(result.compressedSize);
      }
      var savingsText = result.success
        ? (result.savings >= 0 ? '-' : '+') + Math.abs(result.savings).toFixed(1) + '%'
        : '失败';
      row.querySelector('.queue-item-status').textContent = savingsText;
      // 如果有错误信息，添加警告图标
      if (result.error) {
        var statusEl = row.querySelector('.queue-item-status');
        var errIcon = document.createElement('span');
        errIcon.className = 'error-info-btn';
        errIcon.title = result.error;
        errIcon.innerHTML = iconMarkup('warning', true);
        errIcon.onclick = function(e) { e.stopPropagation(); showErrorDetail(result.file, result.error); };
        statusEl.appendChild(errIcon);
      }
      result.compressOptions = batchOptions;
      results = results.filter(function(existing) { return existing.file !== result.file; });
      results.push(result);
      renderQueueResultActions(row, result);
      updateStats();
      updateQueueSummary();
      emitCompareResultsChanged();
    }

    if (status === 'cancelled' && row && !batchSettled.has(file)) {
      batchSettled.add(file);
      row.classList.add('cancelled');
      row.querySelector('.queue-item-icon').innerHTML = iconMarkup('minus', true);
      row.querySelector('.queue-item-status').textContent = '已跳过';
      updateQueueSummary();
    }
  };

  var unlisten = function() {};

  try {
    unlisten = await listen('compress-progress', function(event) {
      progressHandler(event.payload);
    });
    var backendResults = await invoke(config.useSmartIpc ? 'compress_smart' : 'compress_files', {
      filePaths: batchPaths,
      options: batchOptions,
    });
    // The event is the live path, while the return value is a recovery path
    // for a backend that completed without delivering one of its events.
    if (Array.isArray(backendResults)) {
      backendResults.forEach(function(result) {
        progressHandler({ file: result.file, status: '', result: result });
      });
    }
    if (runRevision === queueRevision) {
      updateStats();
      showResults();
    }
  } catch (err) {
    console.error('Compression error:', err);
    showToast((processingMode === 'system' ? '转换出错: ' : '压缩出错: ') + (err.message || err));
  } finally {
    try { unlisten(); } catch (e) {}
    if (activeBatchRevision === runRevision) {
      activeBatchPaths = [];
      activeBatchSet.clear();
      activeBatchRows.clear();
      activeBatchRevision = 0;
    }
    isCompressing = false;
    cancelledFiles.clear();
    compressionPaused = false;
    setPauseButtonVisible(false);
    if (startBtn) {
      startBtn.classList.remove('compressing');
      startBtn.classList.add('done');
      var btnText = document.getElementById('compressBtnText');
      if (btnText) btnText.innerHTML = '<svg class="symbol-icon"><use href="#icon-check"/></svg> ' + processingActionText('done');
      startButtonTimer = setTimeout(function() {
        startButtonTimer = null;
        startBtn.classList.remove('done');
        startBtn.disabled = false;
        if (btnText) btnText.innerHTML = '<svg class="symbol-icon"><use href="#icon-compress"/></svg> ' + processingActionText('idle');
      }, 2000);
    }
    var shouldContinue = pendingAutoCompress && getPendingQueuePaths(files).length > 0;
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

  for (const r of results) {
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

async function compressOneFile(filePath) {
  if (isCompressing) return;
  const row = fileRows[filePath];
  if (!row) return;
  results = results.filter(function(r) { return r.file !== filePath; });
  emitCompareResultsChanged();

  row.classList.remove('waiting', 'done', 'failed', 'restored', 'cancelled');
  row.classList.add('compressing');
  row.querySelector('.queue-item-icon').innerHTML = '<span class="progress-file-spinner"></span>';
  row.querySelector('.queue-item-status').textContent = '压缩中…';
  var actions = row.querySelector('.queue-item-actions');
  if (actions) actions.innerHTML = '';
  var rmBtn = row.querySelector('.queue-item-remove');
  if (rmBtn) rmBtn.style.display = 'none';
  await startCompressionForPaths(true, [filePath]);
  if (results.some(function(result) { return result.file === filePath && result.success; })) {
    showToast('已重新压缩: ' + basename(filePath));
  }
}

async function saveResult(filePath) {
  const result = results.find(r => r.file === filePath);
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
  const result = results.find(r => r.file === filePath);
  const target = (result && result.outputPath) ? result.outputPath : filePath;
  invoke('open_in_finder', { filePath: target });
}

// 压缩后又用别的 App 改过图：恢复会覆盖那个新版本，必须先问。
var RESTORE_CONFLICT_TEXT = '这个文件在压缩后又被修改过。\n恢复原图会覆盖当前版本。';

/// 恢复成功后的统一收尾：主队列、历史页、对比窗口都只走这里。
/// skipRefresh 供批量恢复使用，避免每个文件重绘一次结果列表。
function afterRestore(filePath, skipRefresh) {
  results = results.filter(function(r) { return r.file !== filePath; });
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
  var mode = outcome.outputMode
    || (results.find(function(r) { return r.file === filePath; }) || {}).outputMode;
  showToast(mode === 'replace'
    ? '已恢复原图: ' + basename(filePath)
    : '已删除这次压缩结果: ' + basename(filePath));
  afterRestore(outcome.filePath || filePath);
}

function markQueueRowRestored(filePath) {
  var row = fileRows[filePath];
  if (!row) return;
  row.classList.remove('done', 'failed', 'compressing');
  row.classList.add('restored');
  var icon = row.querySelector('.queue-item-icon');
  if (icon) icon.innerHTML = iconMarkup('restore', true);
  var status = row.querySelector('.queue-item-status');
  if (status) status.textContent = '已恢复';
  renderRestoredActions(row, filePath);
}

async function restoreAllOriginals() {
  if (results.length === 0) return;
  if (!confirm('确定要恢复全部已压缩成功的原图吗？')) return;
  var outcome;
  try {
    outcome = await invoke('restore_all', { results: results.slice() });
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
  if (results.length === 0) return;
  const suffix = getResultOutputSuffix(results[0]);
  const count = await invoke('export_all', { results: results, outputSuffix: suffix });
  showToast('已导出 ' + count + ' 个文件到原目录（' + suffix + ' 后缀）');
}

function clearResults() {
  var wasCompressing = isCompressing;
  queueRevision++;
  if (wasCompressing) {
    activeBatchPaths.forEach(function(filePath) { cancelledFiles.add(filePath); });
    invoke('cancel_batch', { filePaths: activeBatchPaths }).catch(function() {});
  }
  results = [];
  files = [];
  inputPaths = [];
  fileRows = {};
  if (!wasCompressing) cancelledFiles.clear();
  pendingAutoCompress = false;
  if (!wasCompressing) {
    activeBatchPaths = [];
    activeBatchSet.clear();
    activeBatchRows.clear();
    activeBatchRevision = 0;
  }
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

// ─── 暂停 / 继续 ────────────────────────────────────────────────
// 暂停只挡住"还没开始"的文件；已经在跑的子进程自己跑完，绝不 kill。
var compressionPaused = false;

function pauseButtonText(paused) {
  return paused
    ? '<svg class="symbol-icon symbol-icon-small"><use href="#icon-play"/></svg> 继续'
    : '<svg class="symbol-icon symbol-icon-small"><use href="#icon-pause"/></svg> 暂停';
}

function renderPauseControls() {
  var btn = document.getElementById('pauseCompressBtn');
  var text = document.getElementById('pauseBtnText');
  if (text) text.innerHTML = pauseButtonText(compressionPaused);
  if (btn) btn.title = compressionPaused ? '继续压缩剩余文件' : '暂停：不再启动新文件';
  var btnText = document.getElementById('compressBtnText');
  if (btnText && isCompressing) {
    btnText.innerHTML = '<span class="progress-file-spinner"></span> '
      + (compressionPaused ? '暂停中…' : processingActionText('progress'));
  }
  updateQueueSummary();
}

function setPauseButtonVisible(visible) {
  var btn = document.getElementById('pauseCompressBtn');
  if (btn) btn.style.display = visible ? 'inline-flex' : 'none';
}

async function toggleCompressionPause() {
  var next = !compressionPaused;
  compressionPaused = next;
  renderPauseControls();
  try {
    await invoke(next ? 'pause_compression' : 'resume_compression');
  } catch (error) {
    console.error('Pause toggle failed:', error);
    compressionPaused = !next;
    renderPauseControls();
    showToast(next ? '暂停失败，请重试' : '继续失败，请重试');
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
  return results.filter(function(r) { return r && r.success; });
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
  const result = results.find(r => r.file === filePath);
  if (result) openCompare(result);
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
  const idx = results.findIndex(function(r) { return r.file === payload.filePath; });
  if (idx < 0) return;
  const existing = results[idx];
  results[idx] = Object.assign({}, existing, updated, {
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
