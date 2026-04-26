<script setup lang="ts">
// 账户设置页面
// - 从后端读取/保存用户设置（隐私、通知、安全）
// - 使用简单的开关与下拉框组织表单
// - 保存时仅发送必要字段，后端做合并更新
// 引入响应式与生命周期
import { ref, onMounted } from 'vue';
// 引入 UI 组件
import { Separator } from '@/components/ui/separator';
import { Card, CardContent } from '@/components/ui/card';
import SecurityPage from '@/components/SecurityPage.vue';
import { Button } from '@/components/ui/button';
import { Switch } from '@/components/ui/switch';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
// 引入 API/状态/提示
import { apiFetch } from '@/composables/useApi';
import { usePreferenceStore } from '@/stores/user';
import { toast } from 'vue-sonner';

// 偏好/鉴权信息
const pref = usePreferenceStore();
// 加载与保存中的状态位
const loading = ref(false);
const saving = ref(false);

// 本地响应式数据：与后端字段一一对应
const twoFactorEnabled = ref(false);
const loginAlerts = ref(true);
const profile_visibility = ref<'public' | 'private'>(
  'public'
);
const show_online_status = ref(true);
const allow_dm_from_strangers = ref(false);
const push_notification_enabled = ref(true);
const email_notification_enabled = ref(true);

// 载入当前设置
async function loadSettings() {
  // 进入加载态
  loading.value = true;
  try {
    // 获取设置（需要带上 Bearer Token）
    const res = await apiFetch<{ data: { settings: any } }>(
      '/api/v1/account/settings',
      {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${pref.preferences.access_token}`
        }
      }
    );
    // 写入到本地响应式变量
    const s = res.data.settings || {};
    twoFactorEnabled.value = !!s.twoFactorEnabled;
    loginAlerts.value = !!s.loginAlerts;
    profile_visibility.value =
      s.profile_visibility || 'public';
    show_online_status.value = !!s.show_online_status;
    allow_dm_from_strangers.value =
      !!s.allow_dm_from_strangers;
    push_notification_enabled.value =
      !!s.push_notification_enabled;
    email_notification_enabled.value =
      !!s.email_notification_enabled;
  } catch (e) {
    // 失败提示
    toast.error('Failed to load settings');
  } finally {
    // 结束加载态
    loading.value = false;
  }
}

// 保存当前设置
async function saveSettings() {
  // 进入保存态
  saving.value = true;
  try {
    // 合并更新（后端做 patch/merge）
    await apiFetch('/api/v1/account/settings', {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${pref.preferences.access_token}`
      },
      body: {
        // 安全
        twoFactorEnabled: twoFactorEnabled.value,
        loginAlerts: loginAlerts.value,
        // 隐私
        profile_visibility: profile_visibility.value,
        show_online_status: show_online_status.value,
        allow_dm_from_strangers:
          allow_dm_from_strangers.value,
        // 通知
        push_notification_enabled:
          push_notification_enabled.value,
        email_notification_enabled:
          email_notification_enabled.value
      }
    });
    // 成功提示
    toast.success('Settings saved');
  } catch (e) {
    // 失败提示
    toast.error('Save failed');
  } finally {
    // 结束保存态
    saving.value = false;
  }
}

// 挂载后读取一次设置
onMounted(loadSettings);
</script>

<template>
  <!-- 外层卡片容器 -->
  <Card>
    <!-- 卡片内容区 -->
    <CardContent>
      <!-- 页面容器与标题说明（桌面端更大内边距） -->
      <div class="hidden space-y-6 p-10 pb-16 md:block">
        <!-- 标题与副标题 -->
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            {{ $t('account.settings.title') }}
          </h2>
          <p class="text-muted-foreground">
            {{ $t('account.settings.description') }}
          </p>
        </div>

        <!-- 账号安全模块（现有组件） -->
        <Separator class="my-6" />
        <SecurityPage />

        <Separator class="my-6" />

        <!-- 隐私设置 -->
        <div class="space-y-2">
          <h3 class="text-lg font-semibold">
            {{ $t('account.settings.privacy') }}
          </h3>
          <div class="grid gap-4">
            <!-- 资料可见范围 -->
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">
                  {{ $t('account.settings.visibility') }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{
                    $t('account.settings.visibilityDesc')
                  }}
                </div>
              </div>
              <Select v-model="profile_visibility">
                <SelectTrigger class="w-[140px]"
                  ><SelectValue placeholder="-"
                /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="public">{{
                    $t('account.settings.visibilityPublic')
                  }}</SelectItem>
                  <SelectItem value="private">{{
                    $t('account.settings.visibilityPrivate')
                  }}</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <!-- 在线状态是否展示 -->
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">
                  {{ $t('account.settings.showOnline') }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{
                    $t('account.settings.showOnlineDesc')
                  }}
                </div>
              </div>
              <Switch
                v-model:checked="show_online_status"
              />
            </div>

            <!-- 是否允许陌生人私信 -->
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">
                  {{ $t('account.settings.allowDM') }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{ $t('account.settings.allowDMDesc') }}
                </div>
              </div>
              <Switch
                v-model:checked="allow_dm_from_strangers"
              />
            </div>
          </div>
        </div>

        <Separator class="my-6" />

        <!-- 通知设置 -->
        <div class="space-y-2">
          <h3 class="text-lg font-semibold">
            {{ $t('account.settings.notifications') }}
          </h3>
          <div class="grid gap-4">
            <!-- 推送通知开关 -->
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">
                  {{ $t('account.settings.push') }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{ $t('account.settings.pushDesc') }}
                </div>
              </div>
              <Switch
                v-model:checked="push_notification_enabled"
              />
            </div>
            <!-- 邮件通知开关 -->
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">
                  {{ $t('account.settings.email') }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{ $t('account.settings.emailDesc') }}
                </div>
              </div>
              <Switch
                v-model:checked="email_notification_enabled"
              />
            </div>
          </div>
        </div>

        <Separator class="my-6" />

        <!-- 安全其他 -->
        <div class="space-y-2">
          <h3 class="text-lg font-semibold">
            {{ $t('account.settings.securityOther') }}
          </h3>
          <div class="grid gap-4">
            <!-- 二次验证开关 -->
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">
                  {{ $t('account.settings.2fa') }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{ $t('account.settings.2faDesc') }}
                </div>
              </div>
              <Switch v-model:checked="twoFactorEnabled" />
            </div>
            <!-- 登录提醒开关 -->
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">
                  {{ $t('account.settings.loginAlerts') }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{
                    $t('account.settings.loginAlertsDesc')
                  }}
                </div>
              </div>
              <Switch v-model:checked="loginAlerts" />
            </div>
          </div>
        </div>

        <!-- 操作按钮 -->
        <div class="mt-6 flex justify-end gap-2">
          <Button
            variant="outline"
            :disabled="loading || saving"
            @click="loadSettings()"
            >{{ $t('common.refresh') }}</Button
          >
          <Button
            :disabled="loading || saving"
            @click="saveSettings()"
            >{{ $t('account.settings.save') }}</Button
          >
        </div>
      </div>
    </CardContent>
  </Card>
</template>
