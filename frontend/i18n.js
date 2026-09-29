(function attachOctoShrinkI18n(root) {
  'use strict';

  function normalizeLocale(value) {
    const locale = String(value == null ? '' : value)
      .trim()
      .replace(/_/g, '-')
      .split(/[.@]/, 1)[0]
      .toLowerCase();
    if (!locale || locale === 'c' || locale === 'posix') return '';
    return /^[a-z]{2,3}(?:-[a-z0-9]{1,8})*$/.test(locale) ? locale : '';
  }

  function resolveUiLanguage(locales) {
    const candidates = Array.isArray(locales) ? locales : [locales];
    for (const candidate of candidates) {
      const locale = normalizeLocale(candidate);
      if (locale) return locale === 'zh' || locale.startsWith('zh-') ? 'zh' : 'en';
    }
    return 'en';
  }

  function applyUiLanguage(document, locales) {
    const language = resolveUiLanguage(locales);
    const isChinese = language === 'zh';
    document.documentElement.lang = isChinese ? 'zh-Hans' : 'en';

    const apply = () => {
      for (const element of document.querySelectorAll('[data-i18n-zh]')) {
        if (isChinese) element.textContent = element.getAttribute('data-i18n-zh');
      }
    };
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', apply, { once: true });
    } else {
      apply();
    }
    return language;
  }

  const api = Object.freeze({ normalizeLocale, resolveUiLanguage, applyUiLanguage });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;

  if (root && root.document) {
    root.OctoShrinkI18n = api;
    const navigator = root.navigator || {};
    const locales = [
      ...(Array.isArray(navigator.languages) ? navigator.languages : []),
      navigator.language,
    ];
    api.applyUiLanguage(root.document, locales);
  }
})(typeof window === 'undefined' ? globalThis : window);
