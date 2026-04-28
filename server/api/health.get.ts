interface HealthCheckResponse {
  status: 'ok';
  service: 'nekotribe';
  timestamp: string;
}

export default defineEventHandler(
  (): HealthCheckResponse => {
    return {
      status: 'ok',
      service: 'nekotribe',
      timestamp: new Date().toISOString()
    };
  }
);
