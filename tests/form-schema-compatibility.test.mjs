import assert from 'node:assert/strict';
import test from 'node:test';
import { toTypedSchema } from '@vee-validate/zod';
import * as z from 'zod/v3';

test('the installed form adapter validates values and reports union errors', async () => {
  const schema = toTypedSchema(z.object({
    email: z.string().trim().email(),
    contact: z.union([z.string().email(), z.literal('')])
  }));

  const valid = await schema.parse({
    email: ' member@example.test ',
    contact: ''
  });
  assert.deepEqual(valid.errors, []);
  assert.equal(valid.value.email, 'member@example.test');

  const invalid = await schema.parse({ email: 'invalid', contact: false });
  assert.deepEqual(invalid.errors.map(error => error.path).sort(), ['contact', 'email']);
  assert.ok(invalid.errors.every(error => error.errors.length > 0));
});

test('the installed form adapter describes nested required and optional fields', () => {
  const schema = toTypedSchema(z.object({
    profile: z.object({ email: z.string().email(), bio: z.string().optional() })
  }));

  assert.deepEqual(schema.describe('profile.email'), { exists: true, required: true });
  assert.deepEqual(schema.describe('profile.bio'), { exists: true, required: false });
  assert.deepEqual(schema.describe('profile.missing'), { exists: false, required: false });
});

test('the installed form adapter retains defaults while casting invalid form input', () => {
  const schema = toTypedSchema(z.object({
    email: z.string().email(),
    role: z.string().default('member'),
    profile: z.object({ language: z.string().default('zh') })
  }));

  assert.deepEqual(schema.cast({ email: 'invalid' }), {
    email: 'invalid', role: 'member', profile: { language: 'zh' }
  });
});

test('password confirmation refinements retain the field error path', async () => {
  const schema = toTypedSchema(z.object({
    password: z.string().min(6),
    confirmPassword: z.string().min(6)
  }).refine(value => value.password === value.confirmPassword, {
    path: ['confirmPassword'], message: 'Passwords must match'
  }));

  const invalid = await schema.parse({ password: 'example-one', confirmPassword: 'example-two' });
  assert.deepEqual(invalid.errors, [{ path: 'confirmPassword', errors: ['Passwords must match'] }]);
  assert.deepEqual((await schema.parse({ password: 'example-one', confirmPassword: 'example-one' })).errors, []);
});
