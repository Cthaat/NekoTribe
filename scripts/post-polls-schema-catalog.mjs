import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({
  featureId: 'post-polls',
  revision: 1,
  expectedSteps: 5,
  scope: 'Oracle metadata only. Apply post poll schema through the Nuxt migration CLI.',
});
