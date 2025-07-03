// server/api/test-oceanbase.get.ts
import { executeQuery } from '~/server/utils/oceanBasePool'

export default defineEventHandler(async (event) => {
  const runtimeConfig = useRuntimeConfig()  
  try {
    // 使用便捷方法执行查询 - 使用最简单的查询语句
    const rows = await executeQuery('SELECT 1 as test_value')
    
    return {
      success: true,
      message: 'OceanBase 连接成功！',
      data: rows,
      timestamp: new Date().toISOString()
    }
  } catch (error) {
    console.error('OceanBase 连接测试失败:', error)
    
    return {
      success: false,
      message: 'OceanBase 连接失败',
      error: error instanceof Error ? error.message : '未知错误',
      timestamp: new Date().toISOString()
    }
  }
})
