$path='c:\Code\NekoTribe\doc\neko_tribe-oracle-v2.sql'
$raw=Get-Content -LiteralPath $path -Raw

$colMap=@{
'access_jti'='访问令牌唯一标识（JTI）'
'access_token_expires_at'='访问令牌过期时间'
'account'='账号（邮箱或用户名）'
'action'='操作动作'
'admin_response'='管理员回复'
'allow_dm_from_strangers'='是否允许陌生人私信'
'alt_text'='媒体替代文本'
'appeal_message'='申诉内容'
'appeal_status'='申诉状态'
'avatar_url'='头像地址'
'ban_reason'='封禁原因'
'bio'='个人简介'
'bookmarks_count'='收藏数'
'comments_count'='评论数'
'content'='内容'
'cover_url'='封面图地址'
'created_at'='创建时间'
'created_by'='创建人'
'delete_reason'='删除原因'
'deleted_at'='删除时间'
'deleted_by'='删除操作人用户ID'
'description'='描述'
'details'='详情'
'device_fingerprint'='设备指纹'
'device_info'='设备信息'
'display_name'='显示名称'
'duration'='时长（秒）'
'email'='邮箱'
'email_notification_enabled'='是否开启邮件通知'
'email_verified_at'='邮箱验证时间'
'engagement_score'='互动热度分'
'expires_at'='过期时间'
'file_name'='文件名'
'file_size'='文件大小（字节）'
'followers_count'='粉丝数'
'following_count'='关注数'
'height'='高度'
'invite_code'='邀请码'
'ip_address'='IP地址'
'is_active'='是否启用'
'is_announcement'='是否公告'
'is_deleted'='是否删除'
'is_enabled'='是否启用'
'is_pinned'='是否置顶'
'is_read'='是否已读'
'is_trending'='是否热门'
'is_verified'='是否认证'
'join_approval'='入群是否需审批'
'joined_at'='加入时间'
'language'='语言'
'last_accessed_at'='最后访问时间'
'last_login_at'='最后登录时间'
'last_refresh_at'='最后刷新时间'
'likes_count'='点赞数'
'location'='位置'
'login_alerts'='是否开启登录提醒'
'max_uses'='最大使用次数'
'media_type'='媒体类型'
'media_urls'='媒体地址列表'
'member_count'='成员数'
'message'='消息内容'
'metadata_json'='扩展元数据（JSON）'
'mime_type'='MIME类型'
'mute_until'='禁言截止时间'
'name'='名称'
'name_lower'='名称小写'
'nickname'='群昵称'
'notification_type'='通知类型'
'otp_type'='验证码用途'
'password_hash'='密码哈希'
'phone'='手机号'
'policy_code'='策略编码'
'post_count'='帖子数'
'post_permission'='发帖权限'
'post_type'='帖子类型'
'posts_count'='发帖数'
'priority'='优先级'
'privacy'='可见性'
'profile_visibility'='资料可见性'
'public_url'='公开访问地址'
'push_notification_enabled'='是否开启推送通知'
'read_at'='已读时间'
'refresh_token_expires_at'='刷新令牌过期时间'
'refresh_token_hash'='刷新令牌哈希'
'replies_count'='回复数'
'resource_id'='资源ID'
'resource_type'='资源类型'
'responded_at'='响应时间'
'retweets_count'='转发数'
'revoked_at'='撤销时间'
'role'='角色'
'session_id'='会话ID'
'show_online_status'='是否显示在线状态'
'slug'='短标识'
'sort_order'='排序序号'
'statement_type'='处置类型'
'status'='状态'
'storage_key'='存储键'
'thumbnail_url'='缩略图地址'
'title'='标题'
'trending_score'='趋势分'
'two_factor_enabled'='是否开启双因素认证'
'type'='类型'
'updated_at'='更新时间'
'updated_by'='更新人'
'usage_count'='使用次数'
'used_count'='已使用次数'
'user_agent'='用户代理'
'username'='用户名'
'verification_code_hash'='验证码哈希'
'verification_id'='验证ID'
'verified_at'='验证时间'
'views_count'='浏览数'
'visibility'='可见范围'
'website'='个人网站'
'width'='宽度'
}

$tableColMap=@{
'n_users.user_id'='用户主键ID'
'n_users.status'='账户状态（active/disabled/suspended/pending）'
'n_user_follows.status'='关注状态（active/cancelled）'
'n_media_assets.status'='媒体处理状态（uploaded/processing/ready/failed）'
'n_notifications.type'='通知类型'
'n_group_members.status'='成员状态（pending/active/muted/banned）'
'n_group_members.role'='成员角色（owner/admin/moderator/member）'
'n_group_invites.status'='邀请状态（pending/accepted/rejected/expired）'
'n_account_statements.status'='处理状态（unread/read/resolved/dismissed/appealed）'
'n_statement_appeals.appeal_status'='申诉状态（pending/approved/rejected）'
'n_groups.privacy'='群组可见性（public/private/secret）'
'n_groups.post_permission'='群组发帖权限（all/admin_only/moderator_up）'
'n_posts.visibility'='帖子可见范围（public/followers/mentioned/private）'
'n_posts.post_type'='帖子类型（post/reply/repost/quote）'
}

function Convert-IdDesc([string]$col){
  switch ($col) {
    'user_id' { return '用户ID' }
    'post_id' { return '帖子ID' }
    'group_id' { return '群组ID' }
    'comment_id' { return '评论ID' }
    'notification_id' { return '通知ID' }
    'statement_id' { return '处置记录ID' }
    'appeal_id' { return '申诉ID' }
    'member_id' { return '成员ID' }
    'invite_id' { return '邀请ID' }
    'log_id' { return '日志ID' }
    'media_id' { return '媒体ID' }
    'tag_id' { return '标签ID' }
    'like_id' { return '点赞ID' }
    'bookmark_id' { return '收藏ID' }
    'follow_id' { return '关注关系ID' }
    'block_id' { return '屏蔽关系ID' }
    'mute_id' { return '静音关系ID' }
    'otp_event_id' { return '验证码事件ID' }
    'verification_id' { return '验证ID' }
    'owner_id' { return '所有者用户ID' }
    'owner_user_id' { return '归属用户ID' }
    'author_id' { return '作者用户ID' }
    'actor_id' { return '行为发起人用户ID' }
    'target_user_id' { return '目标用户ID' }
    'target_post_id' { return '目标帖子ID' }
    'target_comment_id' { return '目标评论ID' }
    'follower_id' { return '关注者用户ID' }
    'following_id' { return '被关注用户ID' }
    'mentioned_user_id' { return '被提及用户ID' }
    'reply_to_user_id' { return '回复目标用户ID' }
    'reply_to_post_id' { return '回复目标帖子ID' }
    'repost_of_post_id' { return '转发来源帖子ID' }
    'quoted_post_id' { return '引用帖子ID' }
    'parent_comment_id' { return '父评论ID' }
    'root_comment_id' { return '根评论ID' }
    'inviter_id' { return '邀请人用户ID' }
    'invitee_id' { return '被邀请用户ID' }
    'invited_by' { return '邀请来源用户ID' }
    'deleted_by' { return '删除操作人用户ID' }
    'avatar_media_id' { return '头像媒体ID' }
    'post_like_id' { return '帖子点赞ID' }
    'comment_like_id' { return '评论点赞ID' }
    'resource_id' { return '关联资源ID' }
    default {
      if($col -match '(.+)_id$'){ return ($Matches[1] + ' ID') }
      return $null
    }
  }
}

$updated=[regex]::Replace($raw,'(?im)^\s*COMMENT\s+ON\s+COLUMN\s+([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\s+IS\s+''[^'']*''\s*;',{ param($m)
  $table=$m.Groups[1].Value
  $col=$m.Groups[2].Value
  $k=($table+'.'+$col).ToLower()
  $ck=$col.ToLower()

  if($tableColMap.ContainsKey($k)){ $desc=$tableColMap[$k] }
  elseif($colMap.ContainsKey($ck)){ $desc=$colMap[$ck] }
  else {
    $idDesc=Convert-IdDesc $ck
    if($idDesc){$desc=$idDesc}else{$desc="$col 字段"}
  }

  return "COMMENT ON COLUMN $table.$col IS '$desc';"
})

Set-Content -LiteralPath $path -Value $updated -Encoding UTF8

$left=[regex]::Matches($updated,"COMMENT ON COLUMN [^\r\n]+ IS '[^']*字段';").Count
Write-Output ('remaining_generic_field_comments='+$left)
