import { defineEventHandler } from 'h3';
import { deleteUserProvider } from '~/server/services/ai/user-provider';

export default defineEventHandler(deleteUserProvider);
