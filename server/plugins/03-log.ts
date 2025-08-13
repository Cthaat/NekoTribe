export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('request', event => {
    const req = event.node.req;
    const method = req.method;
    const url = req.url;
    const ip =
      req.headers['x-forwarded-for']
        ?.toString()
        .split(',')[0]
        ?.trim() ||
      req.socket.remoteAddress ||
      'unknown';
    const userAgent =
      req.headers['user-agent'] || 'unknown';

    // 读取来源追踪头
    const xClientRoute =
      req.headers['x-client-route'] || '-';
    const xClientComponent =
      req.headers['x-client-component'] || '-';
    const xClientSource =
      req.headers['x-client-source'] || '-';
    const xClientReferer =
      req.headers['x-client-referer'] ||
      req.headers['referer'] ||
      '-';
    const xClientPlatform =
      req.headers['x-client-platform'] || '-';

    console.log(
      `log:[请求] 方法:${method} 路径:${url} IP:${ip} UA:${userAgent} 平台:${xClientPlatform} 路由:${xClientRoute} 组件:${xClientComponent} 来源:${xClientSource} Referer:${xClientReferer} 时间:${new Date().toISOString()}`
    );
  });
});
