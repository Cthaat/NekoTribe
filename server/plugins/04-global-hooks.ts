export default defineNitroPlugin((nitroApp) => {
  // 请求到来时
  nitroApp.hooks.hook('request', (event) => {
    event.context._start = Date.now()
    console.log(`global-hooks:[${new Date().toISOString()}] 请求: ${event.path}`)
  })

  // 响应发送前
  nitroApp.hooks.hook('beforeResponse', (event, response) => {
    const duration = Date.now() - (event.context._start || Date.now())
    console.log(`global-hooks:[${new Date().toISOString()}] 响应: ${event.path} 用时: ${duration}ms`)
  })

  // 捕获全局错误
  nitroApp.hooks.hook('error', (error, event) => {
    console.error(`[global-hooks:${new Date().toISOString()}] 全局错误:`, error, '请求路径:', event?.path)
  })
})