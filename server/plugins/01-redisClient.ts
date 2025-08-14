import {
  defineNitroPlugin,
  useRuntimeConfig
} from '#imports';
import Redis from 'ioredis';

// 1. 在插件的顶层作用域定义一个变量，它将作为我们的单例（Singleton）容器。
//    初始值为 null，表示还没有创建实例。
let redisInstance: Redis | null = null;

/**
 * 这是一个获取Redis实例的函数。
 * 它采用了单例模式，确保在整个应用的生命周期中，只创建一个Redis连接。
 */
function getRedisInstance() {
  // 2. 检查实例是否已经存在。
  if (!redisInstance) {
    // 如果不存在，才执行创建逻辑。
    console.log('Redis 实例不存在，正在创建新的连接...');

    const runtimeConfig = useRuntimeConfig();

    console.log(runtimeConfig);

    // 3. 创建新的 Redis 实例。
    redisInstance = new Redis({
      host: runtimeConfig.redisHost,
      port: Number(runtimeConfig.redisPort),
      password: runtimeConfig.redisPassword,
      db: Number(runtimeConfig.redisDb),
      // --- 这是至关重要的选项！ ---
      // lazyConnect: true 告诉 ioredis 不要立即连接，
      // 而是在第一条命令被发送时才建立连接。
      // 这完美地配合了我们的惰性加载模式。
      lazyConnect: true
    });

    redisInstance.on('error', err => {
      console.error('Redis 连接错误:', err);
    });
    redisInstance.on('connect', () => {
      console.log('Redis 连接成功');
    });
  }

  // 4. 返回（已存在的或新创建的）实例。
  return redisInstance;
}

export default defineNitroPlugin(nitroApp => {
  // 5. 我们不再直接注入一个已经创建好的实例。
  //    而是使用 Object.defineProperty 定义一个 getter。
  //    这使得 event.context.redis 成为一个“惰性”属性。
  // 定义 nitroApp.hooks.hook 的类型
  interface NitroAppHooks {
    hook: (
      eventName: string,
      handler: (event: any) => void
    ) => void;
  }

  // 定义 event.context 的类型
  interface NitroEventContext {
    redis?: Redis;
    [key: string]: any;
  }

  // 定义 event 的类型
  interface NitroEvent {
    context: NitroEventContext;
    [key: string]: any;
  }

  (nitroApp.hooks as NitroAppHooks).hook(
    'request',
    (event: NitroEvent) => {
      Object.defineProperty(event.context, 'redis', {
        // 当代码第一次尝试访问 event.context.redis 时，这个 get 函数才会被调用。
        get() {
          return getRedisInstance();
        },
        // 允许此属性在热更新（HMR）时被重新配置。
        configurable: true
      });
    }
  );
});
