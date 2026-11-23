import { defineEventHandler, setResponseHeader, setResponseStatus } from 'h3';
import { metricsContentType, metricsStatus, renderMetrics } from '../utils/observability';
import { oraclePoolMetrics } from '../utils/oracle';
import { sessionManager } from '../utils/wsSession';

export default defineEventHandler(event => {
  setResponseHeader(event, 'Cache-Control', 'no-store');
  const authorization = event.node.req.headersDistinct?.authorization ?? event.node.req.headers.authorization;
  const status = event.method === 'GET' ? metricsStatus(process.env.METRICS_TOKEN,
    Array.isArray(authorization) && authorization.length === 1 ? authorization[0] : authorization) : 404;
  setResponseStatus(event, status);
  if (status !== 200) return '';
  setResponseHeader(event, 'Content-Type', metricsContentType);
  return renderMetrics(oraclePoolMetrics(), sessionManager.metrics());
});
