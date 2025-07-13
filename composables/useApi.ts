// composables/apiFetch.ts

// 1. 我们不需要从任何地方导入选项类型了！
//    我们将直接从全局的 $fetch 函数推导出它的类型。

/**
 * 直接从全局 $fetch 函数的类型定义中提取出其第二个参数（options 对象）的类型。
 * 这是最精确、最不会出错的做法。
 */
type ApiFetchOptions = Parameters<typeof $fetch>[1];

/**
 * 封装了 $fetch，并自动添加 baseURL。
 * 这是用于事件驱动请求（如表单提交）的工具。
 *
 * @param path 你要请求的 API 路径
 * @param options 与 $fetch 完全兼容的选项对象
 */
export const apiFetch = <T>(
  path: string,
  // 2. 使用我们刚刚推导出的精确类型
  options: ApiFetchOptions = {}
) => {
  // 3. 获取运行时配置
  const config = useRuntimeConfig();

  // 4. 创建默认选项，同样使用这个精确的类型
  const defaults: ApiFetchOptions = {
    baseURL: config.public.apiBase

    // 如果需要全局添加 headers 或拦截器，这里是最佳位置
    // onRequest({ options }) { ... }
  };

  // 5. 合并选项，TypeScript 现在可以正确推断出 mergedOptions 的类型
  const mergedOptions = { ...defaults, ...options };

  // 6. 调用 $fetch，现在类型完美匹配，不会再有任何错误
  return $fetch<T>(path, mergedOptions);
};
