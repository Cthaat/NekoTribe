import {resolve} from 'node:path';
import {buildTermsMaintenanceBundle} from './lib/ai-public-terms-build.mjs';
await buildTermsMaintenanceBundle({outfile:resolve('.output/server/ai-terms-maintenance.cjs')});
