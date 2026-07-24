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

function applyTheme(theme) {
  currentTheme = theme;
  localStorage.setItem('octoshrink-theme', theme);

  const resolvedTheme = getResolvedTheme(theme);
  document.documentElement.setAttribute('data-theme-mode', theme);
  if (resolvedTheme === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
  } else {
    document.documentElement.setAttribute('data-theme', 'light');
  }

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
const comparePanel = document.getElementById('comparePanel');
const compareOriginalImg = document.getElementById('compareOriginalImg');
const compareCompressedImg = document.getElementById('compareCompressedImg');
const compareHandle = document.getElementById('compareHandle');
const compareFilename = document.getElementById('compareFilename');
const compareOriginalSize = document.getElementById('compareOriginalSize');
const compareCompressedSize = document.getElementById('compareCompressedSize');
const compareSavings = document.getElementById('compareSavings');
const compareAlgorithm = document.getElementById('compareAlgorithm');
let currentCompareResult = null;
let currentCompareZoom = 1;
const outputDirRow = document.getElementById('outputDirRow');

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

// Output mode radio
document.querySelectorAll('input[name="outputMode"]').forEach(radio => {
  radio.addEventListener('change', () => {
    outputDirRow.style.display = radio.value === 'folder' ? 'flex' : 'none';
  });
});

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
  const filePaths = await invoke('select_files');
  if (filePaths && filePaths.length > 0) {
    handleFilePaths(filePaths);
  }
}

async function selectFolder() {
  const folderPaths = await invoke('select_folder');
  if (folderPaths && folderPaths.length > 0) {
    handleFilePaths(folderPaths);
  }
}

async function selectOutputDir() {
  const dirs = await invoke('select_output_dir');
  if (dirs && dirs.length > 0) {
    outputDir = dirs[0];
    outputDirDisplay.textContent = outputDir;
    outputDirDisplay.title = outputDir;
  }
}

function handleFiles(fileList) {
  const filePaths = [];
  for (const file of fileList) {
    filePaths.push(file.path || file.name);
  }
  handleFilePaths(filePaths);
}

async function handleFilePaths(filePaths) {
  if (filePaths.length === 0) return;

  var rootSet = new Set(inputPaths);
  for (var i = 0; i < filePaths.length; i++) {
    if (!rootSet.has(filePaths[i])) {
      inputPaths.push(filePaths[i]);
      rootSet.add(filePaths[i]);
    }
  }

  var expanded = [];
  try {
    expanded = await invoke('expand_image_files', { filePaths: inputPaths });
  } catch (e) {
    expanded = filePaths;
  }

  if (!expanded || expanded.length === 0) {
    showToast('文件夹中没有找到可压缩的图片');
    return;
  }

  files = expanded;
  if (isCompressing) {
    totalFiles = files.length;
  }

  var queuePanel = document.getElementById('queuePanel');
  if (queuePanel) queuePanel.style.display = 'block';
  settingsPanel.style.display = 'block';
  resultsPanel.style.display = 'none';
  updateQueueSummary();
  renderFileQueue();
  document.querySelector('.container').scrollTop = 0;
  var ac = document.getElementById('autoCompress');
  if (ac && ac.checked && files.length > 0) {
    if (isCompressing) {
      pendingAutoCompress = true;
    } else {
      startCompression(false);
    }
  }
}

// Global state for compression
var fileRows = {};
var cancelledFiles = new Set();
var totalDone = 0;
var totalFiles = 0;
var queueWasEdited = false;

function updateQueueSummary() {
  var summary = document.getElementById('queueSummary');
  if (!summary) return;
  if (isCompressing) {
    summary.textContent = totalDone + ' / ' + totalFiles + ' 已完成';
  } else {
    summary.textContent = files.length + ' 个文件';
  }
  updateBulkActionButtons();
}

function updateBulkActionButtons() {
  var restoreBtn = document.getElementById('restoreAllBtn');
  if (!restoreBtn) return;
  var hasRestorable = results.some(function(r) { return r && r.success; });
  restoreBtn.style.display = hasRestorable ? 'inline-flex' : 'none';
}

async function renderFileQueue() {
  var list = document.getElementById('fileQueueList');
  if (!list) return;
  var newFiles = [];
  for (var i = 0; i < files.length; i++) {
    if (!fileRows[files[i]]) {
      var row = createQueueRow(files[i]);
      fileRows[files[i]] = row;
      list.appendChild(row);
      newFiles.push(files[i]);
    }
  }
  // Fetch file sizes for newly added rows only (preserve existing row state)
  if (newFiles.length > 0) {
    try {
      const sizes = await invoke('get_file_sizes', { filePaths: newFiles });
      for (var j = 0; j < newFiles.length; j++) {
        var row = fileRows[newFiles[j]];
        if (row && sizes[j] !== undefined) {
          var sizeEl = row.querySelector('.queue-item-size');
          if (sizeEl) sizeEl.textContent = formatBytes(sizes[j]);
        }
      }
    } catch (e) { /* ignore */ }
  }
}

function createQueueRow(filePath) {
  var row = document.createElement('div');
  row.className = 'file-queue-item waiting';
  row.dataset.file = filePath;
  var name = basename(filePath);
  row.innerHTML =
    '<span class="queue-item-icon">' + iconMarkup('queue', true) + '</span>' +
    '<span class="queue-item-name">' + name + '</span>' +
    '<span class="queue-item-size"></span>' +
    '<span class="queue-item-status">等待中</span>' +
    '<span class="queue-item-actions"></span>' +
    '<button class="queue-item-remove" title="移除">' + iconMarkup('close', true) + '</button>' +
    '<div class="progress-file-bar"></div>';
  var rmBtn = row.querySelector('.queue-item-remove');
  rmBtn.addEventListener('click', function(e) {
    e.stopPropagation();
    if (row.classList.contains('waiting')) {
      if (isCompressing) {
        cancelledFiles.add(filePath);
        invoke('cancel_file', { filePath: filePath });
      }
      var idx = files.indexOf(filePath);
      if (idx >= 0) files.splice(idx, 1);
      row.classList.remove('waiting');
      row.classList.add('cancelled');
      row.querySelector('.queue-item-icon').innerHTML = iconMarkup('minus', true);
      row.querySelector('.queue-item-status').textContent = '已移除';
      row.querySelector('.queue-item-remove').style.display = 'none';
      if (!isCompressing) {
        queueWasEdited = true;
        updateQueueSummary();
      } else {
        totalFiles--;
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
    actionDefs = [
      { action: 'save', title: '另存为', icon: iconMarkup('save', true) },
      { action: 'compare', title: '对比查看', icon: iconMarkup('compare', true) },
      { action: 'restore', title: '恢复原图', icon: iconMarkup('restore', true) },
      { action: 'finder', title: '在访达中显示', icon: iconMarkup('finder', true) },
    ];
  }
  actionDefs.push({ action: 'log', title: '复制日志', icon: iconMarkup('copy', true) });

  actionDefs.forEach(function(def) {
    var btn = document.createElement('button');
    btn.className = 'queue-action-btn';
    btn.type = 'button';
    btn.title = def.title;
    btn.innerHTML = def.icon;
    btn.addEventListener('click', function(e) {
      e.stopPropagation();
      if (def.action === 'save') saveResult(result.file);
      else if (def.action === 'compare') openCompareByFile(result.file);
      else if (def.action === 'restore') restoreOriginal(result.file, result.backupPath || '', result.outputMode || 'suffix');
      else if (def.action === 'finder') openInFinder(result.file);
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
  var text = lines.join('\n');
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
  showToast(ok ? '\u538b\u7f29\u65e5\u5fd7\u5df2\u590d\u5236\u5230\u526a\u8d34\u677f' : '\u590d\u5236\u5931\u8d25\uff0c\u8bf7\u624b\u52a8\u9009\u4e2d\u65e5\u5fd7\u6587\u672c');
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
  const outputFormat = document.getElementById('outputFormat').value;
  const backend = document.getElementById('compressionBackend').value;
  const effort = parseInt(document.getElementById('compressionEffort').value);
  const smartMode = document.getElementById('smartMode').checked;
  const convertToWebp = document.getElementById('convertToWebp').checked;

  let effectiveFormat = outputFormat;
  if (convertToWebp && outputFormat === 'original') {
    effectiveFormat = 'webp';
  }

  if (outputMode === 'folder' && !outputDir) {
    return { error: '请先选择输出目录' };
  }

  return {
    useSmartIpc: smartMode || effectiveFormat !== 'original',
    options: {
      quality: parseInt(qualitySlider.value),
      smartMode,
      outputFormat: effectiveFormat,
      backend,
      effort,
      convertToWebp,
      outputMode,
      outputDir: outputMode === 'folder' ? outputDir : null,
    },
  };
}

function clearAllFiles() {
  if (files.length === 0) return;
  if (!confirm('确定要清空全部 ' + files.length + ' 个文件吗？')) return;
  files = [];
  inputPaths = [];
  results = [];
  fileRows = {};
  cancelledFiles.clear();
  totalDone = 0;
  totalFiles = 0;
  queueWasEdited = false;
  isCompressing = false;
  var queuePanel = document.getElementById('queuePanel');
  if (queuePanel) queuePanel.style.display = 'none';
  settingsPanel.style.display = 'block';
  resultsPanel.style.display = 'none';
  var list = document.getElementById('fileQueueList');
  if (list) list.innerHTML = '';
  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'none';
  updateQueueSummary();
}

// ─── Compression ────────────────────────────────────────────────
async function startCompression(isIncrement) {
  if (isCompressing || files.length === 0) return;
  isCompressing = true;
  if (!isIncrement) results = [];
  currentCompressOptions = null;

  const config = getCurrentCompressionConfig();
  if (config.error) {
    showToast(config.error);
    isCompressing = false;
    return;
  }
  currentCompressOptions = config.options;

  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'flex';
  statOriginal.textContent = '0B';
  statCompressed.textContent = '0B';
  totalSavings.textContent = '0B';
  totalRate.textContent = '0%';

  cancelledFiles.clear();
  totalDone = isIncrement ? results.length : 0;
  totalFiles = files.length;
  updateQueueSummary();

  var startBtn = document.getElementById('startCompressBtn');
  if (startBtn) startBtn.disabled = true;

  renderFileQueue();

  // Progress handler - updates existing rows in place
  const progressHandler = (data) => {
    var file = data.file, result = data.result, status = data.status;
    var row = fileRows[file];
    if (!row) return;

    if (status === 'starting') {
      row.classList.remove('waiting');
      row.classList.add('compressing');
      row.querySelector('.queue-item-icon').innerHTML = '<span class="progress-file-spinner"></span>';
      row.querySelector('.queue-item-status').textContent = '压缩中…';
      var rmBtn = row.querySelector('.queue-item-remove');
      if (rmBtn) rmBtn.style.display = 'none';
    }

    if (result) {
      if (results.some(function(r) { return r.file === result.file; })) return;
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
      result.compressOptions = currentCompressOptions;
      results.push(result);
      renderQueueResultActions(row, result);
      updateStats();
      totalDone++;
      updateQueueSummary();
    }

    if (status === 'cancelled' && row) {
      row.classList.add('cancelled');
      row.querySelector('.queue-item-icon').innerHTML = iconMarkup('minus', true);
      row.querySelector('.queue-item-status').textContent = '已跳过';
    }
  };

  const unlisten = await listen('compress-progress', (event) => {
    progressHandler(event.payload);
  });

  try {
    const allPaths = (!queueWasEdited && inputPaths.length > 0) ? inputPaths : files;
    const alreadyDone = new Set(results.map(function(r) { return r.file; }));
    const pathsForCompression = allPaths.filter(function(f) { return !alreadyDone.has(f); });
    if (pathsForCompression.length === 0) { return; }
    await invoke(config.useSmartIpc ? 'compress_smart' : 'compress_files', { filePaths: pathsForCompression, options: config.options });
    updateStats();
    showResults();
  } catch (err) {
    console.error('Compression error:', err);
    showToast('压缩出错: ' + (err.message || err));
  } finally {
    unlisten();
    isCompressing = false;
    if (pendingAutoCompress) {
      pendingAutoCompress = false;
      startCompression(true);
    } else {
      if (startBtn) startBtn.disabled = false;
      updateQueueSummary();
    }
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

  const config = getCurrentCompressionConfig();
  if (config.error) {
    showToast(config.error);
    return;
  }

  isCompressing = true;
  currentCompressOptions = config.options;
  results = results.filter(function(r) { return r.file !== filePath; });

  row.classList.remove('waiting', 'done', 'failed', 'restored', 'cancelled');
  row.classList.add('compressing');
  row.querySelector('.queue-item-icon').innerHTML = '<span class="progress-file-spinner"></span>';
  row.querySelector('.queue-item-status').textContent = '压缩中…';
  var actions = row.querySelector('.queue-item-actions');
  if (actions) actions.innerHTML = '';
  var rmBtn = row.querySelector('.queue-item-remove');
  if (rmBtn) rmBtn.style.display = 'none';

  const unlisten = await listen('compress-progress', (event) => {
    var data = event.payload;
    if (!data || data.file !== filePath || !data.result) return;
    var result = data.result;
    row.classList.remove('compressing');
    row.classList.add(result.success ? 'done' : 'failed');
    row.querySelector('.queue-item-icon').innerHTML = iconMarkup(result.success ? 'check' : 'error', true);
    var sizeEl = row.querySelector('.queue-item-size');
    if (result.success && sizeEl) {
      sizeEl.textContent = formatBytes(result.originalSize) + ' → ' + formatBytes(result.compressedSize);
    }
    row.querySelector('.queue-item-status').textContent = result.success
      ? (result.savings >= 0 ? '-' : '+') + Math.abs(result.savings).toFixed(1) + '%'
      : '失败';
    results = results.filter(function(r) { return r.file !== filePath; });
    result.compressOptions = currentCompressOptions;
    results.push(result);
    renderQueueResultActions(row, result);
    updateStats();
    updateQueueSummary();
  });

  try {
    await invoke(config.useSmartIpc ? 'compress_smart' : 'compress_files', { filePaths: [filePath], options: config.options });
    showToast('已重新压缩: ' + basename(filePath));
  } catch (err) {
    row.classList.remove('compressing');
    row.classList.add('failed');
    row.querySelector('.queue-item-icon').innerHTML = iconMarkup('error', true);
    row.querySelector('.queue-item-status').textContent = '失败';
    showToast('重新压缩出错: ' + (err.message || err));
  } finally {
    unlisten();
    isCompressing = false;
    updateQueueSummary();
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

async function restoreOriginal(filePath, backupPath, outputMode) {
  const result = await invoke('restore_original', { filePath, backupPath: backupPath || null, outputMode });
  if (result.success) {
    showToast('已恢复原图: ' + basename(filePath));
    results = results.filter(r => r.file !== filePath);
    markQueueRowRestored(filePath);
    showResults();
    updateQueueSummary();
  } else {
    showToast('恢复失败: ' + (result.error || '未知错误'));
  }
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
  var successCount = 0;
  var restoredFiles = [];
  for (var i = 0; i < results.length; i++) {
    var r = results[i];
    if (!r.success) continue;
    try {
      await invoke('restore_original', {
        filePath: r.file,
        backupPath: r.backupPath || null,
        outputMode: r.outputMode || 'suffix'
      });
      successCount++;
      restoredFiles.push(r.file);
    } catch(e) { /* ignore */ }
  }
  showToast('已恢复 ' + successCount + ' 个文件到原图');
  restoredFiles.forEach(markQueueRowRestored);
  results = [];
  showResults();
  updateQueueSummary();
}

async function exportAll() {
  if (results.length === 0) return;
  const count = await invoke('export_all', { results: results });
  showToast('已导出 ' + count + ' 个文件到原目录（_compressed 后缀）');
}

function clearResults() {
  results = [];
  files = [];
  inputPaths = [];
  fileRows = {};
  cancelledFiles.clear();
  totalDone = 0;
  totalFiles = 0;
  queueWasEdited = false;
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
}

function formatBytes(bytes) {
  if (bytes === 0) return '0B';
  if (bytes < 1024) return bytes.toFixed(1) + 'B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + 'KB';
  return (bytes / (1024 * 1024)).toFixed(1) + 'MB';
}

// ─── Comparison ─────────────────────────────────────────────────
async function recompressWithQuality(quality) {
  if (!currentCompareResult) return;
  const result = currentCompareResult;
  const recompressBtn = document.getElementById('recompressBtn');
  if (recompressBtn) recompressBtn.disabled = true;

  try {
    const options = {
      quality: parseInt(quality),
      backend: 'auto',
      effort: 6,
      outputMode: 'suffix',
      outputFormat: result.type || 'original',
    };
    const newResult = await invoke('compress_single', { filePath: result.file, options: options });
    if (newResult && newResult.success && newResult.outputPath) {
      // Load the new compressed image
      await loadOriginalImage(compareCompressedImg, newResult.outputPath);
      compareCompressedSize.textContent = newResult.compressedSizeFormatted || '?';
      compareSavings.textContent = (newResult.savings >= 0 ? '-' : '+') + Math.abs(newResult.savings).toFixed(1) + '%';
      compareAlgorithm.textContent = newResult.algorithm || '?';

      const idx = results.findIndex(r => r.file === result.file);
      if (idx >= 0) {
        results[idx] = Object.assign({}, results[idx], newResult);
      }
      currentCompareResult = Object.assign({}, result, newResult);
      showToast('重新压缩完成 (质量: ' + quality + '%)');
    } else {
      showToast('重新压缩失败');
    }
  } catch (err) {
    showToast('重新压缩出错: ' + (err.message || err));
  } finally {
    if (recompressBtn) recompressBtn.disabled = false;
  }
}

async function openCompare(result) {
  releaseCompareImages();
  currentCompareResult = result;

  // Determine the original image path (backup for replace mode, else original file)
  const originalPath = result.backupPath || result.file;
  const loadedOriginal = await loadOriginalImage(compareOriginalImg, originalPath);
  if (!loadedOriginal) {
    showToast('无法加载原图');
    return;
  }

  // Load compressed image from output path
  const compressedPath = result.outputPath || result.file;
  const loadedCompressed = await loadOriginalImage(compareCompressedImg, compressedPath);
  if (!loadedCompressed) {
    showToast('无法加载压缩图');
    releaseCompareImages();
    return;
  }

  // Set container aspect-ratio to match image
  var outer = document.getElementById('compareSliderOuter');
  var setRatio = function() {
    var w = compareOriginalImg.naturalWidth || compareCompressedImg.naturalWidth;
    var h = compareOriginalImg.naturalHeight || compareCompressedImg.naturalHeight;
    if (w && h) {
      outer.style.aspectRatio = w + ' / ' + h;
    }
  };
  if (compareOriginalImg.naturalWidth) setRatio();
  else compareOriginalImg.onload = setRatio;

  var fitW = compareOriginalImg.naturalWidth || compareCompressedImg.naturalWidth || 1;
  var fitH = compareOriginalImg.naturalHeight || compareCompressedImg.naturalHeight || 1;
  var fitZoom = Math.min(outer.clientWidth / fitW, outer.clientHeight / fitH, 1);
  if (!isFinite(fitZoom) || fitZoom <= 0) fitZoom = 1;
  setCompareZoom(fitZoom);
  updateCompareSlider(50);

  compareFilename.textContent = basename(result.file);
  compareOriginalSize.textContent = result.originalSizeFormatted || '?';
  compareCompressedSize.textContent = result.compressedSizeFormatted || '?';
  compareSavings.textContent = (result.savings >= 0 ? '-' : '+') + Math.abs(result.savings).toFixed(1) + '%';
  compareAlgorithm.textContent = result.algorithm || '?';

  document.getElementById('modalBackdrop').style.display = 'block';
  comparePanel.style.display = 'flex';
  document.body.style.overflow = 'hidden';
}

// ── Compare slider: clip-path + handle position ──────────────────
function updateCompareSlider(value) {
  var sliderBar = document.getElementById('compareRange');
  value = Math.max(0, Math.min(100, parseFloat(value) || 0));
  if (sliderBar) sliderBar.value = Math.round(value);

  var outer = document.getElementById('compareSliderOuter');
  var container = document.getElementById('compareSliderContainer');
  var zoom = currentCompareZoom || 1;
  var cw = outer.clientWidth;
  var sl = container.scrollLeft;
  var imgW = compareOriginalImg.naturalWidth || compareCompressedImg.naturalWidth || cw;

  var clipLinePx = sl + (value / 100) * cw;
  var imgWidth = imgW * zoom;
  var clipLinePct = (clipLinePx / imgWidth) * 100;
  var clipRight = Math.max(0, Math.min(100, 100 - clipLinePct));

  compareOriginalImg.style.clipPath = 'inset(0 ' + clipRight + '% 0 0)';
  compareHandle.style.left = clipLinePct + '%';
  compareHandle.style.display = 'block';
}

function setCompareZoom(level) {
  level = Math.max(0.1, Math.min(8, level));
  var outer = document.getElementById('compareSliderOuter');
  var container = document.getElementById('compareSliderContainer');
  var wrapper = document.getElementById('compareImgWrapper');
  var oldZoom = currentCompareZoom || 1;
  var cw = outer.clientWidth;
  var ch = outer.clientHeight;
  var imgW = compareOriginalImg.naturalWidth || compareCompressedImg.naturalWidth || 1;
  var imgH = compareOriginalImg.naturalHeight || compareCompressedImg.naturalHeight || 1;

  var sliderBar = document.getElementById('compareRange');
  var sliderVal = sliderBar ? parseFloat(sliderBar.value) : 50;

  var oldImgW = imgW * oldZoom;
  var oldImgH = imgH * oldZoom;
  var axisRatio = (container.scrollLeft + (sliderVal / 100) * cw) / oldImgW;
  var centerYRatio = (container.scrollTop + ch / 2) / oldImgH;

  currentCompareZoom = level;
  wrapper.style.width = (imgW * level) + 'px';
  wrapper.style.height = (imgH * level) + 'px';

  var newImgW = imgW * level;
  var newImgH = imgH * level;
  container.scrollLeft = axisRatio * newImgW - (sliderVal / 100) * cw;
  container.scrollTop = centerYRatio * newImgH - ch / 2;

  var zoomSlider = document.getElementById('zoomSlider');
  if (zoomSlider) zoomSlider.value = level;
  var zoomValue = document.getElementById('zoomValue');
  if (zoomValue) zoomValue.textContent = Math.round(level * 100) + '%';

  updateCompareSlider(sliderVal);
}

function stepZoom(delta) {
  setCompareZoom(currentCompareZoom + delta);
}

function toggleFullscreen() {
  comparePanel.classList.toggle('fullscreen');
  requestAnimationFrame(function() {
    var sliderBar = document.getElementById('compareRange');
    updateCompareSlider(sliderBar ? sliderBar.value : 50);
  });
}

function closeCompare() {
  comparePanel.style.display = 'none';
  comparePanel.classList.remove('fullscreen');
  document.getElementById('modalBackdrop').style.display = 'none';
  document.body.style.overflow = '';
  currentCompareResult = null;
  releaseCompareImages();
  setCompareZoom(1);
}

function releaseCompareImages() {
  if (compareOriginalImg) {
    compareOriginalImg.onload = null;
    compareOriginalImg.removeAttribute('src');
  }
  if (compareCompressedImg) {
    compareCompressedImg.onload = null;
    compareCompressedImg.removeAttribute('src');
  }
}

var recompressQualitySlider = document.getElementById('recompressQuality');
var recompressQualityValue = document.getElementById('recompressQualityValue');
if (recompressQualitySlider) {
  recompressQualitySlider.addEventListener('input', function() {
    recompressQualityValue.textContent = recompressQualitySlider.value + '%';
  });
}

(function setupCompareDrag() {
  var outer = document.getElementById('compareSliderOuter');
  var container = document.getElementById('compareSliderContainer');
  var sliderBar = document.getElementById('compareRange');
  if (!outer || !container) return;

  var isPointerDown = false;

  function getPercent(clientX) {
    var rect = outer.getBoundingClientRect();
    var x = clientX - rect.left;
    return Math.max(0, Math.min(100, (x / rect.width) * 100));
  }

  outer.addEventListener('mousemove', function(e) {
    var pct = getPercent(e.clientX);
    updateCompareSlider(pct);
  });

  function onPointerDown(e) {
    isPointerDown = true;
    e.preventDefault();
    if (window.getSelection) {
      var selection = window.getSelection();
      if (selection) selection.removeAllRanges();
    }
    var clientX = e.touches ? e.touches[0].clientX : e.clientX;
    updateCompareSlider(getPercent(clientX));
  }

  function onPointerMove(e) {
    if (!isPointerDown) return;
    e.preventDefault();
    var clientX = e.touches ? e.touches[0].clientX : e.clientX;
    updateCompareSlider(getPercent(clientX));
  }

  function onPointerUp() { isPointerDown = false; }

  outer.addEventListener('mousedown', onPointerDown);
  outer.addEventListener('touchstart', onPointerDown, { passive: false });
  document.addEventListener('mousemove', onPointerMove);
  document.addEventListener('mouseup', onPointerUp);
  document.addEventListener('touchmove', onPointerMove, { passive: false });
  document.addEventListener('touchend', onPointerUp);

  if (sliderBar) {
    sliderBar.addEventListener('input', function() {
      updateCompareSlider(this.value);
    });
  }

  outer.addEventListener('wheel', function(e) {
    e.preventDefault();
    if (e.metaKey) {
      navigateCompare(e.deltaY < 0 ? -1 : 1);
      return;
    }
    var oldZoom = currentCompareZoom || 1;
    var delta = e.deltaY < 0 ? 0.25 : -0.25;
    var newZoom = Math.max(0.1, Math.min(8, oldZoom + delta));

    var rect = outer.getBoundingClientRect();
    var mouseX = e.clientX - rect.left;
    var cw = outer.clientWidth;
    var ch = outer.clientHeight;
    var imgW = compareOriginalImg.naturalWidth || compareCompressedImg.naturalWidth || cw;
    var imgH = compareOriginalImg.naturalHeight || compareCompressedImg.naturalHeight || ch;
    var mouseImgX = (container.scrollLeft + mouseX) / (imgW * oldZoom);
    var mouseImgY = (container.scrollTop + (e.clientY - rect.top)) / (imgH * oldZoom);

    currentCompareZoom = newZoom;
    var wrapper = document.getElementById('compareImgWrapper');
    wrapper.style.width = (imgW * newZoom) + 'px';
    wrapper.style.height = (imgH * newZoom) + 'px';
    container.scrollLeft = mouseImgX * (imgW * newZoom) - mouseX;
    container.scrollTop = mouseImgY * (imgH * newZoom) - (e.clientY - rect.top);

    var zoomSlider = document.getElementById('zoomSlider');
    if (zoomSlider) zoomSlider.value = newZoom;
    var zoomValue = document.getElementById('zoomValue');
    if (zoomValue) zoomValue.textContent = Math.round(newZoom * 100) + '%';

    var sliderVal = sliderBar ? parseFloat(sliderBar.value) : 50;
    updateCompareSlider(sliderVal);
  }, { passive: false });

  container.addEventListener('scroll', function() {
    if (sliderBar) updateCompareSlider(sliderBar.value);
  });

  var zoomSliderEl = document.getElementById('zoomSlider');
  if (zoomSliderEl) {
    zoomSliderEl.addEventListener('input', function() {
      setCompareZoom(parseFloat(this.value));
    });
  }
})();

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && comparePanel.style.display !== 'none') {
    closeCompare();
  }
});

window.addEventListener('beforeunload', () => {
  releaseCompareImages();
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

async function restoreFromCompare() {
  if (!currentCompareResult) return;
  const r = currentCompareResult;
  await restoreOriginal(r.file, r.backupPath || '', r.outputMode || 'suffix');
  closeCompare();
}

function toggleWindowControls() {
  showToast('OctoShrink v' + (window.appVersion || '2.0.0'));
}

function navigateCompare(direction) {
  if (!currentCompareResult) return;
  var okResults = results.filter(function(r) { return r && r.success; });
  if (okResults.length === 0) return;
  var idx = okResults.indexOf(currentCompareResult);
  if (idx < 0) idx = 0;
  var newIdx = Math.max(0, Math.min(okResults.length - 1, idx + direction));
  if (newIdx === idx) return;
  openCompare(okResults[newIdx]);
}

function openCompareByFile(filePath) {
  const result = results.find(r => r.file === filePath);
  if (result) openCompare(result);
}

function updateSettingsSummary() {
  var ac = document.getElementById('autoCompress');
  var q = document.getElementById('qualitySlider');
  var of = document.getElementById('outputFormat');
  var sm = document.getElementById('smartMode');
  var om = document.querySelector('input[name="outputMode"]:checked');
  var parts = [];
  if (ac && ac.checked) parts.push('自动');
  if (q) parts.push('Q' + q.value);
  if (of) parts.push(of.value === 'original' ? '\u539f\u683c\u5f0f' : of.value.toUpperCase());
  if (sm) parts.push(sm.checked ? '\u667a\u80fd' : '\u6807\u51c6');
  if (om) parts.push(om.value === 'replace' ? '\u8986\u76d6' : (om.value === 'suffix' ? '\u540e\u7f00' : '\u76ee\u5f55'));
  var el = document.getElementById('settingsSummary');
  if (el) el.textContent = parts.join(' \u00b7 ');
}

function saveCompressSettings() {
  var data = {};
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
  try { localStorage.setItem('octoshrink-settings', JSON.stringify(data)); } catch(e) {}
}

function loadCompressSettings() {
  var raw;
  try { raw = localStorage.getItem('octoshrink-settings'); } catch(e) { return; }
  if (!raw) return;
  var data;
  try { data = JSON.parse(raw); } catch(e) { return; }
  if (!data) return;
  if (data.quality != null) { var q = document.getElementById('qualitySlider'); if (q) q.value = data.quality; }
  if (data.outputFormat != null) { var of = document.getElementById('outputFormat'); if (of) of.value = data.outputFormat; }
  if (data.backend != null) { var cb = document.getElementById('compressionBackend'); if (cb) cb.value = data.backend; }
  if (data.effort != null) { var ce = document.getElementById('compressionEffort'); if (ce) ce.value = data.effort; }
  if (data.autoCompress != null) { var ac = document.getElementById('autoCompress'); if (ac) ac.checked = data.autoCompress; }
  if (data.smartMode != null) { var sm = document.getElementById('smartMode'); if (sm) sm.checked = data.smartMode; }
  if (data.convertToWebp != null) { var cw = document.getElementById('convertToWebp'); if (cw) cw.checked = data.convertToWebp; }
  if (data.outputMode != null) { var om = document.querySelector('input[name="outputMode"][value="' + data.outputMode + '"]'); if (om) om.checked = true; }
}

// Init
(function() {
  loadCompressSettings();
  var sp = document.getElementById('settingsPanel');
  if (sp) sp.style.display = 'block';
  ['autoCompress','qualitySlider','outputFormat','compressionBackend','compressionEffort','smartMode','convertToWebp'].forEach(function(id){
    var el = document.getElementById(id);
    if (el) el.addEventListener('change', function(){ saveCompressSettings(); updateSettingsSummary(); });
  });
  document.querySelectorAll('input[name="outputMode"]').forEach(function(r){
    r.addEventListener('change', function(){ saveCompressSettings(); updateSettingsSummary(); });
  });
  updateSettingsSummary();
  updateQualitySlider();
  invoke('get_app_version').then(v => { window.appVersion = v; }).catch(() => {});
})();
