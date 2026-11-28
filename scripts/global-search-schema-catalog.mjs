import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';
syncSchemaCatalog({ featureId: 'global-search', revision: 1, expectedSteps: 3,
  scope: 'Read-only search history table and ordered indexes; apply only through the explicit migration CLI.' });
