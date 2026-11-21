import { defineEventHandler } from 'h3';
import { readPrivateMediaContent } from '~/server/services/v2/private-media';

export default defineEventHandler(readPrivateMediaContent);
