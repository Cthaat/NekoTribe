import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({
  featureId: 'post-markdown',
  revision: 1,
  expectedSteps: 1,
  scope: 'Oracle metadata only. Apply Markdown post storage through the Nuxt migration CLI.',
});
