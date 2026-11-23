import { defineEventHandler } from 'h3';
import { saveUserProvider } from '~/server/services/ai/user-provider';

export default defineEventHandler(saveUserProvider);
