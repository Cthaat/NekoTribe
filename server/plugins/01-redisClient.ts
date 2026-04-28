import { defineNitroPlugin } from '#imports';
import type { H3Event } from 'h3';
import Redis from 'ioredis';
import { resolveRedisOptions } from '../utils/redis-config';
import {
  logError,
  logInfo,
  serializeLogError
} from '~/server/utils/logging';

// 1. 在插件的顶层作用域定义一个变量，它将作为我们的单例（Singleton）容器。
//    初始值为 null，表示还没有创建实例。
let redisInstance: Redis | null = null;

interface RedisEventContext {
  redis?: Redis;
}

/**
 * 这是一个获取Redis实例的函数。
 * 它采用了单例模式，确保在整个应用的生命周期中，只创建一个Redis连接。
 */
function getRedisInstance(): Redis {
  // 2. 检查实例是否已经存在。
  if (!redisInstance) {
    // 如果不存在，才执行创建逻辑。
    logInfo('redis', {
      event: 'client:create',
      lazyConnect: true
    });

    // 3. 创建新的 Redis 实例。
    redisInstance = new Redis({
      ...resolveRedisOptions(),
      // --- 这是至关重要的选项！ ---
      // lazyConnect: true 告诉 ioredis 不要立即连接，
      // 而是在第一条命令被发送时才建立连接。
      // 这完美地配合了我们的惰性加载模式。
      lazyConnect: true
    });

    redisInstance.on('error', err => {
      logError('redis', {
        event: 'client:error',
        error: serializeLogError(err)
      });
    });
    redisInstance.on('connect', () => {
      logInfo('redis', {
        event: 'client:connect'
      });
    });
  }

  // 4. 返回（已存在的或新创建的）实例。
  return redisInstance;
}

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('request', (event: H3Event) => {
    Object.defineProperty(
      event.context as RedisEventContext,
      'redis',
      {
        get() {
          return getRedisInstance();
        },
        configurable: true
      }
    );
  });
});
