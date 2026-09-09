// OctoShrink - 独立对比窗口（compare.html）
// 由主窗口经 open_compare_window 创建；首屏载荷经 take_compare_window_payload 取回，
// 之后主窗口通过 compare-open / compare-results-changed 事件推送更新。
// 重新压缩 / 恢复原图在本窗口执行，结果经事件回传主窗口同步。

const { invoke } = window.__TAURI__.core;
const { listen, emit } = window.__TAURI__.event;
const { getCurrentWindow } = window.__TAURI__.window;

// ─── DOM ────────────────────────────────────────────────────────
const comparePanel = document.getElementById('comparePanel');
const compareModalBody = document.getElementById('compareModalBody');
const compareEmpty = document.getElementById('compareEmpty');
const compareOriginalImg = document.getElementById('compareOriginalImg');
const compareCompressedImg = document.getElementById('compareCompressedImg');
const compareHandle = document.getElementById('compareHandle');
const compareFilename = document.getElementById('compareFilename');
const compareOriginalSize = document.getElementById('compareOriginalSize');
const compareCompressedSize = document.getElementById('compareCompressedSize');
const compareSavings = document.getElementById('compareSavings');
const compareAlgorithm = document.getElementById('compareAlgorithm');
const prevBtn = document.getElementById('prevBtn');
const nextBtn = document.getElementById('nextBtn');

// ─── State ──────────────────────────────────────────────────────
let compareResults = [];
let currentIndex = -1;
let currentResult = null;
let currentCompareZoom = 1;
let compareRequestId = 0;
let compareSliderFrame = 0;
let pendingCompareSliderValue = null;

// ─── Path utilities ─────────────────────────────────────────────
function basename(p) {
  const parts = String(p).replace(/\\/g, '/').split('/');
  return parts[parts.length - 1] || p;
}

// ─── Theme（跟随主窗口 localStorage 与系统外观）────────────────
const THEMES = ['auto', 'light', 'dark'];

function applyCompareTheme() {
  let mode = 'auto';
  try {
    const stored = localStorage.getItem('octoshrink-theme');
    if (THEMES.includes(stored)) mode = stored;
  } catch (_) {}
  const resolved = mode === 'auto'
    ? (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    : mode;
  document.documentElement.setAttribute('data-theme-mode', mode);
  if (resolved === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
  } else {
    document.documentElement.setAttribute('data-theme', 'light');
  }
  document.documentElement.style.colorScheme = resolved;
}

applyCompareTheme();
window.addEventListener('storage', applyCompareTheme);
if (window.matchMedia) {
  try {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyCompareTheme);
  } catch (_) {}
}

// ─── Image loading ──────────────────────────────────────────────
function imageFileSrc(filePath) {
  const { convertFileSrc } = window.__TAURI__.core;
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

// ─── Empty / panel switching ────────────────────────────────────
function showEmpty(message) {
  compareEmpty.textContent = message || '暂无可对比的内容';
  compareEmpty.style.display = 'flex';
  compareModalBody.style.display = 'none';
}

function showLoading(message) {
  compareEmpty.textContent = message || '加载中…';
  compareEmpty.style.display = 'flex';
  compareModalBody.style.display = 'none';
}

function showPanel() {
  compareEmpty.style.display = 'none';
  compareModalBody.style.display = '';
}

// ─── Toast ──────────────────────────────────────────────────────
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

// ─── Rendering ──────────────────────────────────────────────────
function refreshInfo() {
  if (!currentResult) return;
  compareFilename.textContent = basename(currentResult.file);
  compareOriginalSize.textContent = currentResult.originalSizeFormatted || '?';
  compareCompressedSize.textContent = currentResult.compressedSizeFormatted || '?';
  compareSavings.textContent = (currentResult.savings >= 0 ? '-' : '+') + Math.abs(currentResult.savings).toFixed(1) + '%';
  compareAlgorithm.textContent = currentResult.algorithm || '?';
}

function setNavButtonsState() {
  if (prevBtn) prevBtn.disabled = currentIndex <= 0;
  if (nextBtn) nextBtn.disabled = currentIndex < 0 || currentIndex >= compareResults.length - 1;
}

async function renderAt(index) {
  if (!compareResults.length) {
    currentResult = null;
    currentIndex = -1;
    showEmpty('暂无可对比的内容');
    setNavButtonsState();
    return;
  }
  currentIndex = Math.max(0, Math.min(compareResults.length - 1, index));
  const result = compareResults[currentIndex];
  currentResult = result;
  const requestId = ++compareRequestId;
  const outer = document.getElementById('compareSliderOuter');

  showLoading('加载中…');
  releaseCompareImages();
  setNavButtonsState();

  try {
    const originalPath = result.backupPath || result.file;
    const compressedPath = result.outputPath || result.file;
    const loaded = await Promise.all([
      loadOriginalImage(compareOriginalImg, originalPath),
      loadOriginalImage(compareCompressedImg, compressedPath),
    ]);
    if (requestId !== compareRequestId || currentResult !== result) return;
    if (!loaded[0] || !loaded[1]) {
      showEmpty(!loaded[0] ? '无法加载原图，文件可能已被移动或恢复' : '无法加载压缩图，文件可能已被移动或恢复');
      return;
    }

    const fitW = compareOriginalImg.naturalWidth || compareCompressedImg.naturalWidth || 1;
    const fitH = compareOriginalImg.naturalHeight || compareCompressedImg.naturalHeight || 1;
    let fitZoom = Math.min(outer.clientWidth / fitW, outer.clientHeight / fitH, 1);
    if (!isFinite(fitZoom) || fitZoom <= 0) fitZoom = 1;
    setCompareZoom(fitZoom);
    updateCompareSlider(50);
    refreshInfo();
    showPanel();
  } catch (err) {
    if (requestId !== compareRequestId) return;
    showEmpty('打开对比失败: ' + (err.message || err));
  }
}

function loadPayload(payload) {
  if (!payload) return;
  compareResults = (Array.isArray(payload.results) ? payload.results : []).filter(function(r) {
    return r && r.success;
  });
  const index = typeof payload.index === 'number' ? payload.index : 0;
  if (!compareResults.length) {
    currentResult = null;
    currentIndex = -1;
    showEmpty('没有可对比的结果');
    setNavButtonsState();
    return;
  }
  renderAt(index);
}

// ─── Slider: clip-path + handle position ────────────────────────
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

function scheduleCompareSlider(value) {
  pendingCompareSliderValue = value;
  if (compareSliderFrame) return;
  compareSliderFrame = requestAnimationFrame(function() {
    compareSliderFrame = 0;
    updateCompareSlider(pendingCompareSliderValue);
  });
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

// ─── Navigation ─────────────────────────────────────────────────
function navigateCompare(direction) {
  if (compareResults.length === 0) return;
  const newIdx = currentIndex + direction;
  if (newIdx < 0 || newIdx >= compareResults.length) return;
  renderAt(newIdx);
}

// ─── Actions: recompress / restore / close ──────────────────────
async function recompressWithQuality(quality) {
  if (!currentResult) return;
  const result = currentResult;
  const requestId = compareRequestId;
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
      if (requestId !== compareRequestId || !currentResult || currentResult.file !== result.file) return;
      const loadedPreview = await loadOriginalImage(compareCompressedImg, newResult.outputPath);
      if (requestId !== compareRequestId || !currentResult || currentResult.file !== result.file) return;
      if (!loadedPreview) {
        showToast('重新压缩预览加载失败');
        return;
      }
      compareCompressedSize.textContent = newResult.compressedSizeFormatted || '?';
      compareSavings.textContent = (newResult.savings >= 0 ? '-' : '+') + Math.abs(newResult.savings).toFixed(1) + '%';
      compareAlgorithm.textContent = newResult.algorithm || '?';

      // compress_single 输出的是临时预览文件；保留真实输出与备份元数据，
      // 恢复原图仍指向原结果（与主窗口 recompress 逻辑一致）。
      currentResult = Object.assign({}, result, newResult, {
        outputPath: result.outputPath,
        backupPath: result.backupPath,
        outputMode: result.outputMode,
      });
      compareResults[currentIndex] = currentResult;
      emit('compare-recompressed', { filePath: result.file, result: currentResult });
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

async function restoreFromCompare() {
  if (!currentResult) return;
  const r = currentResult;
  try {
    const result = await invoke('restore_original', {
      filePath: r.file,
      backupPath: r.backupPath || null,
      outputMode: r.outputMode || 'suffix',
      outputPath: r.outputPath || null,
      outputSuffix: (r.compressOptions && r.compressOptions.outputSuffix) || null,
    });
    if (result && result.success) {
      emit('compare-restored', { filePath: r.file });
      closeCompareWindow();
    } else {
      showToast('恢复失败: ' + ((result && result.error) || '未知错误'));
    }
  } catch (err) {
    showToast('恢复出错: ' + (err.message || err));
  }
}

function closeCompareWindow() {
  getCurrentWindow().close();
}

// ─── Slider drag / wheel interactions ───────────────────────────
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
    scheduleCompareSlider(pct);
  });

  function onPointerDown(e) {
    isPointerDown = true;
    e.preventDefault();
    if (window.getSelection) {
      var selection = window.getSelection();
      if (selection) selection.removeAllRanges();
    }
    var clientX = e.touches ? e.touches[0].clientX : e.clientX;
    scheduleCompareSlider(getPercent(clientX));
  }

  function onPointerMove(e) {
    if (!isPointerDown) return;
    e.preventDefault();
    var clientX = e.touches ? e.touches[0].clientX : e.clientX;
    scheduleCompareSlider(getPercent(clientX));
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
      scheduleCompareSlider(this.value);
    });
  }

  outer.addEventListener('wheel', function(e) {
    if (e.metaKey) {
      e.preventDefault();
      navigateCompare(e.deltaY < 0 ? -1 : 1);
      return;
    }
    // 普通滚轮滚动放大后的图片；Ctrl/Alt+滚轮缩放
    if (!e.ctrlKey && !e.altKey) {
      e.preventDefault();
      container.scrollLeft += e.deltaX || (e.shiftKey ? e.deltaY : 0);
      container.scrollTop += e.deltaY;
      return;
    }
    e.preventDefault();
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
    if (sliderBar) scheduleCompareSlider(sliderBar.value);
  });

  var zoomSliderEl = document.getElementById('zoomSlider');
  if (zoomSliderEl) {
    zoomSliderEl.addEventListener('input', function() {
      setCompareZoom(parseFloat(this.value));
    });
  }
})();

// 重新压缩质量滑杆数值显示
var recompressQualitySlider = document.getElementById('recompressQuality');
var recompressQualityValue = document.getElementById('recompressQualityValue');
if (recompressQualitySlider) {
  recompressQualitySlider.addEventListener('input', function() {
    recompressQualityValue.textContent = recompressQualitySlider.value + '%';
  });
}

// ─── Keyboard / lifecycle ───────────────────────────────────────
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    closeCompareWindow();
  } else if (e.key === 'ArrowLeft' && e.target === document.body) {
    navigateCompare(-1);
  } else if (e.key === 'ArrowRight' && e.target === document.body) {
    navigateCompare(1);
  }
});

window.addEventListener('beforeunload', () => {
  releaseCompareImages();
});

// ─── 主窗口事件同步 ─────────────────────────────────────────────
listen('compare-open', function(event) {
  loadPayload(event.payload);
});

listen('compare-results-changed', function(event) {
  const payload = event.payload || {};
  const incoming = (Array.isArray(payload.results) ? payload.results : []).filter(function(r) {
    return r && r.success;
  });
  compareResults = incoming;
  setNavButtonsState();

  if (!currentResult) {
    if (compareResults.length) renderAt(0);
    return;
  }

  const idx = compareResults.findIndex(function(r) { return r.file === currentResult.file; });
  if (idx < 0) {
    // 当前文件已被恢复或移除
    currentResult = null;
    currentIndex = -1;
    releaseCompareImages();
    showEmpty('该文件已恢复原图或被移除');
    return;
  }

  const fresh = compareResults[idx];
  const viewFields = ['outputPath', 'backupPath', 'originalSizeFormatted', 'compressedSizeFormatted', 'savings', 'algorithm'];
  const changed = viewFields.some(function(field) {
    return JSON.stringify(fresh[field]) !== JSON.stringify(currentResult[field]);
  });
  currentIndex = idx;
  currentResult = fresh;
  if (changed) {
    renderAt(idx);
  } else {
    refreshInfo();
  }
});

// ─── Init ───────────────────────────────────────────────────────
(async function init() {
  try {
    const payload = await invoke('take_compare_window_payload');
    if (payload) {
      loadPayload(payload);
    } else if (!currentResult) {
      showEmpty('暂无可对比的内容');
    }
  } catch (err) {
    showEmpty('加载失败: ' + (err.message || err));
  }
})();
