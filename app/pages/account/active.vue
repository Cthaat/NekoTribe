<script setup lang="ts">
// 活跃会话页面
// - 展示当前账号的所有登录会话（设备）
// - 支持注销单个会话、注销除当前设备外的所有会话
// 导入 Vue 的响应式工具 ref 和生命周期钩子 onMounted
import { ref, onMounted } from 'vue';
import {
  v2ListSessions,
  v2RevokeOtherSessions,
  v2RevokeSession,
  type SessionVM
} from '@/services';
// 导入分隔线 UI 组件
import { Separator } from '@/components/ui/separator';
// 导入卡片 UI 组件
import { Card, CardContent } from '@/components/ui/card';
// 导入按钮 UI 组件
import { Button } from '@/components/ui/button';
// 导入徽章 UI 组件
import { Badge } from '@/components/ui/badge';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@/components/ui/table';
// 导入通知/吐司组件
import { toast } from 'vue-sonner';

const { t } = useAppLocale();

// 加载状态，避免重复操作与控制按钮禁用态
const loading = ref(false);
// 会话列表数据
const sessions = ref<SessionVM[]>([]);

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
    toast.error(t('account.active.feedback.loadFailed'));
  } finally {
    // 结束加载状态
    loading.value = false;
  }
}

// 注销单个会话
async function revoke(id: string) {
  try {
    await v2RevokeSession(id);
    toast.success(t('account.active.feedback.revoked'));
    await load();
  } catch (e) {
    // 失败提示
    toast.error(t('account.active.feedback.operationFailed'));
  }
}

// 注销除当前设备外的所有会话
async function revokeOthers() {
  try {
    await v2RevokeOtherSessions();
    toast.success(t('account.active.feedback.othersRevoked'));
    await load();
  } catch (e) {
    // 失败提示
    toast.error(t('account.active.feedback.operationFailed'));
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
            {{ t('account.active.title') }}
          </h2>
          <!-- 页面副标题/描述 -->
          <p class="text-muted-foreground">
            <!-- 国际化文案：描述 -->
            {{ t('account.active.description') }}
          </p>
        </div>
        <!-- 分隔线，用于分组 -->
        <Separator class="my-6" />

        <!-- 顶部工具栏：刷新/注销其它设备 -->
        <div class="flex items-center justify-between">
          <!-- 左侧说明文字 -->
          <div class="text-sm text-muted-foreground">
            <!-- 国际化：同描述 -->
            {{ t('account.active.description') }}
          </div>
          <!-- 右侧按钮组 -->
          <div class="flex items-center gap-2">
            <!-- 刷新按钮：重新加载会话列表 -->
            <Button
              variant="outline"
              :disabled="loading"
              @click="load()"
              >{{ t('common.refresh') }}</Button
            >
            <!-- 注销其它设备按钮：删除除当前设备外的所有会话 -->
            <Button
              variant="destructive"
              :disabled="loading || !sessions.length"
              @click="revokeOthers()"
              >{{
                t('account.active.revokeOthers')
              }}</Button
            >
          </div>
        </div>

        <div class="mt-4 overflow-hidden rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>
                  {{ t('account.active.thisDevice') }}
                </TableHead>
                <TableHead>
                  {{ t('account.active.description') }}
                </TableHead>
                <TableHead>Session</TableHead>
                <TableHead class="text-right">
                  {{ t('account.active.revoke') }}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              <TableRow v-if="!sessions.length">
                <TableCell
                  colspan="4"
                  class="h-24 text-center text-muted-foreground"
                >
                  {{ t('common.empty') }}
                </TableCell>
              </TableRow>
              <TableRow v-for="s in sessions" :key="s.id">
                <TableCell>
                  <Badge
                    :variant="
                      s.current ? 'secondary' : 'outline'
                    "
                  >
                    {{
                      s.current
                        ? t('account.active.thisDevice')
                        : t('account.active.otherDevice')
                    }}
                  </Badge>
                </TableCell>
                <TableCell>
                  <div class="space-y-1">
                    <div class="font-medium">
                      {{ s.deviceInfo }}
                    </div>
                    <div class="text-xs text-muted-foreground">
                      {{ s.ipAddress }} · —
                    </div>
                    <div class="text-xs text-muted-foreground">
                      {{
                        new Date(
                          s.lastAccessedAt
                        ).toLocaleString()
                      }}
                    </div>
                  </div>
                </TableCell>
                <TableCell class="max-w-[18rem] truncate font-mono text-xs">
                  {{ s.id }}
                </TableCell>
                <TableCell class="text-right">
                  <Button
                    size="sm"
                    variant="outline"
                    :disabled="s.current || loading"
                    @click="revoke(s.id)"
                  >
                    {{ t('account.active.revoke') }}
                  </Button>
                </TableCell>
              </TableRow>
            </TableBody>
          </Table>
        </div>
      </div>
    </CardContent>
  </Card>
</template>


