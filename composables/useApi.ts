// 我们需要从 ofetch 导入 FetchOptions 类型，以便进行断言
import type { FetchOptions } from 'ofetch';

/**
 * 这是您应用中发起 API 请求的【推荐】方式。
 *
 * 它是一个简洁的封装，内部调用了由 `plugins/api.ts` 插件创建并提供的
 * 全局 `$api` 实例。
 *
 * @param path 你要请求的 API 路径
 * @param options 与全局 $fetch 完全兼容的选项对象
 * @returns Promise<T>
 */
export const apiFetch = <T>(
  // 我们仍然使用从全局 $fetch 推导出的类型，因为它最贴近用户的使用习惯
  path: string,
  options?: Parameters<typeof $fetch>[1]
) => {
  const { $api } = useNuxtApp();

  // 🔥 核心改动：使用类型断言 `as`
  // 我们在这里强制告诉 TypeScript：
  // "尽管你可能觉得这个 options 类型很宽泛，但我保证它与 ofetch 要求的 FetchOptions<'json'> 是兼容的。
  // 请按照这个类型来处理它。"
  // 这会直接解决掉关于 `responseType` 不兼容的错误。
  const assertionOptions = options as FetchOptions<'json'>;

  // 添加调试信息
  console.log(`[apiFetch] 发起请求: ${path}`, {
    options: assertionOptions || '无选项'
  });

  // 调用 $api，并传递经过类型断言的选项对象
  return $api<T>(path, assertionOptions);
};
