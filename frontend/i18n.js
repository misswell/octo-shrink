(function attachOctoShrinkI18n(root) {
  'use strict';

  const PREFERENCE_KEY = 'octoshrink-language';
  const ENGLISH = Object.freeze({
    '还原默认设置': 'Restore defaults', '历史记录': 'History', '设置': 'Settings', '切换主题': 'Switch theme', '关于': 'About',
    '外观': 'Appearance', '主题': 'Theme',
    '文件队列': 'File queue', '0 个文件': '0 files', ' 个文件': ' files', '清空列表': 'Clear list', '清除全部': 'Clear all',
    '原始大小': 'Original size', '压缩后大小': 'Compressed size', '压缩后': 'Compressed', '已节省': 'Saved', '压缩率': 'Compression ratio',
    '只显示失败': 'Show failures only', '排序': 'Sort by', '导入顺序': 'Import order', '名称': 'Name', '压缩比': 'Compression ratio', '状态': 'Status',
    '当前升序，点击切换降序': 'Currently ascending; click to sort descending', '当前降序，点击切换升序': 'Currently descending; click to sort ascending',
    '升序': 'Ascending', '降序': 'Descending', '没有失败的文件': 'No failed files', '追加文件': 'Add files', '恢复全部原图': 'Restore all originals', '继续': 'Continue',
    '开始压缩': 'Start compression', '暂停': 'Pause', '停止': 'Stop', '停止：正在处理的文件会先完成，其余文件保留在队列中': 'Stop: current files will finish; the rest stay in the queue',
    '压缩设置': 'Compression settings', '处理方式': 'Processing mode', '系统转换': 'System conversion', '高级压缩': 'Advanced compression',
    '切换处理方式，当前为': 'Switch processing mode; current mode: ', '自动处理': 'Automatic processing', '拖入或选择后自动压缩': 'Automatically compress after adding files',
    '拖入或选择后自动转换': 'Automatically convert after adding files', '格式': 'Format', '原格式': 'Original format', '图像大小': 'Image size',
    '实际大小': 'Actual size', '大（最长边 1280 px）': 'Large (longest edge 1280 px)', '中（最长边 640 px）': 'Medium (longest edge 640 px)',
    '小（最长边 320 px）': 'Small (longest edge 320 px)', '元数据': 'Metadata', '保留元数据': 'Preserve metadata', '压缩质量': 'Compression quality',
    '输出模式': 'Output mode', '覆盖原文件': 'Replace original', '添加自定义后缀': 'Add a custom suffix', '输出到指定文件夹': 'Save to a folder',
    '文件名后缀': 'Filename suffix', '例如 _small': 'For example, _small', '输出目录': 'Output folder', '未选择': 'Not selected', '浏览': 'Browse',
    '智能模式': 'Smart mode', '自动选择最佳算法和参数': 'Automatically choose the best algorithm and settings', '转换为 WebP': 'Convert to WebP',
    '输出为 WebP 格式（更小体积）': 'Use WebP output for smaller files', '输出格式': 'Output format', '保持原格式': 'Keep original format',
    '压缩引擎': 'Compression engine', '自动选择（推荐）': 'Automatic (recommended)', '现代引擎（推荐）': 'Modern engine (recommended)',
    'CLI 工具': 'CLI tools', '压缩力度': 'Compression effort', '快速': 'Fast', '平衡（推荐）': 'Balanced (recommended)', '高质量': 'High quality',
    '极致压缩（慢）': 'Maximum compression (slow)', '压缩结果': 'Compression results', '清空': 'Clear', '全部导出': 'Export all',
    '共压缩': 'Compressed', '个文件，节省': ' files, saving', '返回': 'Back', '清空历史记录': 'Clear history', '清空历史': 'Clear history',
    '还没有压缩记录': 'No compression history yet', '历史记录与原图': 'History and originals', '原图备份保留时间': 'Keep original backups for',
    '不保留': 'Do not keep', '1 天': '1 day', '3 天': '3 days', '7 天': '7 days', '14 天': '14 days', '30 天': '30 days',
    '覆盖原文件时，OctoShrink 会先保存一份原图备份。': 'OctoShrink saves a backup of the original before replacing a file.',
    '本次运行的压缩记录和原图备份都会在关闭应用时清理；期间可以随时恢复原图。': 'Compression history and original backups from this session are cleared when the app closes. You can restore originals before then.',
    '性能': 'Performance', '当前设备': 'This device', '检测中…': 'Detecting…', 'CPU 使用上限': 'CPU usage limit',
    'OctoShrink 最多使用的 CPU 并行份数': 'Maximum number of CPU workers used by OctoShrink', '自动': 'Automatic',
    '不指定，按机器性能自动决定': 'Let OctoShrink choose based on this device', '低占用': 'Lower usage', '高性能': 'Higher performance',
    '限制 OctoShrink 同时使用的 CPU 并行能力。': 'Limit how much CPU parallelism OctoShrink can use.',
    '较低的数值会降低压缩速度，但可为其他应用保留更多性能。': 'A lower setting reduces compression speed and leaves more resources for other apps.',
    '系统会自动在性能核与能效核之间调度任务。': 'The system schedules work across performance and efficiency cores.',
    '更新': 'Updates', '当前版本': 'Current version', '在线更新': 'App updates', '检查更新': 'Check for updates',
    '打开 GitHub Release 页面': 'Open the GitHub Releases page', 'Release 页面': 'GitHub Releases', '下载进度': 'Download progress',
    '下载中 0%': 'Downloading 0%', '取消': 'Cancel',
    '检查更新只访问 GitHub Releases；发现新版本要点「立即更新」才会下载，图片始终不离开这台机器。': 'Update checks only contact GitHub Releases. A download starts only when you select Update now; your images never leave this device.',
    '本版本由 Mac App Store 分发，更新由 App Store 统一管理，应用内不再检查版本。': 'This version is distributed through the Mac App Store. Updates are managed by the App Store.',
    '系统转换说明': 'About system conversion', '关闭': 'Close',
    '系统转换使用 macOS 自带的图像转换能力，行为对齐 Finder 中选中图片后右键「快速操作 → 转换图像」的默认方式。': 'System conversion uses macOS built-in image conversion, similar to Finder’s Quick Actions > Convert Image.',
    '可选择输出格式、图像大小和是否保留元数据；不会调用第三方压缩工具。此模式仅在 macOS 上可用。': 'Choose an output format, image size, and whether to preserve metadata. No third-party compression tools are used. This mode is available only on macOS.',
    '知道了': 'Got it', '原图对比': 'Image comparison', '上一个（⌘+滚轮）': 'Previous (⌘ + scroll)', '上一个': 'Previous',
    '下一个（⌘+滚轮）': 'Next (⌘ + scroll)', '下一个': 'Next', '缩小': 'Zoom out', '放大': 'Zoom in', '重置为适合窗口': 'Fit to window',
    '加载中…': 'Loading…', '原图': 'Original', '压缩后': 'Compressed', '文件名': 'Filename', '原图大小': 'Original size', '节省': 'Saved',
    '算法': 'Algorithm', '重新压缩质量': 'Recompress quality', '重新压缩': 'Recompress', '恢复原图': 'Restore original',
    '自动（跟随系统）': 'Follow system', '简体中文': 'Simplified Chinese', '英语': 'English', '界面语言': 'Interface language', '语言': 'Language',
    '默认跟随系统语言；更改后界面会重新加载。': 'Follows your system language by default. The interface reloads when you change this setting.',
    '系统': 'System', '智能': 'Smart', '标准': 'Standard', '覆盖': 'Replace', '后缀': 'Suffix', '目录': 'Folder',
    '原图对比': 'Image comparison',
    '亮色模式': 'Light mode', '暗黑模式': 'Dark mode', '当前: ': 'Current: ', ' · 点击切换': ' · click to switch', '亮色': 'Light', '暗黑': 'Dark', '主题: ': 'Theme: ',
    '转换中…': 'Converting…', '压缩中…': 'Compressing…', '转换完成': 'Conversion complete', '压缩完成': 'Compression complete',
    '继续转换': 'Continue conversion', '继续压缩': 'Continue compression', '开始转换': 'Start conversion', '开始压缩': 'Start compression',
    '选择图片失败，请重试': 'Could not select images. Please try again.', '选择文件夹失败，请重试': 'Could not select a folder. Please try again.',
    '请选择系统转换文件的输出文件夹': 'Choose an output folder for system conversion.', '无法读取拖入文件，请使用“选择文件”': 'Could not read the dropped files. Use “Choose Files” instead.',
    '读取图片失败，请重试': 'Could not read the images. Please try again.', '文件夹中没有找到可压缩的图片': 'No supported images found in the folder.',
    '所选图片已在队列中': 'The selected images are already in the queue.', '添加图片失败，请重试': 'Could not add images. Please try again.',
    '已跳过': 'Skipped', '只处理这几个': 'Process selected files only', '处理过': 'Processed', '已处理': ' processed', ' · 失败 ': ' · failed ',
    ' · 已暂停': ' · paused', ' · 正在停止': ' · stopping', '还有几个在跑': 'Some files are still processing', '上限 / 可用并行数': 'Limit / available workers',
    '同时允许几份 CPU 并行压缩工作': 'Maximum concurrent CPU compression tasks', ' · CPU 自动': ' · CPU automatic', '失败': 'Failed', '已恢复': 'Restored', '已移除': 'Removed',
    '等待中': 'Waiting', '已暂停': 'Paused', '移除': 'Remove', '删除这次压缩结果': 'Delete compressed file', '另存为': 'Save as', '对比查看': 'Compare',
    '在访达中显示': 'Show in Finder', '重试': 'Retry', '复制日志': 'Copy log', '版本: ': 'Version: ', '=== OctoShrink 压缩日志 ===': '=== OctoShrink compression log ===',
    '=== OctoShrink 压缩历史 ===': '=== OctoShrink compression history ===', '文件: ': 'File: ', '时间: ': 'Time: ', '状态: ': 'Status: ', '成功': 'Succeeded',
    '--- 压缩参数 ---': '--- Compression settings ---', '(未设置)': '(not set)', '--- 压缩结果 ---': '--- Compression result ---', '--- 原图备份 ---': '--- Original backup ---', '未知错误': 'Unknown error', '原始大小: ': 'Original size: ',
    '压缩后大小: ': 'Compressed size: ', '压缩率: ': 'Compression ratio: ', '输出格式: ': 'Output format: ', '(未知)': '(unknown)', '算法: ': 'Algorithm: ',
    '压缩失败': 'Compression failed', '--- 错误信息 ---': '--- Error details ---', '(无)': '(none)', '压缩日志已复制到剪贴板': 'Compression log copied to clipboard.',
    '复制失败，请手动选中日志文本': 'Could not copy. Select and copy the log manually.', '请先选择输出目录': 'Choose an output folder first.', '确定要清空全部 ': 'Clear all ',
    ' 个文件吗？': ' files?', '无法确认输出目录，请重试': 'Could not verify the output folder. Please try again.', '转换出错: ': 'Conversion error: ', '压缩出错: ': 'Compression error: ',
    '已重新压缩: ': 'Recompressed: ', '无法保存：找不到压缩文件': 'Could not save: compressed file not found.', '已保存到: ': 'Saved to: ',
    '这个文件在压缩后又被修改过。\n恢复原图会覆盖当前版本。': 'This file was changed after compression.\nRestoring the original will overwrite the current version.',
    '恢复失败: ': 'Restore failed: ', '恢复失败': 'Restore failed', '已恢复原图: ': 'Original restored: ', '已删除这次压缩结果: ': 'Deleted compressed file: ',
    '确定要恢复全部已压缩成功的原图吗？': 'Restore all originals that were compressed successfully?', '已导出 ': 'Exported ', ' 个文件到原目录（': ' files to the original folder (', ' 后缀）': ' suffix)',
    '正在停止…': 'Stopping…', '收尾中…': 'Finishing…', ' 暂停中…': ' Pausing…', '继续压缩剩余文件': 'Continue compressing remaining files',
    '暂停：不再启动新文件': 'Pause: do not start new files', '停止：正在处理的文件会先完成，其余文件保留在队列中': 'Stop: current files will finish; the rest stay in the queue',
    ' 处理完成 · ': ' completed · ', ' 个失败': ' failed', '暂停失败，请重试': 'Could not pause. Please try again.', '继续失败，请重试': 'Could not resume. Please try again.',
    '正在停止：正在处理的文件会先完成，其余文件保留在队列中': 'Stopping: current files will finish; the rest stay in the queue', '停止失败，请重试': 'Could not stop. Please try again.',
    '今天 ': 'Today ', '昨天 ': 'Yesterday ', '检测到可恢复的原图备份': 'A recoverable original backup was found', '原图备份已清理': 'Original backup was cleaned up',
    '原图未覆盖': 'Original was not overwritten', '原文件位置不存在': 'Original file location does not exist', '已压缩': 'Compressed', '压缩结果已不存在': 'Compressed file no longer exists',
    '打开对比窗口失败: ': 'Could not open comparison window: ', '删除这次压缩结果？\n将删除 ': 'Delete this compressed file?\nThis will delete ',
    '，并移除这条历史记录。原图未被覆盖，不受影响。': '. This history entry will be removed. The original was not overwritten.', '明细: 已丢失（这条记录是按原图备份重建出来的）': 'Details unavailable (this entry was rebuilt from the original backup)',
    '输出: ': 'Output: ', '输出方式: ': 'Output mode: ', '明细已丢失': 'Details unavailable', '节省 ': 'Saved ', '按备份重建': 'Rebuilt from backup', ' 条': ' entries',
    '压缩进行中，这一批结束后才能清空历史': 'Compression is in progress. Clear history after this batch finishes.', '读取历史记录失败': 'Could not read compression history.',
    '确定要清空 ': 'Clear ', ' 条历史记录吗？\n': ' history entries?\n', '同时立即删除 OctoShrink 保存的 ': 'Also delete the ',
    ' 份原图备份，不必等保留期到期。不会删除你的任何图片文件。': ' original backups saved by OctoShrink. Your image files will not be deleted.',
    'OctoShrink 目前没有保存原图备份，这次只清记录。不会删除你的任何图片文件。': 'OctoShrink has no saved original backups. Only history will be cleared; your image files will not be deleted.',
    '不会删除你的任何图片文件': 'Your image files will not be deleted', '已清空 ': 'Cleared ', ' 条历史记录': ' history entries', '清空失败: ': 'Could not clear history: ',
    '原图备份改为不保留，关闭应用时清理记录和备份': 'Original backups will not be kept. History and backups are cleared when the app closes.',
    '原图备份保留 ': 'Keep original backups for ', ' 天，关闭应用时清理过期项': ' days; expired items are cleared when the app closes.', '设置失败: ': 'Could not save settings: ',
    '过期的历史记录和原图备份将在关闭应用时自动清理。': 'Expired history and original backups are cleared automatically when the app closes.', '关掉备份': 'Disable backups', '下次启动': 'next launch',
    ' 核 CPU（': '-core CPU (', ' 性能核 + ': ' performance + ', ' 能效核）': ' efficiency cores)', ' 个物理核心 · ': ' physical cores · ', ' 个逻辑处理器': ' logical processors',
    '最多 ': 'Up to ', ' 份并行计算': ' parallel workers', '自动（': 'Automatic (', '（全部）': '(all)', 'CPU 上限改为自动（': 'CPU limit set to automatic (',
    'CPU 上限改为 ': 'CPU limit set to ', '没有可对比的结果': 'No results to compare', '打开对比失败: ': 'Could not open comparison: ',
    '检查中': 'Checking…', '立即更新': 'Update now', ' 可用': ' available', '已是最新版本': 'You are up to date', '检查失败': 'Check failed', '下载中 0%': 'Downloading 0%',
    '下载中 ': 'Downloading ', '安装中…': 'Installing…', '更新失败': 'Update failed', '已取消': 'Cancelled', '在线更新检查失败:': 'Online update check failed:',
    '暂无可对比的内容': 'Nothing to compare', '无法加载原图，文件可能已被移动或恢复': 'Could not load the original. It may have been moved or restored.',
    '无法加载压缩图，文件可能已被移动或恢复': 'Could not load the compressed image. It may have been moved or restored.', '打开对比失败: ': 'Could not open comparison: ',
    '重新压缩预览加载失败': 'Could not load the recompression preview', '重新压缩完成 (质量: ': 'Recompression complete (quality: ', '重新压缩失败': 'Recompression failed',
    '重新压缩出错: ': 'Recompression error: ', '恢复出错: ': 'Restore error: ', '该文件已恢复原图或被移除': 'This file was restored or removed', '加载失败: ': 'Load failed: ',
    '原始大小: ': 'Original size: ', '压缩后大小 ': 'Compressed size ', '保存': 'Save'
  });
  const replacements = Object.entries(ENGLISH).sort((a, b) => b[0].length - a[0].length);

  function normalizeLocale(value) {
    const locale = String(value == null ? '' : value).trim().replace(/_/g, '-').split(/[.@]/, 1)[0].toLowerCase();
    if (!locale || locale === 'c' || locale === 'posix') return '';
    return /^[a-z]{2,3}(?:-[a-z0-9]{1,8})*$/.test(locale) ? locale : '';
  }

  function normalizePreference(value) {
    return value === 'zh' || value === 'en' ? value : 'auto';
  }

  function resolveUiLanguage(locales, preference) {
    const selected = normalizePreference(preference);
    if (selected !== 'auto') return selected;
    const candidates = Array.isArray(locales) ? locales : [locales];
    for (const candidate of candidates) {
      const locale = normalizeLocale(candidate);
      if (locale) return locale === 'zh' || locale.startsWith('zh-') ? 'zh' : 'en';
    }
    return 'en';
  }

  function readPreference(storage) {
    try { return normalizePreference(storage && storage.getItem(PREFERENCE_KEY)); } catch (_) { return 'auto'; }
  }

  function getStorage() {
    try { return root && root.localStorage; } catch (_) { return null; }
  }

  function getLocales(navigator) {
    return [...(Array.isArray(navigator && navigator.languages) ? navigator.languages : []), navigator && navigator.language];
  }

  function translateText(value, language) {
    let text = String(value == null ? '' : value);
    if ((language || currentLanguage) !== 'en') return text;
    for (const [source, translated] of replacements) text = text.split(source).join(translated);
    return text;
  }

  let currentLanguage = 'en';
  let currentPreference = 'auto';
  const originalElementText = new WeakMap();
  const boundSelectors = new WeakSet();

  function applyToDocument(document, locales, preference) {
    if (!document) return currentLanguage;
    currentPreference = normalizePreference(preference == null ? readPreference(getStorage()) : preference);
    currentLanguage = resolveUiLanguage(locales == null ? getLocales(root && root.navigator) : locales, currentPreference);
    document.documentElement.lang = currentLanguage === 'zh' ? 'zh-Hans' : 'en';
    document.documentElement.dataset.uiLanguage = currentLanguage;
    document.documentElement.dataset.languagePreference = currentPreference;
    document.title = translateText(document.title, currentLanguage);

    const apply = () => {
      const scope = document.body || document.documentElement;
      for (const element of scope.querySelectorAll('[data-i18n-zh]')) {
        if (!originalElementText.has(element)) originalElementText.set(element, element.textContent);
        element.textContent = currentLanguage === 'zh' ? element.getAttribute('data-i18n-zh') : originalElementText.get(element);
      }

      const NodeFilterType = document.defaultView && document.defaultView.NodeFilter;
      const walker = document.createTreeWalker(scope, NodeFilterType ? NodeFilterType.SHOW_TEXT : 4);
      let node;
      while ((node = walker.nextNode())) {
        node.nodeValue = translateText(node.nodeValue, currentLanguage);
      }

      const translatedAttributes = ['title', 'aria-label', 'aria-description', 'placeholder', 'alt'];
      for (const element of scope.querySelectorAll('*')) {
        for (const attribute of translatedAttributes) {
          if (element.hasAttribute(attribute)) {
            const value = element.getAttribute(attribute);
            element.setAttribute(attribute, translateText(value, currentLanguage));
          }
        }
      }

      const selector = document.getElementById('languagePreference');
      if (selector) {
        selector.value = currentPreference;
        if (!boundSelectors.has(selector)) {
          boundSelectors.add(selector);
          selector.addEventListener('change', () => {
            const nextPreference = normalizePreference(selector.value);
            try { root.localStorage.setItem(PREFERENCE_KEY, nextPreference); } catch (_) {}
            if (root && root.location && typeof root.location.reload === 'function') root.location.reload();
          });
        }
      }
    };

    if (document.body) apply();
    else document.addEventListener('DOMContentLoaded', apply, { once: true });
    return currentLanguage;
  }

  const api = Object.freeze({
    preferenceKey: PREFERENCE_KEY,
    normalizeLocale,
    normalizePreference,
    resolveUiLanguage,
    translateText,
    readPreference,
    applyUiLanguage: applyToDocument,
    applyToDocument,
    get language() { return currentLanguage; },
    get preference() { return currentPreference; }
  });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;

  if (root && root.document) {
    root.OctoShrinkI18n = api;
    api.applyToDocument(root.document);
  }
})(typeof window === 'undefined' ? globalThis : window);
