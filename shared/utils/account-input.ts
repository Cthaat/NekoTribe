import { z } from 'zod/v3';

// Keep new identifiers aligned with the existing Nuxt registration forms.
const email = z.string().email();
export function validNewEmail(value: string): boolean {
  return email.safeParse(value).success;
}

export function validRegistrationName(value: string): boolean {
  return value.length >= 2;
}
