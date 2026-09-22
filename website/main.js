(() => {
  const menuButton = document.querySelector('.menu-toggle');
  const mobileNav = document.querySelector('#mobileNav');
  const range = document.querySelector('#compressionRange');
  const value = document.querySelector('#compressionValue');
  const size = document.querySelector('#compressionSize');
  const meterFill = document.querySelector('#meterFill');
  const year = document.querySelector('#currentYear');

  if (year) year.textContent = String(new Date().getFullYear());

  if (menuButton && mobileNav) {
    menuButton.addEventListener('click', () => {
      const isOpen = menuButton.getAttribute('aria-expanded') === 'true';
      menuButton.setAttribute('aria-expanded', String(!isOpen));
      mobileNav.classList.toggle('is-open', !isOpen);
    });

    mobileNav.querySelectorAll('a').forEach((link) => {
      link.addEventListener('click', () => {
        menuButton.setAttribute('aria-expanded', 'false');
        mobileNav.classList.remove('is-open');
      });
    });
  }

  function updateCompressionDemo() {
    if (!range || !value || !size || !meterFill) return;
    const compression = Number(range.value);
    const sizeInMb = 12.4 * (1 - compression * 0.01015);
    const saved = Math.max(1, 100 - Math.round(sizeInMb / 12.4 * 100));
    value.textContent = `${compression}%`;
    size.textContent = `${sizeInMb.toFixed(1)} MB`;
    meterFill.style.width = `${compression}%`;
    meterFill.parentElement?.setAttribute('aria-valuenow', String(compression));
    document.documentElement.style.setProperty('--demo-saved', `${saved}%`);
  }
  range?.addEventListener('input', updateCompressionDemo);
  updateCompressionDemo();

  const revealItems = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries, currentObserver) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          currentObserver.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -30px' });
    revealItems.forEach((item) => observer.observe(item));
  } else {
    revealItems.forEach((item) => item.classList.add('is-visible'));
  }

  const glow = document.querySelector('.cursor-glow');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (glow && !reducedMotion) {
    window.addEventListener('pointermove', (event) => {
      glow.style.left = `${event.clientX}px`;
      glow.style.top = `${event.clientY}px`;
    }, { passive: true });
  }
})();
