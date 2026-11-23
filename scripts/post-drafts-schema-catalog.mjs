import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({
  featureId: 'post-drafts',
  revision: 1,
  expectedSteps: 4,
  scope: 'Oracle metadata only. Apply the post draft schema through the Nuxt migration CLI.',
});
