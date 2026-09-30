/**
 * snapshot.js — In-page DOM snapshot for Jev / Qavo action space.
 * Extracts indexed interactive elements, visible text, and page metadata.
 */
(() => {
  const isVisible = (el) => {
    if (!el || el.nodeType !== 1) return false;
    const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
    if (style && (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0')) {
      return false;
    }
    const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
    if (rect && (rect.width === 0 || rect.height === 0)) return false;
    return true;
  };

  const getAccessibleName = (el) => {
    return (
      el.getAttribute('aria-label') ||
      el.getAttribute('title') ||
      el.getAttribute('placeholder') ||
      (el.innerText ? el.innerText.trim().replace(/\s+/g, ' ') : '') ||
      el.getAttribute('name') ||
      el.getAttribute('value') ||
      el.getAttribute('id') ||
      ''
    );
  };

  const getRole = (el) => {
    const roleAttr = el.getAttribute('role');
    if (roleAttr) return roleAttr;
    const tag = el.tagName.toLowerCase();
    if (tag === 'button') return 'button';
    if (tag === 'a' && el.hasAttribute('href')) return 'link';
    if (tag === 'input') {
      const type = el.getAttribute('type') || 'text';
      if (['button', 'submit', 'reset'].includes(type)) return 'button';
      if (['checkbox', 'radio'].includes(type)) return type;
      return 'textbox';
    }
    if (tag === 'select') return 'combobox';
    if (tag === 'textarea') return 'textbox';
    return tag;
  };

  const interactiveSelectors = [
    'button',
    'a[href]',
    'input:not([type="hidden"])',
    'select',
    'textarea',
    '[role="button"]',
    '[role="link"]',
    '[role="tab"]',
    '[role="menuitem"]',
    '[role="checkbox"]',
    '[role="switch"]',
    '[role="combobox"]',
    '[role="option"]',
    '[tabindex]:not([tabindex="-1"])',
    '[onclick]'
  ];

  const elements = [];
  const nodes = document.querySelectorAll(interactiveSelectors.join(','));
  let index = 1;

  for (const node of nodes) {
    if (!isVisible(node)) continue;
    if (node.disabled || node.getAttribute('aria-disabled') === 'true') continue;

    const role = getRole(node);
    const name = getAccessibleName(node);
    const href = node.getAttribute('href') || null;
    const value = node.value || null;
    const checked = node.checked || node.getAttribute('aria-checked') === 'true' || null;
    const expanded = node.getAttribute('aria-expanded') === 'true' || null;

    // Supported operations for this element
    const ops = [];
    if (['button', 'link', 'checkbox', 'switch', 'tab', 'menuitem', 'option'].includes(role) || node.hasAttribute('href') || node.hasAttribute('onclick')) {
      ops.push('CLICK');
    }
    if (['textbox', 'searchbox'].includes(role) || (node.tagName.toLowerCase() === 'input' && !['checkbox', 'radio', 'button', 'submit'].includes(node.type))) {
      ops.push('TYPE_TEXT');
    }
    if (role === 'combobox' || node.tagName.toLowerCase() === 'select') {
      ops.push('SELECT');
    }

    elements.push({
      index: index++,
      role,
      name: name.slice(0, 80),
      href,
      value,
      checked,
      expanded,
      operations: ops,
      tag: node.tagName.toLowerCase()
    });
  }

  // Get visible page text summary
  const bodyText = (document.body ? document.body.innerText : '')
    .split('\n')
    .map(s => s.trim())
    .filter(Boolean)
    .slice(0, 50)
    .join(' \u00b7 ');

  return {
    url: window.location.href,
    title: document.title || '',
    text: bodyText.slice(0, 1000),
    elements,
    timestamp: Date.now()
  };
})();
