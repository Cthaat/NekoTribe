export default defineEventHandler((event) => {
  const start = Date.now()
  const ip = event.node.req.headers['x-forwarded-for'] || event.node.req.socket.remoteAddress
  const path = event.node.req.url

  // 在响应时记录耗时
  event.node.res.on('finish', () => {
    const duration = Date.now() - start
    console.log(`logger:[日志] IP:${ip} 路径:${path} 用时:${duration}ms`)
  })
})