import { defineEventHandler } from 'h3';
import { getAccountUsage } from '~/server/services/v2/account-resources';

export default defineEventHandler(getAccountUsage);
