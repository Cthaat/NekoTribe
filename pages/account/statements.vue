<script setup lang="ts">
// 账户状态（通知/警告/违规）页面
// - 支持筛选（类型/状态）、分页
// - 支持操作：标记已读/未读、解决、忽略、提交申诉
// 引入 Vue 响应式与计算属性
import { ref, onMounted, computed } from 'vue';
// 引入 i18n
import { useI18n } from 'vue-i18n';
// 引入用户偏好（获取 access_token）
import { usePreferenceStore } from '@/stores/user';
// 引入封装的 API
import { apiFetch } from '@/composables/useApi';
// UI 组件：分隔线、卡片、按钮、徽章
import { Separator } from '@/components/ui/separator';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
// 提示组件
import { toast } from 'vue-sonner';

// 类型与状态枚举
type StatementType =
  | 'info'
  | 'warning'
  | 'strike'
  | 'suspension';
type StatementStatus =
  | 'unread'
  | 'read'
  | 'resolved'
  | 'dismissed'
  | 'appealed';

// 申诉信息
interface StatementAppeal {
  id: string;
  message: string;
  createdAt: string;
  status: 'pending' | 'approved' | 'rejected';
  response?: string;
}

// 账户状态项
interface AccountStatement {
  id: string;
  userId: number;
  type: StatementType;
  title: string;
  message: string;
  policy?: string;
  createdAt: string;
  status: StatementStatus;
  appeal?: StatementAppeal;
}

// i18n 工具
const { t } = useI18n();
// 偏好仓库
const pref = usePreferenceStore();

// 列表与分页状态
const loading = ref(false);
const page = ref(1);
const pageSize = ref(10);
const total = ref(0);
const statusFilter = ref<'all' | StatementStatus>('all');
const typeFilter = ref<'all' | StatementType>('all');
const items = ref<AccountStatement[]>([]);

// 总页数计算
const totalPages = computed(() =>
  Math.max(1, Math.ceil(total.value / pageSize.value))
);

// 拉取列表
async function load() {
  loading.value = true;
  try {
    // 请求参数包含分页与筛选项
    const res = await apiFetch<{
      success: boolean;
      data: {
        items: AccountStatement[];
        total: number;
        page: number;
        pageSize: number;
      };
    }>('/api/v1/account/statements', {
      method: 'GET',
      params: {
        page: page.value,
        pageSize: pageSize.value,
        status: statusFilter.value,
        type: typeFilter.value
      },
      headers: {
        Authorization: `Bearer ${pref.preferences.access_token}`
      }
    });
    // 写入列表与总数
    items.value = res.data.items;
    total.value = res.data.total;
  } catch (e: any) {
    // 网络错误提示
    toast.error(
      t('common.networkError') || 'Network error'
    );
  } finally {
    loading.value = false;
  }
}

// 标记/处理动作
async function actMark(
  id: string,
  action:
    | 'mark_read'
    | 'mark_unread'
    | 'resolve'
    | 'dismiss'
) {
  try {
    await apiFetch('/api/v1/account/statements/' + id, {
      method: 'PUT',
      body: { action },
      headers: {
        Authorization: `Bearer ${pref.preferences.access_token}`
      }
    });
    toast.success(t('account.statements.actionSuccess'));
    await load();
  } catch (e) {
    toast.error(t('account.statements.actionFailed'));
  }
}

// 申诉对话框状态
const showAppeal = ref<null | string>(null);
const appealMsg = ref('');

// 提交申诉
async function submitAppeal(id: string) {
  // 校验字数
  if (
    !appealMsg.value ||
    appealMsg.value.trim().length < 10
  ) {
    toast.error(t('account.statements.appealTooShort'));
    return;
  }
  try {
    await apiFetch(
      '/api/v1/account/statements/' + id + '/appeal',
      {
        method: 'POST',
        body: { message: appealMsg.value.trim() },
        headers: {
          Authorization: `Bearer ${pref.preferences.access_token}`
        }
      }
    );
    // 成功后重置输入并刷新
    toast.success(t('account.statements.appealSubmitted'));
    showAppeal.value = null;
    appealMsg.value = '';
    await load();
  } catch (e) {
    toast.error(t('account.statements.appealFailed'));
  }
}

// 挂载时拉取一次
onMounted(load);
</script>

<template>
  <!-- 外层卡片容器 -->
  <Card>
    <!-- 卡片内容区域 -->
    <CardContent>
      <!-- 页面主体：桌面端内边距更大 -->
      <div class="hidden space-y-6 p-10 pb-16 md:block">
        <!-- 标题与描述 -->
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            {{ $t('account.statements.title') }}
          </h2>
          <p class="text-muted-foreground">
            {{ $t('account.statements.description') }}
          </p>
        </div>
        <Separator class="my-6" />

        <!-- 筛选条 -->
        <div class="flex flex-wrap items-center gap-3">
          <!-- 类型筛选 -->
          <div class="flex items-center gap-2">
            <span class="text-sm text-muted-foreground">{{
              $t('account.statements.filters.type')
            }}</span>
            <select
              v-model="typeFilter"
              @change="
                page = 1;
                load();
              "
              class="h-9 rounded-md border bg-background px-3 text-sm"
            >
              <option value="all">
                {{ $t('account.statements.types.all') }}
              </option>
              <option value="info">
                {{ $t('account.statements.types.info') }}
              </option>
              <option value="warning">
                {{ $t('account.statements.types.warning') }}
              </option>
              <option value="strike">
                {{ $t('account.statements.types.strike') }}
              </option>
              <option value="suspension">
                {{
                  $t('account.statements.types.suspension')
                }}
              </option>
            </select>
          </div>
          <!-- 状态筛选 -->
          <div class="flex items-center gap-2">
            <span class="text-sm text-muted-foreground">{{
              $t('account.statements.filters.status')
            }}</span>
            <select
              v-model="statusFilter"
              @change="
                page = 1;
                load();
              "
              class="h-9 rounded-md border bg-background px-3 text-sm"
            >
              <option value="all">
                {{ $t('account.statements.status.all') }}
              </option>
              <option value="unread">
                {{ $t('account.statements.status.unread') }}
              </option>
              <option value="read">
                {{ $t('account.statements.status.read') }}
              </option>
              <option value="appealed">
                {{
                  $t('account.statements.status.appealed')
                }}
              </option>
              <option value="resolved">
                {{
                  $t('account.statements.status.resolved')
                }}
              </option>
              <option value="dismissed">
                {{
                  $t('account.statements.status.dismissed')
                }}
              </option>
            </select>
          </div>
          <!-- 刷新按钮 -->
          <div class="ml-auto flex items-center gap-2">
            <Button
              variant="outline"
              :disabled="loading"
              @click="load()"
              >{{ $t('common.refresh') }}</Button
            >
          </div>
        </div>

        <!-- 列表 -->
        <div class="mt-4 divide-y rounded-md border">
          <template v-if="items.length">
            <!-- 列表项 -->
            <div
              v-for="it in items"
              :key="it.id"
              class="flex flex-col gap-2 p-4 md:flex-row md:items-start md:justify-between"
            >
              <!-- 左侧信息 -->
              <div class="flex-1 space-y-1">
                <div class="flex items-center gap-2">
                  <!-- 类型徽章，颜色按类型切换 -->
                  <Badge
                    :variant="
                      it.type === 'info'
                        ? 'secondary'
                        : it.type === 'warning'
                          ? 'default'
                          : it.type === 'strike'
                            ? 'destructive'
                            : 'outline'
                    "
                  >
                    {{
                      $t(
                        'account.statements.types.' +
                          it.type
                      )
                    }}
                  </Badge>
                  <!-- 创建时间 -->
                  <span
                    class="text-xs text-muted-foreground"
                    >{{
                      new Date(
                        it.createdAt
                      ).toLocaleString()
                    }}</span
                  >
                  <!-- 对应策略编号（可选） -->
                  <span
                    v-if="it.policy"
                    class="text-xs text-muted-foreground"
                    >· {{ it.policy }}</span
                  >
                </div>
                <!-- 标题与内容 -->
                <div class="font-medium">
                  {{ it.title }}
                </div>
                <p class="text-sm text-muted-foreground">
                  {{ it.message }}
                </p>
                <!-- 申诉状态提示（存在申诉时） -->
                <div
                  v-if="it.appeal"
                  class="text-xs text-amber-600 dark:text-amber-400"
                >
                  {{
                    $t('account.statements.appealStatus')
                  }}: {{ it.appeal.status }}
                </div>
              </div>
              <!-- 右侧操作按钮组 -->
              <div
                class="flex shrink-0 flex-wrap items-center gap-2 pt-2 md:pt-0"
              >
                <Button
                  size="sm"
                  variant="ghost"
                  @click="
                    actMark(
                      it.id,
                      it.status === 'unread'
                        ? 'mark_read'
                        : 'mark_unread'
                    )
                  "
                >
                  {{
                    it.status === 'unread'
                      ? $t(
                          'account.statements.actions.markRead'
                        )
                      : $t(
                          'account.statements.actions.markUnread'
                        )
                  }}
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  @click="actMark(it.id, 'resolve')"
                  >{{
                    $t('account.statements.actions.resolve')
                  }}</Button
                >
                <Button
                  size="sm"
                  variant="outline"
                  @click="actMark(it.id, 'dismiss')"
                  >{{
                    $t('account.statements.actions.dismiss')
                  }}</Button
                >
                <Button
                  size="sm"
                  @click="showAppeal = it.id"
                  >{{
                    $t('account.statements.actions.appeal')
                  }}</Button
                >
              </div>
            </div>
          </template>
          <!-- 空状态 -->
          <div
            v-else
            class="p-6 text-center text-sm text-muted-foreground"
          >
            {{ $t('common.empty') }}
          </div>
        </div>

        <!-- 分页 -->
        <div class="mt-4 flex items-center justify-between">
          <div class="text-sm text-muted-foreground">
            {{
              $t('common.pagination', {
                page,
                totalPages,
                total
              })
            }}
          </div>
          <div class="flex items-center gap-2">
            <Button
              size="sm"
              variant="outline"
              :disabled="loading || page <= 1"
              @click="
                page = Math.max(1, page - 1);
                load();
              "
              >{{ $t('common.prev') }}</Button
            >
            <Button
              size="sm"
              variant="outline"
              :disabled="loading || page >= totalPages"
              @click="
                page = Math.min(totalPages, page + 1);
                load();
              "
              >{{ $t('common.next') }}</Button
            >
          </div>
        </div>

        <!-- 申诉弹层（简单内联实现） -->
        <div
          v-if="showAppeal"
          class="fixed inset-0 z-[60] grid place-items-center bg-black/40 p-4"
        >
          <div
            class="w-full max-w-lg rounded-lg border bg-background p-4 shadow-lg"
          >
            <div class="mb-2 text-lg font-semibold">
              {{ $t('account.statements.appealTitle') }}
            </div>
            <textarea
              v-model="appealMsg"
              rows="5"
              class="w-full resize-none rounded-md border bg-background p-2 text-sm"
              :placeholder="
                $t(
                  'account.statements.appealPlaceholder'
                ) as string
              "
            />
            <div class="mt-3 flex justify-end gap-2">
              <Button
                variant="ghost"
                @click="showAppeal = null"
                >{{ $t('common.cancel') }}</Button
              >
              <Button
                :disabled="loading"
                @click="submitAppeal(showAppeal as string)"
                >{{ $t('common.submit') }}</Button
              >
            </div>
          </div>
        </div>
      </div>
    </CardContent>
  </Card>
</template>
