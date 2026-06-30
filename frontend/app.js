// OctoShrink - Tauri frontend
// Uses window.__TAURI__ global API (withGlobalTauri: true)

const { invoke, convertFileSrc } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

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

function setImageSource(img, src) {
  return new Promise((resolve, reject) => {
    img.onload = () => resolve(true);
    img.onerror = () => reject(new Error('image load failed'));
    img.src = src;
  });
}

async function loadOriginalImage(img, filePath) {
  img.removeAttribute('src');
  const directSrc = imageFileSrc(filePath);
  if (directSrc) {
    try {
      await setImageSource(img, directSrc);
      return true;
    } catch (_) {
      img.removeAttribute('src');
    }
  }

  const dataUrl = await invoke('read_image_dataurl', { filePath: filePath, preview: false });
  if (!dataUrl) return false;
  await setImageSource(img, dataUrl);
  return true;
}

// ─── 主题管理（自动/亮色/暗黑）──────────────────────────────────
// 三种模式：auto（跟随系统）、light、dark，循环切换
const THEMES = ['auto', 'light', 'dark'];
let currentTheme = localStorage.getItem('octoshrink-theme') || 'auto';

function applyTheme(theme) {
  currentTheme = theme;
  localStorage.setItem('octoshrink-theme', theme);

  if (theme === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
  } else if (theme === 'light') {
    document.documentElement.setAttribute('data-theme', 'light');
  } else {
    // auto: 跟随系统
    document.documentElement.removeAttribute('data-theme');
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
      // 触发重新应用（移除再添加属性，强制 CSS 重新计算）
      document.documentElement.removeAttribute('data-theme');
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
let outputDir = null;

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
  qualityValue.textContent = qualitySlider.value + '%';
  const pct = qualitySlider.value;
  qualitySlider.style.background = 'linear-gradient(90deg, var(--primary) ' + pct + '%, #e2e8f0 ' + pct + '%)';
});

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

  var queuePanel = document.getElementById('queuePanel');
  if (queuePanel) queuePanel.style.display = 'block';
  settingsPanel.style.display = 'block';
  resultsPanel.style.display = 'none';
  updateQueueSummary();
  renderFileQueue();
  queuePanel.scrollIntoView({ behavior: 'smooth' });
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
  list.innerHTML = '';
  fileRows = {};
  for (var i = 0; i < files.length; i++) {
    var row = createQueueRow(files[i]);
    fileRows[files[i]] = row;
    list.appendChild(row);
  }
  // Fetch file sizes in batch
  if (files.length > 0) {
    try {
      const sizes = await invoke('get_file_sizes', { filePaths: files });
      for (var j = 0; j < files.length; j++) {
        var row = fileRows[files[j]];
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
    '<span class="queue-item-icon">○</span>' +
    '<span class="queue-item-name">' + name + '</span>' +
    '<span class="queue-item-size"></span>' +
    '<span class="queue-item-status">等待中</span>' +
    '<span class="queue-item-actions"></span>' +
    '<button class="queue-item-remove" title="移除">×</button>' +
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
      row.querySelector('.queue-item-icon').textContent = '—';
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
  if (!result || !result.success) return;

  var actionDefs = [
    { action: 'save', title: '另存为', icon: '<svg width="13" height="13" viewBox="0 0 14 14" fill="currentColor"><path d="M11 0H3a1 1 0 00-1 1v12a1 1 0 001 1h8a1 1 0 001-1V1a1 1 0 00-1-1zm-1 12H4V2h6v10z"/></svg>' },
    { action: 'compare', title: '对比查看', icon: '<svg width="13" height="13" viewBox="0 0 14 14" fill="currentColor"><path d="M2 2h4v4H2V2zm0 6h4v4H2V8zm6-6h4v4H8V2zm0 6h4v4H8V8z"/></svg>' },
    { action: 'restore', title: '恢复原图', icon: '<svg width="13" height="13" viewBox="0 0 14 14" fill="currentColor"><path d="M7 1a6 6 0 100 12A6 6 0 007 1zm0 10V7H4l3-4 3 4H7v4z"/></svg>' },
    { action: 'finder', title: '在访达中显示', icon: '<svg width="13" height="13" viewBox="0 0 14 14" fill="currentColor"><path d="M1 2.5A1.5 1.5 0 012.5 1h3.172a1.5 1.5 0 011.06.44l.94.94H11.5A1.5 1.5 0 0113 3.88V11.5a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 011 11.5V2.5z"/></svg>' },
  ];

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
    });
    actions.appendChild(btn);
  });
}

function renderRestoredActions(row, filePath) {
  var actions = row.querySelector('.queue-item-actions');
  if (!actions) return;
  actions.innerHTML = '';

  var btn = document.createElement('button');
  btn.className = 'queue-action-btn';
  btn.type = 'button';
  btn.title = '重新压缩';
  btn.innerHTML = '<svg width="13" height="13" viewBox="0 0 14 14" fill="currentColor"><path d="M7 1L2 6h3v5h4V6h3L7 1z"/></svg>';
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
  settingsPanel.style.display = 'none';
  resultsPanel.style.display = 'none';
  var list = document.getElementById('fileQueueList');
  if (list) list.innerHTML = '';
  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'none';
  updateQueueSummary();
}

// ─── Compression ────────────────────────────────────────────────
async function startCompression() {
  if (isCompressing || files.length === 0) return;
  isCompressing = true;
  results = [];

  const config = getCurrentCompressionConfig();
  if (config.error) {
    showToast(config.error);
    isCompressing = false;
    return;
  }

  var queueStats = document.getElementById('queueStats');
  if (queueStats) queueStats.style.display = 'flex';
  statOriginal.textContent = '0B';
  statCompressed.textContent = '0B';
  totalSavings.textContent = '0B';
  totalRate.textContent = '0%';

  cancelledFiles.clear();
  totalDone = 0;
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
      row.classList.remove('compressing');
      row.classList.add(result.success ? 'done' : 'failed');
      row.querySelector('.queue-item-icon').innerHTML = result.success ? '✓' : '✗';
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
        errIcon.innerHTML = '<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M6 1L1 11h10L6 1z" fill="#f59e0b" stroke="#f59e0b" stroke-width="0.5"/><circle cx="6" cy="8" r="0.5" fill="white"/><path d="M6 4.5v2.5" stroke="white" stroke-width="0.8" stroke-linecap="round"/></svg>';
        errIcon.onclick = function(e) { e.stopPropagation(); showErrorDetail(result.file, result.error); };
        statusEl.appendChild(errIcon);
      }
      results.push(result);
      renderQueueResultActions(row, result);
      updateStats();
      totalDone++;
      updateQueueSummary();
    }

    if (status === 'cancelled' && row) {
      row.classList.add('cancelled');
      row.querySelector('.queue-item-icon').textContent = '—';
      row.querySelector('.queue-item-status').textContent = '已跳过';
    }
  };

  const unlisten = await listen('compress-progress', (event) => {
    progressHandler(event.payload);
  });

  try {
    const pathsForCompression = (!queueWasEdited && inputPaths.length > 0) ? inputPaths : files;
    await invoke(config.useSmartIpc ? 'compress_smart' : 'compress_files', { filePaths: pathsForCompression, options: config.options });
    updateStats();
    showResults();
  } catch (err) {
    console.error('Compression error:', err);
    showToast('压缩出错: ' + (err.message || err));
  } finally {
    unlisten();
    isCompressing = false;
    if (startBtn) startBtn.disabled = false;
    updateQueueSummary();
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
    row.querySelector('.queue-item-icon').innerHTML = result.success ? '✓' : '✗';
    var sizeEl = row.querySelector('.queue-item-size');
    if (result.success && sizeEl) {
      sizeEl.textContent = formatBytes(result.originalSize) + ' → ' + formatBytes(result.compressedSize);
    }
    row.querySelector('.queue-item-status').textContent = result.success
      ? (result.savings >= 0 ? '-' : '+') + Math.abs(result.savings).toFixed(1) + '%'
      : '失败';
    results = results.filter(function(r) { return r.file !== filePath; });
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
    row.querySelector('.queue-item-icon').innerHTML = '✗';
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
  if (icon) icon.textContent = '↺';
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
  settingsPanel.style.display = 'none';
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
  await loadOriginalImage(compareCompressedImg, compressedPath);

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

  setCompareZoom(1);
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

  var clipLinePx = sl + (value / 100) * cw;
  var imgWidth = cw * zoom;
  var clipLinePct = (clipLinePx / imgWidth) * 100;
  var clipRight = Math.max(0, Math.min(100, 100 - clipLinePct));

  compareOriginalImg.style.clipPath = 'inset(0 ' + clipRight + '% 0 0)';
  compareHandle.style.left = value + '%';
  compareHandle.style.display = 'block';
}

function setCompareZoom(level) {
  level = Math.max(0.1, Math.min(8, level));
  var outer = document.getElementById('compareSliderOuter');
  var container = document.getElementById('compareSliderContainer');
  var oldZoom = currentCompareZoom || 1;
  var cw = outer.clientWidth;
  var ch = outer.clientHeight;

  var sliderBar = document.getElementById('compareRange');
  var sliderVal = sliderBar ? parseFloat(sliderBar.value) : 50;

  var axisImgX = (container.scrollLeft + (sliderVal / 100) * cw) / (cw * oldZoom);
  var centerY = (container.scrollTop + ch / 2) / (ch * oldZoom);

  currentCompareZoom = level;
  container.style.setProperty('--zoom', level);
  outer.style.setProperty('--zoom', level);

  var newImgW = cw * level;
  var newImgH = ch * level;
  container.scrollLeft = axisImgX * newImgW - (sliderVal / 100) * cw;
  container.scrollTop = centerY * newImgH - ch / 2;

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
    if (!e.ctrlKey && !e.metaKey) return;
    e.preventDefault();
    var oldZoom = currentCompareZoom || 1;
    var delta = e.deltaY < 0 ? 0.25 : -0.25;
    var newZoom = Math.max(0.1, Math.min(8, oldZoom + delta));

    var rect = outer.getBoundingClientRect();
    var mouseX = e.clientX - rect.left;
    var cw = outer.clientWidth;
    var ch = outer.clientHeight;
    var mouseImgX = (container.scrollLeft + mouseX) / (cw * oldZoom);
    var mouseImgY = (container.scrollTop + (e.clientY - rect.top)) / (ch * oldZoom);

    currentCompareZoom = newZoom;
    container.style.setProperty('--zoom', newZoom);
    container.scrollLeft = mouseImgX * (cw * newZoom) - mouseX;
    container.scrollTop = mouseImgY * (ch * newZoom) - (e.clientY - rect.top);

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

function openCompareByFile(filePath) {
  const result = results.find(r => r.file === filePath);
  if (result) openCompare(result);
}

// Init
(function() {
  const qs = document.getElementById('qualitySlider');
  if (qs) {
    const pct = qs.value;
    qs.style.background = 'linear-gradient(90deg, var(--primary) ' + pct + '%, #e2e8f0 ' + pct + '%)';
  }
  // Fetch app version
  invoke('get_app_version').then(v => { window.appVersion = v; }).catch(() => {});
})();
