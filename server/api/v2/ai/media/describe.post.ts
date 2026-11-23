import { defineEventHandler } from 'h3';
import { describeMedia } from '~/server/services/ai/vision-media';

export default defineEventHandler(describeMedia);
