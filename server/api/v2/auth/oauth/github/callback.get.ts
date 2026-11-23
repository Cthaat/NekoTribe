import { defineEventHandler } from 'h3';
import { v2GitHubCallback } from '~/server/services/v2/github-oauth';
export default defineEventHandler(v2GitHubCallback);
