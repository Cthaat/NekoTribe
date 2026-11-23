import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({
  featureId: 'github-oauth',
  revision: 1,
  expectedSteps: 3,
  scope: 'Oracle metadata only. Apply GitHub OAuth links and flow state through the Nuxt migration CLI.',
});
