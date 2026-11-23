import { defineEventHandler } from 'h3';
import { readAiOperations } from '~/server/services/ai/operations';

export default defineEventHandler(readAiOperations);
