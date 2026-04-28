// composables/useAnimatedNumber.ts
import { ref, watch, onMounted, type Ref } from 'vue';

/**
 * 一个适用于 SSR 的 Vue Composable，用于将一个数字从旧值动画到新值。
 *
 * @param target - 一个包含最终目标数字的 Ref。
 * @param options - 可选的配置项。
 * @param options.duration - 动画的持续时间（毫秒）。默认为 1500ms。
 * @returns 一个 Ref，在服务器上它会立即返回目标值，在客户端会平滑更新。
 */
export function useAnimatedNumber(
  target: Ref<number>,
  options: { duration?: number } = {}
) {
  const { duration = 1500 } = options;

  // 1. 关键修改：用目标值初始化 ref。
  // 这可以确保服务器渲染出的是最终数字，防止 hydration mismatch。
  const animatedValue = ref(target.value);

  // 2. 关键修改：将所有动画逻辑移入 onMounted。
  // onMounted 钩子内的代码只会在客户端执行。
  onMounted(() => {
    watch(
      target,
      newValue => {
        const startValue = animatedValue.value; // 从当前值开始动画
        const startTime = performance.now();

        const step = (timestamp: number) => {
          const elapsed = timestamp - startTime;
          const progress = Math.min(elapsed / duration, 1);
          const easedProgress =
            1 - Math.pow(1 - progress, 3); // ease-out

          animatedValue.value =
            startValue +
            (newValue - startValue) * easedProgress;

          if (progress < 1) {
            requestAnimationFrame(step);
          }
        };

        requestAnimationFrame(step);
      },
      // 3. 在 onMounted 内部，immediate 仍然有用，
      // 它确保了即使值没有变化，动画也会从 SSR 的最终值“播放”到客户端的目标值（通常是一样的，所以动画很短）
      // 或者如果需要在客户端重新获取数据，它会触发从旧值到新值的动画。
      { immediate: true }
    );
  });

  return animatedValue;
}
