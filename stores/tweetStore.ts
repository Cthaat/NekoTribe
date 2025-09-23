import { defineStore } from 'pinia';

export const useTweetStore = defineStore('tweet', {
  state: () => ({
    // 用于在页面跳转时临时存储的推文对象
    selectedTweet: null as any | null
  }),
  actions: {
    /**
     * 在导航前设置要传递的推文数据
     * @param tweet 要传递的推文对象
     */
    setSelectedTweet(tweet: any) {
      this.selectedTweet = tweet;
    },

    /**
     * 在详情页使用后清除数据，避免内存泄漏或数据污染
     */
    clearSelectedTweet() {
      this.selectedTweet = null;
    }
  }
});
