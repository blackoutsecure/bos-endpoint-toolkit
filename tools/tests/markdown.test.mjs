import assert from 'node:assert/strict';
import test from 'node:test';
import { lint } from 'markdownlint/promise';

test('Markdownlint API retains real validation without CLI glob dependencies', async () => {
  const results = await lint({
    strings: { valid: '# Title\n\nText.\n', invalid: '# Title\nText.\n' }
  });
  assert.equal(results.valid.length, 0);
  assert.ok(results.invalid.some(error => error.ruleNames.includes('MD022')));
});

test('patched math parser remains compatible with Markdownlint', async () => {
  const results = await lint({ strings: { math: '# Title\n\n$$\nx^2 + y^2 = z^2\n$$\n' } });
  assert.equal(results.math.length, 0);
});
