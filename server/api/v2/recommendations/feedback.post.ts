import { defineEventHandler } from 'h3';
import { v2RecommendationFeedback } from '~/server/services/v2/posts';

export default defineEventHandler(v2RecommendationFeedback);
