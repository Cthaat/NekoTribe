<script setup lang="ts">
import { ref, computed } from 'vue';
import { toast } from 'vue-sonner';
import ChatChannelList from '@/components/ChatChannelList.vue';
import ChatRoom from '@/components/ChatRoom.vue';
import type {
  Channel,
  ChannelCategory
} from '@/components/ChatChannelList.vue';
import type { ChatMessageType } from '@/components/ChatMessage.vue';
import type { ChatMember } from '@/components/ChatMemberList.vue';
const { t } = useAppLocale();

definePageMeta({
  layout: 'chat'
});

// 模拟群组数据
const groupInfo = ref({
  id: 1,
  name: 'NekoTribe 开发者社区',
  avatar:
    'https://api.dicebear.com/7.x/identicon/svg?seed=neko-dev'
});

// 模拟频道分类和频道数据
const channelCategories = ref<ChannelCategory[]>([
  {
    id: 1,
    name: '公告',
    channels: [
      {
        id: 1,
        name: '公告板',
        type: 'announcement',
        unreadCount: 2,
        lastMessage: '最新版本 v2.0 已发布！'
      },
      {
        id: 2,
        name: '规则须知',
        type: 'text',
        lastMessage: '请阅读社区规则'
      }
    ]
  },
  {
    id: 2,
    name: '文字频道',
    channels: [
      {
        id: 3,
        name: '综合讨论',
        type: 'text',
        unreadCount: 15,
        lastMessage: '大家好！有人在吗？'
      },
      {
        id: 4,
        name: '技术交流',
        type: 'text',
        unreadCount: 5,
        lastMessage: 'Vue 3 的新特性真不错'
      },
      {
        id: 5,
        name: '问题求助',
        type: 'text',
        lastMessage: '请问这个问题怎么解决？'
      },
      {
        id: 6,
        name: '项目分享',
        type: 'text',
        lastMessage: '看看我的新项目！'
      },
      {
        id: 7,
        name: '管理员专区',
        type: 'text',
        isPrivate: true,
        lastMessage: '内部讨论'
      }
    ]
  },
  {
    id: 3,
    name: '语音频道',
    channels: [
      {
        id: 8,
        name: '休闲聊天',
        type: 'voice'
      },
      {
        id: 9,
        name: '结对编程',
        type: 'voice'
      },
      {
        id: 10,
        name: '会议室',
        type: 'video',
        isPrivate: true
      }
    ]
  }
]);

const initialChannel =
  channelCategories.value[1]?.channels[0] ??
  channelCategories.value[0]?.channels[0];

if (!initialChannel) {
  throw new Error('Missing chat channel seed');
}

// 当前选中的频道
const activeChannel = ref<Channel>(initialChannel);

// 模拟成员数据
const members = ref<ChatMember[]>([
  {
    id: 1,
    username: 'nekoadmin',
    nickname: '猫猫管理员',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=admin',
    role: 'owner',
    status: 'online',
    statusText: '正在码代码...'
  },
  {
    id: 2,
    username: 'devcat',
    nickname: '开发喵',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=devcat',
    role: 'admin',
    status: 'online',
    statusText: '🎮 游戏中'
  },
  {
    id: 3,
    username: 'coder123',
    nickname: '代码小能手',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=coder123',
    role: 'member',
    status: 'online',
    isInVoice: true
  },
  {
    id: 4,
    username: 'designer',
    nickname: '设计师小姐姐',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=designer',
    role: 'member',
    status: 'idle',
    statusText: '去吃饭了~'
  },
  {
    id: 5,
    username: 'newbie',
    nickname: '萌新一枚',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=newbie',
    role: 'member',
    status: 'dnd',
    statusText: '请勿打扰，专心学习'
  },
  {
    id: 6,
    username: 'olduser',
    nickname: '老用户',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=olduser',
    role: 'member',
    status: 'offline'
  },
  {
    id: 7,
    username: 'silent',
    nickname: '潜水员',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=silent',
    role: 'member',
    status: 'offline'
  },
  {
    id: 8,
    username: 'helper',
    nickname: '热心助人',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=helper',
    role: 'member',
    status: 'online'
  }
]);

// 模拟消息数据
const messages = ref<ChatMessageType[]>([
  {
    id: 1,
    content:
      '欢迎来到 NekoTribe 开发者社区！这是我们的综合讨论频道。',
    type: 'system',
    author: {
      id: 0,
      username: 'system',
      nickname: '系统',
      avatar: ''
    },
    createdAt: '2024-12-15T08:00:00Z'
  },
  {
    id: 2,
    content:
      '大家好！我是管理员，有任何问题都可以在这里提问哦~ 🐱',
    type: 'text',
    author: {
      id: 1,
      username: 'nekoadmin',
      nickname: '猫猫管理员',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=admin',
      role: 'owner'
    },
    createdAt: '2024-12-15T08:05:00Z',
    isPinned: true,
    reactions: [
      { emoji: '👋', count: 5, reacted: true },
      { emoji: '❤️', count: 3, reacted: false }
    ]
  },
  {
    id: 3,
    content: '新人报到！请多多关照 😊',
    type: 'text',
    author: {
      id: 5,
      username: 'newbie',
      nickname: '萌新一枚',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=newbie',
      role: 'member'
    },
    createdAt: '2024-12-15T09:30:00Z',
    reactions: [
      { emoji: '👍', count: 8, reacted: false },
      { emoji: '🎉', count: 4, reacted: true }
    ]
  },
  {
    id: 4,
    content: '欢迎欢迎！有问题随时问',
    type: 'text',
    author: {
      id: 2,
      username: 'devcat',
      nickname: '开发喵',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=devcat',
      role: 'admin'
    },
    createdAt: '2024-12-15T09:32:00Z'
  },
  {
    id: 5,
    content:
      '谢谢大家！我想问一下，这个项目是用什么技术栈开发的呀？',
    type: 'text',
    author: {
      id: 5,
      username: 'newbie',
      nickname: '萌新一枚',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=newbie',
      role: 'member'
    },
    createdAt: '2024-12-15T09:35:00Z'
  },
  {
    id: 6,
    content:
      '我们用的是 Vue 3 + Nuxt 3 + TypeScript，UI 组件库是 shadcn-vue',
    type: 'text',
    author: {
      id: 3,
      username: 'coder123',
      nickname: '代码小能手',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=coder123',
      role: 'member'
    },
    createdAt: '2024-12-15T09:36:00Z',
    replyTo: {
      id: 5,
      content:
        '谢谢大家！我想问一下，这个项目是用什么技术栈开发的呀？',
      author: {
        nickname: '萌新一枚'
      }
    }
  },
  {
    id: 7,
    content:
      '对的！而且我们还用了 Tailwind CSS 做样式，非常好用',
    type: 'text',
    author: {
      id: 3,
      username: 'coder123',
      nickname: '代码小能手',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=coder123',
      role: 'member'
    },
    createdAt: '2024-12-15T09:36:30Z'
  },
  {
    id: 8,
    content:
      '哇，这个技术栈很现代化诶！我之前一直用 React，Vue 3 和 React 有什么区别吗？',
    type: 'text',
    author: {
      id: 5,
      username: 'newbie',
      nickname: '萌新一枚',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=newbie',
      role: 'member'
    },
    createdAt: '2024-12-15T09:40:00Z'
  },
  {
    id: 9,
    content:
      '主要区别在于响应式系统的实现方式不同。Vue 3 使用 Proxy 实现响应式，而 React 需要手动调用 setState。Vue 的模板语法也更接近原生 HTML，上手会更快一些。',
    type: 'text',
    author: {
      id: 2,
      username: 'devcat',
      nickname: '开发喵',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=devcat',
      role: 'admin'
    },
    createdAt: '2024-12-15T09:42:00Z',
    reactions: [
      { emoji: '👍', count: 3, reacted: false },
      { emoji: '🙏', count: 2, reacted: false }
    ]
  },
  {
    id: 10,
    content: '我来分享一张我们新设计的界面截图~',
    type: 'text',
    author: {
      id: 4,
      username: 'designer',
      nickname: '设计师小姐姐',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=designer',
      role: 'member'
    },
    createdAt: '2024-12-15T10:00:00Z',
    attachments: [
      {
        id: 1,
        name: 'new-design.png',
        url: 'https://picsum.photos/400/300',
        type: 'image'
      }
    ]
  },
  {
    id: 11,
    content: '哇！好漂亮！配色很舒服',
    type: 'text',
    author: {
      id: 8,
      username: 'helper',
      nickname: '热心助人',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=helper',
      role: 'member'
    },
    createdAt: '2024-12-15T10:02:00Z',
    reactions: [{ emoji: '😍', count: 5, reacted: true }]
  },
  {
    id: 12,
    content:
      '今天下午 3 点有个线上分享会，大家记得参加哦！主题是《如何编写高质量的 TypeScript 代码》',
    type: 'text',
    author: {
      id: 1,
      username: 'nekoadmin',
      nickname: '猫猫管理员',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=admin',
      role: 'owner'
    },
    createdAt: '2024-12-16T08:00:00Z',
    isPinned: true
  },
  {
    id: 13,
    content: '好的，准时参加！',
    type: 'text',
    author: {
      id: 3,
      username: 'coder123',
      nickname: '代码小能手',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=coder123',
      role: 'member'
    },
    createdAt: '2024-12-16T08:05:00Z'
  },
  {
    id: 14,
    content: '我也会来的！',
    type: 'text',
    author: {
      id: 5,
      username: 'newbie',
      nickname: '萌新一枚',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=newbie',
      role: 'member'
    },
    createdAt: '2024-12-16T08:06:00Z'
  }
]);

// 置顶消息
const pinnedMessages = computed(() => {
  return messages.value.filter(m => m.isPinned);
});

// 选择频道
const handleSelectChannel = (channel: Channel) => {
  activeChannel.value = channel;
  // 清除未读计数
  const category = channelCategories.value.find(c =>
    c.channels.some(ch => ch.id === channel.id)
  );
  if (category) {
    const ch = category.channels.find(
      c => c.id === channel.id
    );
    if (ch) {
      ch.unreadCount = 0;
    }
  }
};

// 发送消息
const handleSendMessage = (
  content: string,
  attachments?: File[]
) => {
  const newMessage: ChatMessageType = {
    id: messages.value.length + 1,
    content,
    type: 'text',
    author: {
      id: 1,
      username: 'nekoadmin',
      nickname: '猫猫管理员',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=admin',
      role: 'owner'
    },
    createdAt: new Date().toISOString(),
    attachments: attachments?.map((file, index) => ({
      id: Date.now() + index,
      name: file.name,
      url: URL.createObjectURL(file),
      type: file.type.startsWith('image/')
        ? ('image' as const)
        : ('file' as const),
      size: file.size
    }))
  };
  messages.value.push(newMessage);
  toast.success(t('chat.feedback.sent'));
};

// 添加表情反应
const handleReact = (messageId: number, emoji: string) => {
  const message = messages.value.find(
    m => m.id === messageId
  );
  if (message) {
    if (!message.reactions) {
      message.reactions = [];
    }
    const existingReaction = message.reactions.find(
      r => r.emoji === emoji
    );
    if (existingReaction) {
      if (existingReaction.reacted) {
        existingReaction.count--;
        existingReaction.reacted = false;
        if (existingReaction.count === 0) {
          message.reactions = message.reactions.filter(
            r => r.emoji !== emoji
          );
        }
      } else {
        existingReaction.count++;
        existingReaction.reacted = true;
      }
    } else {
      message.reactions.push({
        emoji,
        count: 1,
        reacted: true
      });
    }
  }
};

// 删除消息
const handleDeleteMessage = (messageId: number) => {
  const index = messages.value.findIndex(
    m => m.id === messageId
  );
  if (index !== -1) {
    messages.value.splice(index, 1);
    toast.success(t('chat.feedback.deleted'));
  }
};

// 置顶消息
const handlePinMessage = (messageId: number) => {
  const message = messages.value.find(
    m => m.id === messageId
  );
  if (message) {
    message.isPinned = !message.isPinned;
    toast.success(
      message.isPinned
        ? t('chat.feedback.pinned')
        : t('chat.feedback.unpinned')
    );
  }
};

// 创建频道
const handleCreateChannel = (categoryId: number) => {
  toast.info(t('chat.feedback.createChannelWip'));
};

// 切换频道静音
const handleToggleMute = () => {
  activeChannel.value.isMuted =
    !activeChannel.value.isMuted;
  toast.success(
    activeChannel.value.isMuted
      ? t('chat.feedback.channelMuted')
      : t('chat.feedback.channelUnmuted')
  );
};
</script>

<template>
  <div class="flex h-full w-full">
    <!-- 频道列表 -->
    <div
      class="w-60 flex-shrink-0 border-r hidden md:block bg-muted/20"
    >
      <ChatChannelList
        :categories="channelCategories"
        :active-channel-id="activeChannel.id"
        :group-name="groupInfo.name"
        :group-avatar="groupInfo.avatar"
        :can-manage="true"
        @select="handleSelectChannel"
        @create-channel="handleCreateChannel"
      />
    </div>

    <!-- 聊天室 -->
    <div class="flex-1 min-w-0 h-full">
      <ChatRoom
        :channel="activeChannel"
        :messages="messages"
        :members="members"
        :pinned-messages="pinnedMessages"
        :can-manage="true"
        @send="handleSendMessage"
        @react="handleReact"
        @delete="handleDeleteMessage"
        @pin="handlePinMessage"
        @toggle-mute="handleToggleMute"
      />
    </div>
  </div>
</template>
