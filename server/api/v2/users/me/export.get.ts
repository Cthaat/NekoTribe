import { defineEventHandler } from 'h3';
import { exportAccountData } from '~/server/services/v2/account-resources';

export default defineEventHandler(exportAccountData);
