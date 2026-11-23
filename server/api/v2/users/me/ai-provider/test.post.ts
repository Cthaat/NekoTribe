import { defineEventHandler } from 'h3';
import { testUserProvider } from '~/server/services/ai/user-provider';

export default defineEventHandler(testUserProvider);
