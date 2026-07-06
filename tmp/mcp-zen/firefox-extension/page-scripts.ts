// In-page JS, injected via browser.tabs.executeScript({ code }). Ported from
// zen-mcp's WebDriver BiDi script.callFunction bodies (server.mjs) -- pure
// DOM code, framework-agnostic, so it translates directly.
//
// Every builder returns a self-invoking function whose completion value
// becomes executeScript's result. wait-for relies on Firefox-specific
// behavior: if the injected script's completion value is a Promise,
// executeScript awaits it before resolving -- that's how a single round
// trip can poll internally instead of the caller polling repeatedly.

import type { FillFormField, ScrollDirection, SnapshotFilter } from "@mcp-zen/common";

const SELECTOR_MAP: Record<SnapshotFilter, string> = {
  all: 'input, textarea, select, button, a, [role="button"], [role="link"], [role="checkbox"], [role="radio"], h1, h2, h3, h4, h5, h6, p, label, li',
  interactive:
    'input, textarea, select, button, a, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [contenteditable]',
  form: "input, textarea, select",
};

export function snapshotScript(filter: SnapshotFilter, selector: string | null): string {
  return `(function() {
    const filter = ${JSON.stringify(filter)};
    const sel = ${JSON.stringify(selector)};
    const selectorMap = ${JSON.stringify(SELECTOR_MAP)};
    const scope = sel ? document.querySelector(sel) : document;
    if (!scope) return { error: 'Selector not found: ' + sel };

    const elements = scope.querySelectorAll(selectorMap[filter] || selectorMap.all);
    const items = [];

    elements.forEach((el) => {
      const tag = el.tagName.toLowerCase();
      const rect = el.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) return;
      if (getComputedStyle(el).display === 'none') return;

      let elSelector = tag;
      if (el.id) elSelector = '#' + el.id;
      else if (el.name) elSelector = tag + '[name="' + el.name + '"]';
      else if (el.getAttribute('aria-label')) elSelector = tag + '[aria-label="' + el.getAttribute('aria-label') + '"]';

      const info = { tag, selector: elSelector };
      if (el.type) info.type = el.type;
      if (el.name) info.name = el.name;
      if (el.id) info.id = el.id;
      if (el.value !== undefined && el.value !== '') info.value = String(el.value).substring(0, 200);
      if (el.placeholder) info.placeholder = el.placeholder;
      if (el.checked !== undefined) info.checked = el.checked;
      if (el.href) info.href = el.href;
      const role = el.getAttribute('role');
      if (role) info.role = role;
      const ariaLabel = el.getAttribute('aria-label');
      if (ariaLabel) info.ariaLabel = ariaLabel;

      const label = el.closest('label')?.textContent?.trim()?.substring(0, 100)
        || (el.id && document.querySelector('label[for="' + el.id + '"]')?.textContent?.trim()?.substring(0, 100))
        || '';
      if (label) info.label = label;

      if (!['input', 'textarea', 'select'].includes(tag)) {
        const txt = el.textContent?.trim()?.substring(0, 120);
        if (txt) info.text = txt;
      }

      items.push(info);
    });

    return { count: items.length, elements: items };
  })()`;
}

export function clickScript(selector: string): string {
  return `(function() {
    const sel = ${JSON.stringify(selector)};
    const el = document.querySelector(sel);
    if (!el) return { error: 'Element not found: ' + sel };
    el.scrollIntoView({ block: 'center' });
    el.click();
    return { clicked: sel };
  })()`;
}

export function fillScript(selector: string, value: string): string {
  return `(function() {
    const sel = ${JSON.stringify(selector)};
    const val = ${JSON.stringify(value)};
    const el = document.querySelector(sel);
    if (!el) return { error: 'Not found: ' + sel };
    el.focus();
    el.scrollIntoView({ block: 'center' });

    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
    if (setter) setter.call(el, val);
    else el.value = val;

    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
    return { filled: sel, value: el.value.substring(0, 100) };
  })()`;
}

export function selectOptionScript(selector: string, value: string): string {
  return `(function() {
    const sel = ${JSON.stringify(selector)};
    const val = ${JSON.stringify(value)};
    const select = document.querySelector(sel);
    if (!select) return { error: 'Not found: ' + sel };
    const option = Array.from(select.options).find(o => o.value === val || o.textContent.trim() === val);
    if (!option) return { error: 'Option not found: ' + val };
    select.value = option.value;
    select.dispatchEvent(new Event('change', { bubbles: true }));
    return { selected: option.value, text: option.textContent.trim() };
  })()`;
}

export function checkScript(selector: string, checked: boolean): string {
  return `(function() {
    const sel = ${JSON.stringify(selector)};
    const shouldCheck = ${JSON.stringify(checked)};
    const el = document.querySelector(sel);
    if (!el) return { error: 'Not found: ' + sel };
    el.scrollIntoView({ block: 'center' });
    if (el.checked !== shouldCheck) el.click();
    return { selector: sel, checked: el.checked };
  })()`;
}

export function fillFormScript(fields: FillFormField[]): string {
  return `(function() {
    const fields = ${JSON.stringify(fields)};
    const results = [];
    for (const field of fields) {
      const action = field.action || 'fill';
      try {
        let result;
        const el = document.querySelector(field.selector);
        if (!el) throw new Error('Not found: ' + field.selector);

        if (action === 'fill') {
          el.focus();
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          if (setter) setter.call(el, field.value);
          else el.value = field.value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (action === 'select') {
          const opt = Array.from(el.options).find(o => o.value === field.value || o.textContent.trim() === field.value);
          if (!opt) throw new Error('Option not found: ' + field.value);
          el.value = opt.value;
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (action === 'check') {
          if (!el.checked) el.click();
        } else if (action === 'uncheck') {
          if (el.checked) el.click();
        } else if (action === 'click') {
          el.click();
        }
        results.push({ selector: field.selector, action, status: 'ok' });
      } catch (e) {
        results.push({ selector: field.selector, action, status: 'error', error: e.message });
      }
    }
    return { results };
  })()`;
}

export function scrollScript(
  direction: ScrollDirection | undefined,
  amount: number | undefined,
  selector: string | undefined
): string {
  if (selector) {
    return `(function() {
      const sel = ${JSON.stringify(selector)};
      document.querySelector(sel)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return { message: 'Scrolled ' + sel + ' into view' };
    })()`;
  }
  const dir = direction ?? "down";
  const amt = amount ?? 500;
  return `(function() {
    const dir = ${JSON.stringify(dir)};
    const amt = ${JSON.stringify(amt)};
    if (dir === 'down') window.scrollBy(0, amt);
    else if (dir === 'up') window.scrollBy(0, -amt);
    else if (dir === 'top') window.scrollTo(0, 0);
    else if (dir === 'bottom') window.scrollTo(0, document.body.scrollHeight);
    return { message: 'Scrolled ' + dir + ' ' + amt + 'px' };
  })()`;
}

export function getPageTextScript(maxLength: number): string {
  return `(function() {
    const maxLen = ${JSON.stringify(maxLength)};
    return {
      title: document.title,
      url: location.href,
      text: document.body.innerText.substring(0, maxLen),
    };
  })()`;
}

export function getFormFieldsScript(): string {
  return `(function() {
    const fields = Array.from(document.querySelectorAll('input, textarea, select')).map((el, i) => {
      const tag = el.tagName.toLowerCase();
      const rect = el.getBoundingClientRect();
      let selector = tag;
      if (el.id) selector = '#' + el.id;
      else if (el.name) selector = tag + '[name="' + el.name + '"]';

      const label = el.closest('label')?.textContent?.trim()?.substring(0, 100)
        || (el.id && document.querySelector('label[for="' + el.id + '"]')?.textContent?.trim()?.substring(0, 100))
        || '';

      let options;
      if (tag === 'select') {
        options = Array.from(el.options).map(o => ({ value: o.value, text: o.textContent.trim(), selected: o.selected }));
      }

      return {
        index: i, tag, type: el.type || '', name: el.name || '',
        id: el.id || '', selector, value: (el.value || '').substring(0, 200),
        placeholder: el.placeholder || '', label,
        checked: el.type === 'checkbox' || el.type === 'radio' ? el.checked : undefined,
        required: el.required || false, disabled: el.disabled || false,
        visible: rect.width > 0 && rect.height > 0, options,
      };
    });
    return { fields };
  })()`;
}

const KEY_CODE_MAP: Record<string, string> = {
  Enter: "Enter",
  Tab: "Tab",
  Escape: "Escape",
  Backspace: "Backspace",
  Delete: "Delete",
  ArrowUp: "ArrowUp",
  ArrowDown: "ArrowDown",
  ArrowLeft: "ArrowLeft",
  ArrowRight: "ArrowRight",
  Home: "Home",
  End: "End",
  PageUp: "PageUp",
  PageDown: "PageDown",
};

export function pressKeyScript(
  key: string,
  modifiers: Array<"ctrl" | "shift" | "alt" | "meta">
): string {
  const keyValue = KEY_CODE_MAP[key] ?? key;
  const mods = modifiers ?? [];
  return `(function() {
    const key = ${JSON.stringify(keyValue)};
    const mods = ${JSON.stringify(mods)};
    const target = document.activeElement || document.body;
    const eventInit = {
      key,
      bubbles: true,
      cancelable: true,
      ctrlKey: mods.includes('ctrl'),
      shiftKey: mods.includes('shift'),
      altKey: mods.includes('alt'),
      metaKey: mods.includes('meta'),
    };
    target.dispatchEvent(new KeyboardEvent('keydown', eventInit));
    target.dispatchEvent(new KeyboardEvent('keyup', eventInit));
    const modStr = mods.length > 0 ? mods.join('+') + '+' : '';
    return { message: 'Pressed ' + modStr + key };
  })()`;
}

export function evaluateScript(script: string): string {
  const wrapped = script.includes(";") && !script.trim().startsWith("(") ? `(() => { ${script} })()` : script;
  // Wrapped in { value: ... } so an arbitrary user script that happens to
  // return an object with its own "error" key isn't misread as a script
  // failure by the generic error-sentinel check in message-handler.
  return `(function() { return { value: (${wrapped}) }; })()`;
}

export function waitForScript(
  searchText: string | undefined,
  selector: string | undefined,
  timeout: number
): string {
  return `(function() {
    const searchText = ${JSON.stringify(searchText ?? null)};
    const selector = ${JSON.stringify(selector ?? null)};
    const timeout = ${JSON.stringify(timeout)};
    const pollInterval = 250;
    const start = Date.now();

    function check() {
      if (searchText) return document.body.innerText.includes(searchText);
      if (selector) return document.querySelector(selector) !== null;
      return false;
    }

    return new Promise((resolve) => {
      function poll() {
        const elapsedMs = Date.now() - start;
        if (check()) {
          resolve({ found: true, elapsedMs });
          return;
        }
        if (elapsedMs >= timeout) {
          resolve({ found: false, elapsedMs });
          return;
        }
        setTimeout(poll, pollInterval);
      }
      poll();
    });
  })()`;
}
