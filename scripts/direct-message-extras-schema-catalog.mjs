import { syncSchemaCatalog } from './lib/vnext-schema-catalog.mjs';

syncSchemaCatalog({featureId:'direct-message-extras',revision:1,expectedSteps:3,
  scope:'Read-only direct message extras schema. A missing ledger is allowed.'});
