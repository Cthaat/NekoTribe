import { defineEventHandler, setResponseHeader, setResponseStatus } from 'h3';
import contract from '../../specifications/requirements/sentiment-retirement.json';

export const retiredSentimentConfig = defineEventHandler(event => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return { code: 200, message: contract.configMessage, data: contract.config, meta: null };
});

export const retiredSentimentOperation = defineEventHandler(event => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  setResponseStatus(event, 410);
  return { code: 41001, message: contract.retiredMessage, data: null, meta: null };
});

export const unknownSentimentOperation = defineEventHandler(event => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  setResponseStatus(event, 404);
  return { code: 40404, message: 'API route not found', data: null, meta: null };
});
