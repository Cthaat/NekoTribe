import { v2GetGitHubLink } from '~/server/services/v2/github-oauth';
import { defineV2Handler } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry(v2GetGitHubLink));
