import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({
  featureId: 'passkey-auth',
  revision: 1,
  expectedSteps: 4,
  scope: 'Oracle metadata only. Apply Passkey credential and challenge tables through the Nuxt migration CLI.',
});
