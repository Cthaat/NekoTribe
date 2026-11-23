import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({featureId:'ai-user-provider',revision:1,expectedSteps:1,
  scope:'Read-only personal AI provider schema. A missing ledger is allowed.'});
