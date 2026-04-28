$path='c:\Code\NekoTribe\doc\neko_tribe-oracle-v2.sql'
$raw=Get-Content -LiteralPath $path -Raw

$tableMap=@{
'n_users'='用户主表'
'n_user_stats'='用户统计表'
'n_auth_otp_events'='验证码事件表'
'n_auth_sessions'='认证会话表'
'n_user_follows'='用户关注关系表'
'n_user_blocks'='用户屏蔽关系表'
'n_user_mutes'='用户静音关系表'
'n_posts'='帖子主表'
'n_post_stats'='帖子统计表'
'n_media_assets'='媒体资源表'
'n_post_media'='帖子媒体关联表'
'n_post_likes'='帖子点赞表'
'n_post_bookmarks'='帖子收藏表'
'n_comments'='评论主表'
'n_comment_stats'='评论统计表'
'n_comment_likes'='评论点赞表'
'n_tags'='标签表'
'n_post_tags'='帖子标签关联表'
'n_post_mentions'='帖子提及关联表'
'n_notifications'='通知主表'
'n_notification_preferences'='通知偏好表'
'n_user_settings'='用户设置表'
'n_account_statements'='账户处置记录表'
'n_statement_appeals'='申诉表'
'n_groups'='群组主表'
'n_group_members'='群组成员表'
'n_group_posts'='群组帖子表'
'n_group_comments'='群组评论表'
'n_group_invites'='群组邀请表'
'n_group_audit_logs'='群组审计日志表'
'n_group_post_likes'='群组帖子点赞表'
'n_group_comment_likes'='群组评论点赞表'
}

$updated=[regex]::Replace($raw,'(?im)^\s*COMMENT\s+ON\s+TABLE\s+([A-Za-z0-9_]+)\s+IS\s+''[^'']*''\s*;',{ param($m)
  $table=$m.Groups[1].Value
  $k=$table.ToLower()
  if($tableMap.ContainsKey($k)){
    $desc=$tableMap[$k]
  } else {
    $desc=$table
  }
  return "COMMENT ON TABLE $table IS '$desc';"
})

Set-Content -LiteralPath $path -Value $updated -Encoding UTF8

$remain=[regex]::Matches($updated,"(?im)^\s*COMMENT\s+ON\s+TABLE\s+[A-Za-z0-9_]+\s+IS\s+'[^']*业务表';").Count
Write-Output ('remaining_business_placeholder='+$remain)
