import { defineEventHandler } from 'h3';
import {
  sentimentFlowIntegrationInfo,
  type SentimentFlowIntegrationInfo
} from '~/server/utils/sentiment-flow';

export default defineEventHandler(
  (): V2Response<SentimentFlowIntegrationInfo> => ({
    code: 200,
    message: 'sentimentflow config',
    data: sentimentFlowIntegrationInfo(),
    meta: null
  })
);
