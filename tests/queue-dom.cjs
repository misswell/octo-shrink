// Minimal DOM with move/fragment semantics for exercising the real viewport.
function element(tag = 'div') {
  const node = {
    tagName: tag, children: [], style: {}, dataset: {}, handlers: {},
    className: '', scrollTop: 0, clientHeight: 260, parentNode: null,
    classList: { toggle() {}, add() {}, remove() {} },
    setAttribute(key, value) { this[key] = value; },
    addEventListener(type, handler) { this.handlers[type] = handler; },
    appendChild(child) {
      if (child.tagName === 'fragment') {
        for (const nested of child.children.slice()) this.appendChild(nested);
        return child;
      }
      if (child.parentNode) child.parentNode.removeChild(child);
      this.children.push(child); child.parentNode = this; return child;
    },
    removeChild(child) {
      this.children = this.children.filter(value => value !== child);
      child.parentNode = null;
    },
    replaceChildren(...children) {
      for (const child of this.children.slice()) this.removeChild(child);
      for (const child of children) this.appendChild(child);
    },
    remove() { if (this.parentNode) this.parentNode.removeChild(this); },
    querySelector(selector) {
      if (selector === '.error-info-btn') return null;
      this.parts ||= {};
      return this.parts[selector] ||= element('span');
    },
  };
  Object.defineProperty(node, 'innerHTML', {
    get() { return this.html || ''; },
    set(value) { this.html = value; if (!value) this.replaceChildren(); },
  });
  Object.defineProperty(node, 'textContent', {
    get() { return this.text || ''; }, set(value) { this.text = String(value); },
  });
  return node;
}

function queueDOM() {
  const controls = {
    fileQueueList: element(), queueFailedOnly: { checked: false },
    queueSortKey: { value: 'import' }, queueSortDirection: element(), queueFilterEmpty: element(),
  };
  return { controls, document: {
    getElementById: id => controls[id] || null,
    createElement: element,
    createDocumentFragment: () => element('fragment'),
  } };
}
module.exports = { element, queueDOM };
