// Image interaction layer shared by both pictures and the comparison handle.
class CompareImageViewer {
  constructor({ viewport, wrapper, images, onTransform, onUserChange }) {
    this.viewport = viewport;
    this.wrapper = wrapper;
    this.images = images;
    this.onTransform = onTransform;
    this.onUserChange = onUserChange;
    this.scale = 1;
    this.fitScale = 1;
    this.tx = 0;
    this.ty = 0;
    this.mode = 'fit';
    this.drag = null;
    this.animation = 0;
    this.bindEvents();
  }

  setTransform() {
    this.wrapper.style.transform = `translate3d(${this.tx}px, ${this.ty}px, 0) scale(${this.scale})`;
    this.viewport.classList.toggle('is-zoomed', this.mode !== 'fit');
    this.onTransform();
  }

  stopAnimation() {
    if (this.animation) cancelAnimationFrame(this.animation);
    this.animation = 0;
  }

  animateTo(scale, tx, ty, mode) {
    this.stopAnimation();
    const start = { scale: this.scale, tx: this.tx, ty: this.ty };
    const started = performance.now();
    this.mode = mode;
    const frame = (now) => {
      const p = Math.min(1, (now - started) / 160);
      const eased = 1 - Math.pow(1 - p, 3);
      this.scale = start.scale + (scale - start.scale) * eased;
      this.tx = start.tx + (tx - start.tx) * eased;
      this.ty = start.ty + (ty - start.ty) * eased;
      this.setTransform();
      this.animation = p < 1 ? requestAnimationFrame(frame) : 0;
    };
    this.animation = requestAnimationFrame(frame);
  }

  fit(animated = false) {
    const img = this.images[0];
    const w = img.naturalWidth || this.images[1].naturalWidth;
    const h = img.naturalHeight || this.images[1].naturalHeight;
    if (!w || !h) return;
    const rect = this.viewport.getBoundingClientRect();
    this.wrapper.style.width = `${w}px`;
    this.wrapper.style.height = `${h}px`;
    this.fitScale = Math.min(rect.width / w, rect.height / h, 1);
    const tx = (rect.width - w * this.fitScale) / 2;
    const ty = (rect.height - h * this.fitScale) / 2;
    if (animated) {
      this.animateTo(this.fitScale, tx, ty, 'fit');
    } else {
      this.stopAnimation();
      this.scale = this.fitScale;
      this.tx = tx;
      this.ty = ty;
      this.mode = 'fit';
      this.setTransform();
    }
  }

  zoomTo(scale, clientX, clientY, animated = false, mode = 'custom') {
    const next = Math.max(0.02, Math.min(8, scale));
    const rect = this.viewport.getBoundingClientRect();
    const x = clientX - rect.left;
    const y = clientY - rect.top;
    const ratio = next / this.scale;
    const tx = x + (this.tx - x) * ratio;
    const ty = y + (this.ty - y) * ratio;
    if (animated) {
      this.animateTo(next, tx, ty, mode);
    } else {
      this.stopAnimation();
      this.scale = next;
      this.tx = tx;
      this.ty = ty;
      this.mode = mode;
      this.setTransform();
    }
    this.onUserChange();
  }

  bindEvents() {
    this.viewport.addEventListener('wheel', (e) => {
      if (e.metaKey) return;
      e.preventDefault();
      this.zoomTo(this.scale * (e.deltaY < 0 ? 1.1 : 0.9), e.clientX, e.clientY);
    }, { passive: false });

    this.viewport.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      this.stopAnimation();
      this.viewport.setPointerCapture(e.pointerId);
      this.drag = { id: e.pointerId, x: e.clientX, y: e.clientY, tx: this.tx, ty: this.ty, moved: false };
      e.preventDefault();
    });

    this.viewport.addEventListener('pointermove', (e) => {
      if (!this.drag || e.pointerId !== this.drag.id) return;
      const dx = e.clientX - this.drag.x;
      const dy = e.clientY - this.drag.y;
      if (!this.drag.moved && Math.hypot(dx, dy) < 4) return;
      this.drag.moved = true;
      this.tx = this.drag.tx + dx;
      this.ty = this.drag.ty + dy;
      this.mode = 'custom';
      this.viewport.classList.add('is-dragging');
      this.setTransform();
      this.onUserChange();
    });

    const endDrag = (e) => {
      if (!this.drag || e.pointerId !== this.drag.id) return;
      const moved = this.drag.moved;
      this.drag = null;
      this.viewport.classList.remove('is-dragging');
      if (this.viewport.hasPointerCapture(e.pointerId)) this.viewport.releasePointerCapture(e.pointerId);
      if (e.type === 'pointercancel' || moved) return;
      if (this.mode === 'fit') {
        this.zoomTo(1, e.clientX, e.clientY, true, 'actual');
      } else {
        this.fit(true);
        this.onUserChange();
      }
    };
    this.viewport.addEventListener('pointerup', endDrag);
    this.viewport.addEventListener('pointercancel', endDrag);
  }
}
