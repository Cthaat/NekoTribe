import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({
  featureId: 'profile-pinned-post',
  revision: 1,
  expectedSteps: 1,
  scope: 'Oracle metadata only. Apply the profile pinned post schema through the Nuxt migration CLI.',
});
