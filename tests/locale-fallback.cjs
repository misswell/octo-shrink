const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {
  applyUiLanguage,
  normalizeLocale,
  normalizePreference,
  readPreference,
  resolveUiLanguage,
  translateText,
} = require('../frontend/i18n.js');

const frontend = path.join(__dirname, '..', 'frontend');
const html = fs.readFileSync(path.join(frontend, 'index.html'), 'utf8');
const compareHtml = fs.readFileSync(path.join(frontend, 'compare.html'), 'utf8');
const appJs = fs.readFileSync(path.join(frontend, 'app.js'), 'utf8');

function assertEnglishStaticMarkup(markup, filename) {
  const visibleMarkup = markup
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<script\b[\s\S]*?<\/script>/gi, '')
    .replace(/<style\b[\s\S]*?<\/style>/gi, '');
  const textNodes = [...visibleMarkup.matchAll(/>([^<>]+)</g)].map(match => match[1].trim()).filter(Boolean);
  const attributes = [...visibleMarkup.matchAll(/\b(?:title|aria-label|aria-description|placeholder|alt)="([^"]*)"/g)].map(match => match[1]);
  const untranslated = [...textNodes, ...attributes]
    .map(value => translateText(value, 'en'))
    .filter(value => /[\u3400-\u9fff]/.test(value));
  assert.deepEqual(untranslated, [], `${filename} has visible static Chinese strings without English translations`);
}

assertEnglishStaticMarkup(html, 'index.html');
assertEnglishStaticMarkup(compareHtml, 'compare.html');

assert.match(html, /<html lang="en">/, 'English remains a safe initial document language');
assert.match(html, /<script src="i18n\.js"><\/script>/);
assert.match(html, /id="languagePreference" class="settings-select"/);
assert.match(html, /<option value="auto">自动（跟随系统）<\/option>/);
assert.match(html, /<option value="zh">简体中文<\/option>/);
assert.match(html, /<option value="en">英语<\/option>/);
assert.match(html, /OctoShrinkI18n\.applyToDocument\(document\)/);
assert.match(html, /<h2 data-i18n-zh="拖拽图片或文件夹到此处">Drop images or folders here<\/h2>/);
assert.match(html, /<p data-i18n-zh="支持 PNG、JPG、GIF、WebP、BMP 格式 · 自动批量压缩">Supports PNG, JPG, GIF, WebP, and BMP · Automatic batch compression<\/p>/);
assert.match(html, /<span data-i18n-zh="选择文件">Choose Files<\/span>/);
assert.match(html, /<span data-i18n-zh="选择文件夹">Choose Folder<\/span>/);
assert.match(compareHtml, /<script src="i18n\.js"><\/script>/, 'the comparison window uses the same language preference');
assert.match(compareHtml, /OctoShrinkI18n\.applyToDocument\(document\)/);
assert.match(appJs, /localizeUiText\('压缩中…'\)/, 'runtime UI messages go through the translation catalog');

assert.equal(normalizeLocale('C.UTF-8'), '');
assert.equal(normalizeLocale('en_US.UTF-8'), 'en-us');
assert.equal(normalizePreference('invalid'), 'auto');
assert.equal(resolveUiLanguage(['C', '']), 'en');
assert.equal(resolveUiLanguage(['en-US']), 'en');
assert.equal(resolveUiLanguage(['fr-FR']), 'en');
assert.equal(resolveUiLanguage(['zh-CN', 'en-US']), 'zh');
assert.equal(resolveUiLanguage(['zh-CN'], 'en'), 'en', 'manual English overrides the system locale');
assert.equal(resolveUiLanguage(['en-US'], 'zh'), 'zh', 'manual Chinese overrides the system locale');
assert.equal(readPreference({ getItem: () => 'zh' }), 'zh');
assert.equal(readPreference({ getItem: () => 'invalid' }), 'auto');
assert.equal(translateText('Q75 · 原格式 · 智能 · 覆盖', 'en'), 'Q75 · Original format · Smart · Replace');
assert.equal(translateText('压缩设置', 'en'), 'Compression settings');
assert.equal(translateText('原图对比', 'en'), 'Image comparison');
assert.equal(translateText('压缩设置', 'zh'), '压缩设置');
assert.equal(translateText('已保存到: ', 'en') + '原格式.png', 'Saved to: 原格式.png', 'user file names remain untouched');

function settingsSummary(language) {
  const summary = { textContent: '' };
  const controls = {
    autoCompress: { checked: false },
    qualitySlider: { value: '75' },
    outputFormat: { value: 'original' },
    smartMode: { checked: true },
    settingsSummary: summary,
  };
  const context = vm.createContext({
    window: { OctoShrinkI18n: { translateText: value => translateText(value, language) } },
    document: { getElementById: id => controls[id] || null, querySelector: () => ({ value: 'replace' }) },
    processingMode: 'advanced',
    getOutputSuffix: () => '_compressed',
  });
  const start = appJs.indexOf('function updateSettingsSummary()');
  const end = appJs.indexOf('function resetSettings()', start);
  assert.ok(start >= 0 && end > start, 'the settings summary function remains available');
  vm.runInContext(`function localizeUiText(value) { return window.OctoShrinkI18n.translateText(value); }\n${appJs.slice(start, end)}`, context);
  context.updateSettingsSummary();
  return summary.textContent;
}

assert.equal(settingsSummary('en'), 'Q75 · Original format · Smart · Replace');
assert.equal(settingsSummary('zh'), 'Q75 · 原格式 · 智能 · 覆盖');

function makeDocument(language, initialText, chineseText) {
  const translated = { textContent: initialText, getAttribute: () => chineseText };
  const plainText = { nodeValue: 'Q75 · 原格式 · 智能 · 覆盖' };
  const body = { querySelectorAll: selector => selector === '[data-i18n-zh]' ? [translated] : [] };
  const doc = {
    body,
    title: 'OctoShrink',
    documentElement: { lang: '', dataset: {} },
    defaultView: null,
    createTreeWalker: () => {
      const nodes = [plainText];
      return { nextNode: () => nodes.shift() || null };
    },
    getElementById: () => null,
  };
  assert.equal(applyUiLanguage(doc, [language], 'auto'), language.startsWith('zh') ? 'zh' : 'en');
  return { doc, translated, plainText };
}

const english = makeDocument('C', 'Drop images or folders here', '拖拽图片或文件夹到此处');
assert.equal(english.doc.documentElement.lang, 'en');
assert.equal(english.translated.textContent, 'Drop images or folders here');
assert.equal(english.plainText.nodeValue, 'Q75 · Original format · Smart · Replace');

const chinese = makeDocument('zh-CN', 'Drop images or folders here', '拖拽图片或文件夹到此处');
assert.equal(chinese.doc.documentElement.lang, 'zh-Hans');
assert.equal(chinese.translated.textContent, '拖拽图片或文件夹到此处');
assert.equal(chinese.plainText.nodeValue, 'Q75 · 原格式 · 智能 · 覆盖');

console.log('Chinese and English locale checks passed');
