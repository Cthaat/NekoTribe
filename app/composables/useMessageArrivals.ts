import { ref, watch } from 'vue';

export function useMessageArrivals(ids: () => number[]) {
  const arrived = ref(new Set<number>());
  watch(ids, (next, old) => {
    const tail = old.at(-1);
    const index = tail === undefined ? -1 : next.indexOf(tail);
    arrived.value = new Set(index < 0 ? [] : next.slice(index + 1));
  });
  return arrived;
}
