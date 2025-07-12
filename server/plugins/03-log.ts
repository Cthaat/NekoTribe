export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('request', event => {
    const req = event.node.req;
    const method = req.method;
    const url = req.url;
    const ip =
      req.headers['x-forwarded-for']?.toString().split(',')[0]?.trim() ||
      req.socket.remoteAddress ||
      'unknown';
    const userAgent = req.headers['user-agent'] || 'unknown';
    console.log(
      `log:[请求] 方法: ${method} 路径: ${url} IP: ${ip} UA: ${userAgent} 时间: ${new Date().toISOString()}`
    );
  });
});
