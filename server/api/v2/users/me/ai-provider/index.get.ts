import { defineEventHandler } from 'h3';
import { readUserProvider } from '~/server/services/ai/user-provider';

export default defineEventHandler(readUserProvider);
