<script setup lang="ts">
// 活跃会话页面
// - 展示当前账号的所有登录会话（设备）
// - 支持注销单个会话、注销除当前设备外的所有会话
// 导入 Vue 的响应式工具 ref 和生命周期钩子 onMounted
import { ref, onMounted } from 'vue';
import type { V2SessionItem } from '@/types/v2';
import {
  v2ListSessions,
  v2RevokeOtherSessions,
  v2RevokeSession
} from '@/services';
// 导入分隔线 UI 组件
import { Separator } from '@/components/ui/separator';
// 导入卡片 UI 组件
import { Card, CardContent } from '@/components/ui/card';
// 导入按钮 UI 组件
import { Button } from '@/components/ui/button';
// 导入徽章 UI 组件
import { Badge } from '@/components/ui/badge';
// 导入通知/吐司组件
import { toast } from 'vue-sonner';

// 加载状态，避免重复操作与控制按钮禁用态
const loading = ref(false);
// 会话列表数据
const sessions = ref<V2SessionItem[]>([]);

// 拉取会话列表
// - 从后端读取当前用户会话
// - currentSuffix 用于标注“当前设备”
async function load() {
  // 进入加载状态
  loading.value = true;
  try {
    const result = await v2ListSessions();
    sessions.value = result.items;
  } catch (e) {
    // 失败提示
    toast.error('Failed to load sessions');
  } finally {
    // 结束加载状态
    loading.value = false;
  }
}

// 注销单个会话
async function revoke(id: string) {
  try {
    await v2RevokeSession(id);
    toast.success('Session revoked');
    await load();
  } catch (e) {
    // 失败提示
    toast.error('Operation failed');
  }
}

// 注销除当前设备外的所有会话
async function revokeOthers() {
  try {
    await v2RevokeOtherSessions();
    toast.success('Other sessions revoked');
    await load();
  } catch (e) {
    // 失败提示
    toast.error('Operation failed');
  }
}

// 组件挂载后立即拉取会话
onMounted(load);
</script>

<template>
  <!-- 外层卡片容器，提供面板式视觉 -->
  <Card>
    <!-- 卡片内容区域 -->
    <CardContent>
      <!-- 页面主体：桌面端使用内边距更大的容器 -->
      <div class="hidden space-y-6 p-10 pb-16 md:block">
        <!-- 标题与描述容器 -->
        <div class="space-y-0.5">
          <!-- 页面主标题：活跃会话 -->
          <h2 class="text-2xl font-bold tracking-tight">
            <!-- 国际化文案：标题 -->
            {{ $t('account.active.title') }}
          </h2>
          <!-- 页面副标题/描述 -->
          <p class="text-muted-foreground">
            <!-- 国际化文案：描述 -->
            {{ $t('account.active.description') }}
          </p>
        </div>
        <!-- 分隔线，用于分组 -->
        <Separator class="my-6" />

        <!-- 顶部工具栏：刷新/注销其它设备 -->
        <div class="flex items-center justify-between">
          <!-- 左侧说明文字 -->
          <div class="text-sm text-muted-foreground">
            <!-- 国际化：同描述 -->
            {{ $t('account.active.description') }}
          </div>
          <!-- 右侧按钮组 -->
          <div class="flex items-center gap-2">
            <!-- 刷新按钮：重新加载会话列表 -->
            <Button
              variant="outline"
              :disabled="loading"
              @click="load()"
              >{{ $t('common.refresh') }}</Button
            >
            <!-- 注销其它设备按钮：删除除当前设备外的所有会话 -->
            <Button
              variant="destructive"
              :disabled="loading || !sessions.length"
              @click="revokeOthers()"
              >{{
                $t('account.active.revokeOthers')
              }}</Button
            >
          </div>
        </div>

        <!-- 会话列表容器 -->
        <div class="mt-4 divide-y rounded-md border">
          <!-- 当存在会话时的展示 -->
          <template v-if="sessions.length">
            <!-- 单条会话行 -->
            <div
              v-for="s in sessions"
              :key="s.session_id"
              class="flex flex-col gap-2 p-4 md:flex-row md:items-start md:justify-between"
            >
              <!-- 左侧：会话详情 -->
              <div class="space-y-1">
                <!-- 顶部：设备标记与设备名 -->
                <div class="flex items-center gap-2">
                  <!-- 标记徽章：当前设备/其它设备 -->
                  <Badge
                    :variant="
                      s.is_current
                        ? 'secondary'
                        : 'outline'
                    "
                  >
                    <!-- 根据是否为当前设备显示不同文案 -->
                    {{
                      s.is_current
                        ? $t('account.active.thisDevice')
                        : $t('account.active.otherDevice')
                    }}
                  </Badge>
                  <!-- 设备名称 -->
                  <span class="font-medium">{{
                    s.device_info
                  }}</span>
                </div>
                <!-- 次行：IP、位置、最后访问时间 -->
                <div class="text-xs text-muted-foreground">
                  {{ s.ip_address }} · — ·
                  {{
                    new Date(
                      s.last_accessed_at
                    ).toLocaleString()
                  }}
                </div>
                <!-- 第三行：UA 信息 -->
                <div
                  class="text-xs text-muted-foreground break-all"
                >
                  Session: {{ s.session_id }}
                </div>
              </div>
              <!-- 右侧：操作按钮组 -->
              <div class="flex shrink-0 items-center gap-2">
                <!-- 注销该会话按钮：当前设备禁用 -->
                <Button
                  size="sm"
                  variant="outline"
                  :disabled="s.is_current || loading"
                  @click="revoke(s.session_id)"
                  >{{ $t('account.active.revoke') }}</Button
                >
              </div>
            </div>
          </template>
          <!-- 当没有会话时的空状态 -->
          <div
            v-else
            class="p-6 text-center text-sm text-muted-foreground"
          >
            {{ $t('common.empty') }}
          </div>
        </div>
      </div>
    </CardContent>
  </Card>
</template>


