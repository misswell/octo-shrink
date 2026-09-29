const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { applyUiLanguage, normalizeLocale, resolveUiLanguage } = require('../frontend/i18n.js');

const html = fs.readFileSync(path.join(__dirname, '..', 'frontend', 'index.html'), 'utf8');

assert.match(html, /<html lang="en">/, 'English is the startup fallback');
assert.match(html, /<script src="i18n\.js"><\/script>/);
assert.match(html, /<h2 data-i18n-zh="拖拽图片或文件夹到此处">Drop images or folders here<\/h2>/);
assert.match(html, /<p data-i18n-zh="支持 PNG、JPG、GIF、WebP、BMP 格式 · 自动批量压缩">Supports PNG, JPG, GIF, WebP, and BMP · Automatic batch compression<\/p>/);
assert.match(html, /<span data-i18n-zh="选择文件">Choose Files<\/span>/);
assert.match(html, /<span data-i18n-zh="选择文件夹">Choose Folder<\/span>/);

assert.equal(normalizeLocale('C.UTF-8'), '');
assert.equal(normalizeLocale('en_US.UTF-8'), 'en-us');
assert.equal(resolveUiLanguage(['C', '']), 'en');
assert.equal(resolveUiLanguage(['en-US']), 'en');
assert.equal(resolveUiLanguage(['fr-FR']), 'en');
assert.equal(resolveUiLanguage(['zh-CN', 'en-US']), 'zh');

const englishNode = { textContent: 'Drop images or folders here', getAttribute: () => '拖拽图片或文件夹到此处' };
const english = { documentElement: {}, readyState: 'complete', querySelectorAll: () => [englishNode] };
assert.equal(applyUiLanguage(english, ['C']), 'en');
assert.equal(english.documentElement.lang, 'en');
assert.equal(englishNode.textContent, 'Drop images or folders here');

const chineseNode = { textContent: 'Drop images or folders here', getAttribute: () => '拖拽图片或文件夹到此处' };
const chinese = { documentElement: {}, readyState: 'complete', querySelectorAll: () => [chineseNode] };
assert.equal(applyUiLanguage(chinese, ['zh-CN']), 'zh');
assert.equal(chinese.documentElement.lang, 'zh-Hans');
assert.equal(chineseNode.textContent, '拖拽图片或文件夹到此处');

console.log('Locale fallback markup checks passed');
