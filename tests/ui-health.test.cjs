'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { hasVisibleRecoveryAlert } = require('../tweak/index.js');

function heading(text, { hidden = false, recovery = false } = {}) {
  return {
    textContent: text,
    getClientRects: () => hidden ? [] : [{}],
    closest: selector => selector === '.bg-surface-recovery' && recovery ? {} : null
  };
}
function doc(alertHeadings) {
  return {
    // Reading all chat text was the regression. A normal message quoting the
    // error must not even be inspected by the recovery detector.
    get body() { throw new Error('Conversation text must not be scanned'); },
    querySelectorAll: () => alertHeadings
  };
}
test('conversation quoting the snag message does not indicate an app crash', () => {
  assert.equal(hasVisibleRecoveryAlert(doc([])), false);
});
test('visible native recovery alert indicates a crash', () => {
  assert.equal(hasVisibleRecoveryAlert(doc([heading('ChatGPT hit a snag')])), true);
});
test('hidden recovery and unrelated alerts do not indicate a crash', () => {
  assert.equal(hasVisibleRecoveryAlert(doc([heading('ChatGPT hit a snag', { hidden: true }), heading('Usage notice')])), false);
});
test('localized heading in the native recovery surface remains detectable', () => {
  assert.equal(hasVisibleRecoveryAlert(doc([heading('Localized error', { recovery: true })])), true);
});
