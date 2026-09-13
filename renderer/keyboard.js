function k(label, type, value) {
  return { label, type, value: value !== undefined ? value : label };
}
function chars(str) {
  return str.split('').map((c) => k(c, 'char', c));
}

// Mirrors the layout in cursor-daemon.ps1, which owns navigation/activation —
// this file only renders whatever selection the daemon reports.
const MAIN_ROWS = [
  [...chars('1234567890'), k('⌫', 'backspace')],
  chars('qwertyuiop'),
  [...chars('asdfghjkl'), k('⏎', 'enter')],
  [k('⇧', 'shift'), ...chars('zxcvbnm'), k(',', 'char', ','), k('.', 'char', '.')],
  [k('?123', 'page'), k('←', 'left'), k('Space', 'space'), k('→', 'right'), k('⌄ Hide', 'hide')],
];
const SYMBOL_ROWS = [
  [...chars('!@#$%^&*()'), k('⌫', 'backspace')],
  chars('-_=+[]{}\\|'),
  [...chars(';:\'",.<>/?'), k('⏎', 'enter')],
  [k('ABC', 'page'), k('←', 'left'), k('Space', 'space'), k('→', 'right'), k('⌄ Hide', 'hide')],
];

const state = { page: 0, row: 0, col: 0, shift: false };

function displayLabel(key) {
  if (key.type === 'char' && state.shift && /[a-z]/i.test(key.value)) return key.value.toUpperCase();
  return key.label;
}

const kbEl = document.getElementById('kb');
function render() {
  const rows = state.page === 0 ? MAIN_ROWS : SYMBOL_ROWS;
  const row = Math.min(state.row, rows.length - 1);

  const hint = document.createElement('div');
  hint.className = 'kb-hint';
  hint.textContent = 'D-pad / left stick to move · A to type · B or Start to hide';

  const rowEls = rows.map((r, ri) => {
    const rowEl = document.createElement('div');
    rowEl.className = 'kb-row';
    r.forEach((key, ci) => {
      const keyEl = document.createElement('div');
      keyEl.className = 'kb-key';
      if (key.type === 'space') keyEl.classList.add('wide');
      if (key.type === 'shift' && state.shift) keyEl.classList.add('active');
      if (ri === row && ci === Math.min(state.col, r.length - 1)) keyEl.classList.add('selected');
      keyEl.textContent = displayLabel(key);
      rowEl.appendChild(keyEl);
    });
    return rowEl;
  });

  kbEl.replaceChildren(hint, ...rowEls);
}
render();

window.controllerMouse.onSelection((sel) => {
  state.page = sel.page;
  state.row = sel.row;
  state.col = sel.col;
  state.shift = sel.shift;
  render();
});
