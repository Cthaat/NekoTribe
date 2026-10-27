use crate::{
    auth::{
        sessions::{
            SessionCredential, SessionRepository, SessionRotation, SessionStoreError, StoreFuture,
        },
        TokenClaims,
    },
    db::{oracle::BindMap, pool::OraclePool, row::DbRow, value::DbValue},
};

pub const TOUCH_SQL:&str="UPDATE n_auth_sessions SET last_accessed_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND access_jti = :access_jti AND revoked_at IS NULL AND access_token_expires_at > CURRENT_TIMESTAMP";
pub const REVOKE_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND revoked_at IS NULL";
pub const REVOKE_OTHERS_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id <> :session_id AND revoked_at IS NULL";
pub const LOGOUT_ACCESS_SQL: &str = "UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL AND access_jti = :access_jti";
pub const LOGOUT_REFRESH_SQL: &str = "UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL AND refresh_token_hash = :refresh_token_hash";
pub const PREFLIGHT_SQL:&str="SELECT user_id, session_id, access_jti, access_token_expires_at, refresh_token_hash, refresh_token_expires_at, last_refresh_at, revoked_at, last_accessed_at FROM n_auth_sessions WHERE 1 = 0";
pub const ROTATE_SQL: &str = "UPDATE n_auth_sessions SET access_jti = :access_jti, refresh_token_hash = :refresh_token_hash, access_token_expires_at = CAST(TO_TIMESTAMP_TZ(:access_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP), refresh_token_expires_at = CAST(TO_TIMESTAMP_TZ(:refresh_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP), last_refresh_at = CURRENT_TIMESTAMP, last_accessed_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND refresh_token_hash = :old_refresh_hash AND revoked_at IS NULL AND refresh_token_expires_at > CURRENT_TIMESTAMP";

pub trait SessionExecutor: Send + Sync {
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64>;
    fn preflight(&self, sql: &'static str) -> StoreFuture<'_, ()>;
    fn query(&self, _sql: &'static str, _binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async { Err(SessionStoreError) })
    }
}
pub struct OracleSessions<E> {
    pub executor: E,
}
impl<E: SessionExecutor> OracleSessions<E> {
    pub async fn preflight(&self) -> Result<(), SessionStoreError> {
        self.executor.preflight(PREFLIGHT_SQL).await
    }
}
impl<E: SessionExecutor> SessionRepository for OracleSessions<E> {
    fn reset_password<'a>(&'a self, email: &'a str, hash: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            self.executor
                .execute(
                    "UPDATE n_users SET password_hash = :password_hash WHERE email = :email",
                    BindMap::from([
                        ("password_hash".into(), DbValue::String(hash.into())),
                        ("email".into(), DbValue::String(email.into())),
                    ]),
                )
                .await
        })
    }
    fn registration_otp<'a>(&'a self, email: &'a str, id: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let b = BindMap::from([
                ("account".into(), DbValue::String(email.into())),
                ("verification_id".into(), DbValue::String(id.into())),
            ]);
            let rows=self.executor.query("SELECT verified_at FROM n_auth_otp_events WHERE account = :account AND otp_type = 'register' AND verification_id = :verification_id AND expires_at > CURRENT_TIMESTAMP AND verified_at IS NOT NULL",b).await?;
            Ok(!rows.is_empty())
        })
    }
    fn registration_exists<'a>(
        &'a self,
        email: &'a str,
        username: &'a str,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let b = BindMap::from([
                ("email".into(), DbValue::String(email.into())),
                ("username".into(), DbValue::String(username.into())),
            ]);
            let rows=self.executor.query("SELECT COUNT(*) AS total FROM n_users WHERE email = :email OR username = :username",b).await?;
            Ok(rows
                .first()
                .map(|r| row_number(r, "TOTAL"))
                .unwrap_or_default()
                > 0)
        })
    }
    fn registration_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let rows = self
                .executor
                .query("SELECT seq_user_id.NEXTVAL AS id FROM dual", BindMap::new())
                .await?;
            row_id(rows.first().ok_or(SessionStoreError)?, "ID")
        })
    }
    fn registration_insert<'a>(
        &'a self,
        r: &'a crate::auth::registration::RegistrationRecord,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let nullable = |s: &str| {
                if s.is_empty() {
                    DbValue::Null
                } else {
                    DbValue::String(s.into())
                }
            };
            let b = BindMap::from([
                ("user_id".into(), DbValue::I64(r.user_id as i64)),
                ("email".into(), DbValue::String(r.email.clone())),
                ("username".into(), DbValue::String(r.username.clone())),
                (
                    "password_hash".into(),
                    DbValue::String(r.password_hash.clone()),
                ),
                (
                    "display_name".into(),
                    DbValue::String(r.display_name.clone()),
                ),
                ("bio".into(), nullable(&r.bio)),
                ("location".into(), nullable(&r.location)),
                ("phone".into(), nullable(&r.phone)),
                ("birth_date".into(), nullable(&r.birth_date)),
            ]);
            self.executor.execute("INSERT INTO n_users (user_id,email,username,password_hash,display_name,bio,location,phone,birth_date,email_verified_at,status) VALUES (:user_id,:email,:username,:password_hash,:display_name,:bio,:location,:phone,CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END,CURRENT_TIMESTAMP,'active')",b).await?;
            Ok(())
        })
    }
    fn otp_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let rows = self
                .executor
                .query(
                    "SELECT seq_otp_event_id.NEXTVAL AS id FROM dual",
                    BindMap::new(),
                )
                .await?;
            row_id(rows.first().ok_or(SessionStoreError)?, "ID")
        })
    }
    fn otp_insert<'a>(&'a self, event: &'a crate::auth::otp::OtpEvent) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let binds = BindMap::from([
                ("otp_event_id".into(), DbValue::I64(event.sequence as i64)),
                ("account".into(), DbValue::String(event.account.clone())),
                ("otp_type".into(), DbValue::String(event.kind.clone())),
                (
                    "send_channel".into(),
                    DbValue::String(event.channel.clone()),
                ),
                (
                    "verification_code_hash".into(),
                    DbValue::String(event.hash.clone()),
                ),
                ("verification_id".into(), DbValue::String(event.id.clone())),
                (
                    "expires_at".into(),
                    DbValue::String(oracle_time(&event.expires)),
                ),
            ]);
            self.executor.execute("INSERT INTO n_auth_otp_events (otp_event_id,account,otp_type,send_channel,verification_code_hash,verification_id,expires_at) VALUES (:otp_event_id,:account,:otp_type,:send_channel,:verification_code_hash,:verification_id,CAST(TO_TIMESTAMP_TZ(:expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))",binds).await?;
            Ok(())
        })
    }
    fn otp_lookup<'a>(
        &'a self,
        account: &'a str,
        kind: &'a str,
        id: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            let binds = BindMap::from([
                ("account".into(), DbValue::String(account.into())),
                ("otp_type".into(), DbValue::String(kind.into())),
                ("verification_id".into(), DbValue::String(id.into())),
            ]);
            let rows=self.executor.query("SELECT verification_code_hash FROM n_auth_otp_events WHERE account = :account AND otp_type = :otp_type AND verification_id = :verification_id AND expires_at > CURRENT_TIMESTAMP ORDER BY created_at DESC FETCH FIRST 1 ROWS ONLY",binds).await?;
            Ok(rows.first().map(|r| row_text(r, "VERIFICATION_CODE_HASH")))
        })
    }
    fn otp_mark<'a>(&'a self, id: &'a str) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.executor.execute("UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP WHERE verification_id = :verification_id",BindMap::from([("verification_id".into(),DbValue::String(id.into()))])).await?;
            Ok(())
        })
    }
    fn otp_verified_at<'a>(&'a self, id: &'a str) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            let rows=self.executor.query("SELECT verified_at FROM n_auth_otp_events WHERE verification_id = :verification_id",BindMap::from([("verification_id".into(),DbValue::String(id.into()))])).await?;
            Ok(rows
                .first()
                .map(|r| row_text(r, "VERIFIED_AT"))
                .filter(|v| !v.is_empty())
                .map(|v| profile_date(&v)))
        })
    }
    fn list_sessions<'a>(
        &'a self,
        user: u64,
        page: crate::auth::session_list::SessionPage,
    ) -> StoreFuture<'a, (Vec<crate::auth::session_list::SessionItem>, u64)> {
        Box::pin(async move {
            let count = self.executor.query("SELECT COUNT(*) AS total FROM n_auth_sessions WHERE user_id = :user_id AND revoked_at IS NULL", user_bind(user)).await?;
            let total = u64::try_from(
                count
                    .first()
                    .map(|r| row_number(r, "TOTAL"))
                    .unwrap_or_default(),
            )
            .map_err(|_| SessionStoreError)?;
            let binds = BindMap::from([
                ("user_id".into(), DbValue::I64(user as i64)),
                ("start_row".into(), DbValue::F64(page.start)),
                ("end_row".into(), DbValue::F64(page.end)),
            ]);
            let rows=self.executor.query("SELECT session_id, device_info, ip_address, last_accessed_at, created_at FROM (SELECT session_id, device_info, ip_address, last_accessed_at, created_at, ROW_NUMBER() OVER (ORDER BY last_accessed_at DESC) AS rn FROM n_auth_sessions WHERE user_id = :user_id AND revoked_at IS NULL) WHERE rn BETWEEN :start_row AND :end_row",binds).await?;
            Ok((
                rows.iter()
                    .map(|row| crate::auth::session_list::SessionItem {
                        session_id: row_text(row, "SESSION_ID"),
                        device_info: row_text(row, "DEVICE_INFO"),
                        ip_address: row_text(row, "IP_ADDRESS"),
                        last_accessed_at: profile_date(&row_text(row, "LAST_ACCESSED_AT")),
                        created_at: profile_date(&row_text(row, "CREATED_AT")),
                        is_current: false,
                    })
                    .collect(),
                total,
            ))
        })
    }
    fn two_factor_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let snapshot = self.executor.readiness_snapshot().await?;
            crate::auth::readiness::validate_snapshot(&snapshot)
        })
    }
    fn login_account<'a>(
        &'a self,
        account: &'a str,
    ) -> StoreFuture<'a, Option<crate::auth::login::LoginAccount>> {
        Box::pin(async move {
            let rows = self.executor.query("SELECT user_id, username, password_hash, status, is_active FROM n_users WHERE email = :account OR username = :account FETCH FIRST 1 ROWS ONLY", BindMap::from([("account".into(), DbValue::String(account.into()))])).await?;
            rows.first()
                .map(|r| {
                    Ok(crate::auth::login::LoginAccount {
                        user_id: row_id(r, "USER_ID")?,
                        username: row_text(r, "USERNAME"),
                        password_hash: row_text(r, "PASSWORD_HASH"),
                        status: row_text(r, "STATUS"),
                        active: row_number(r, "IS_ACTIVE") == 1,
                    })
                })
                .transpose()
        })
    }
    fn login_two_factor<'a>(&'a self, user: u64) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let rows = self.executor.query("SELECT NVL(us.two_factor_enabled, 0) AS two_factor_enabled, tf.enabled_at FROM n_users u LEFT JOIN n_user_settings us ON us.user_id = u.user_id LEFT JOIN n_user_two_factor_secrets tf ON tf.user_id = u.user_id WHERE u.user_id = :user_id", user_bind(user)).await?;
            Ok(rows.first().is_some_and(|r| {
                row_number(r, "TWO_FACTOR_ENABLED") != 0
                    && r.get("ENABLED_AT")
                        .is_some_and(|v| !matches!(v, DbValue::Null))
            }))
        })
    }
    fn login_trusted_device<'a>(
        &'a self,
        user: u64,
        device: &'a crate::auth::login::LoginDevice,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let fingerprint: String = device.fingerprint.chars().take(200).collect();
            if fingerprint.is_empty() || fingerprint == "unknown" {
                return Ok(false);
            }
            let mut binds = user_bind(user);
            binds.insert("device_fingerprint".into(), DbValue::String(fingerprint));
            let rows = self.executor.query("SELECT trusted_device_id FROM n_user_two_factor_trusted_devices WHERE user_id = :user_id AND device_fingerprint = :device_fingerprint AND expires_at > CURRENT_TIMESTAMP AND revoked_at IS NULL FETCH FIRST 1 ROWS ONLY", binds).await?;
            let Some(row) = rows.first() else {
                return Ok(false);
            };
            let id = row_id(row, "TRUSTED_DEVICE_ID")?;
            let mut binds = device_bind(device, true);
            binds.remove("device_fingerprint");
            binds.insert("trusted_device_id".into(), DbValue::I64(id as i64));
            self.executor.execute("UPDATE n_user_two_factor_trusted_devices SET last_used_at = CURRENT_TIMESTAMP, device_info = :device_info, ip_address = :ip_address, user_agent = :user_agent WHERE trusted_device_id = :trusted_device_id", binds).await?;
            Ok(true)
        })
    }
    fn login_challenge<'a>(
        &'a self,
        c: &'a crate::auth::login::LoginChallenge,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let mut b = device_bind(&c.device, true);
            b.extend(user_bind(c.user_id));
            b.insert("challenge_id".into(), DbValue::String(c.id.clone()));
            b.insert("remember_me".into(), DbValue::I64(i64::from(c.remember)));
            b.insert(
                "expires_at".into(),
                DbValue::String(oracle_time(&c.expires_at)),
            );
            self.executor.execute("INSERT INTO n_auth_two_factor_challenges (challenge_id,user_id,remember_me,device_info,device_fingerprint,ip_address,user_agent,expires_at) VALUES (:challenge_id,:user_id,:remember_me,:device_info,:device_fingerprint,:ip_address,:user_agent,CAST(TO_TIMESTAMP_TZ(:expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))", b).await?;
            Ok(())
        })
    }
    fn login_insert_session<'a>(
        &'a self,
        s: &'a crate::auth::login::LoginSession,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let mut b = device_bind(&s.device, false);
            b.extend(user_bind(s.user_id));
            b.insert("session_id".into(), DbValue::String(s.id.clone()));
            b.insert("access_jti".into(), DbValue::String(s.access_jti.clone()));
            b.insert(
                "refresh_token_hash".into(),
                DbValue::String(s.refresh_hash.clone()),
            );
            b.insert(
                "access_token_expires_at".into(),
                DbValue::String(oracle_time(&s.access_expires_at)),
            );
            b.insert(
                "refresh_token_expires_at".into(),
                DbValue::String(oracle_time(&s.refresh_expires_at)),
            );
            self.executor.execute("INSERT INTO n_auth_sessions (session_id,user_id,access_jti,refresh_token_hash,device_info,device_fingerprint,ip_address,user_agent,access_token_expires_at,refresh_token_expires_at) VALUES (:session_id,:user_id,:access_jti,:refresh_token_hash,:device_info,:device_fingerprint,:ip_address,:user_agent,CAST(TO_TIMESTAMP_TZ(:access_token_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP),CAST(TO_TIMESTAMP_TZ(:refresh_token_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))", b).await?;
            self.executor
                .execute(
                    "UPDATE n_users SET last_login_at = CURRENT_TIMESTAMP WHERE user_id = :user_id",
                    user_bind(s.user_id),
                )
                .await?;
            Ok(())
        })
    }
    fn known_login_device<'a>(&'a self, user: u64, fingerprint: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let mut b = user_bind(user);
            b.insert(
                "device_fingerprint".into(),
                DbValue::String(fingerprint.into()),
            );
            let rows=self.executor.query("SELECT COUNT(*) AS total FROM n_auth_sessions WHERE user_id=:user_id AND device_fingerprint=:device_fingerprint",b).await?;
            let row = rows.first().ok_or(SessionStoreError)?;
            Ok(row_number(row, "TOTAL") > 0)
        })
    }
    fn record_login_alert<'a>(
        &'a self,
        session: &'a crate::auth::login::LoginSession,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let rows=self.executor.query("SELECT NVL(us.login_alerts,1) AS login_alerts,NVL(us.email_notification_enabled,1) AS email_notification_enabled FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id",user_bind(session.user_id)).await?;
            if rows
                .first()
                .is_some_and(|r| row_number(r, "LOGIN_ALERTS") == 0)
            {
                return Ok(());
            }
            let mut b = user_bind(session.user_id);
            b.insert(
                "notification_type".into(),
                DbValue::String("login_alert".into()),
            );
            let rows=self.executor.query("SELECT NVL(us.push_notification_enabled,1) AS push_notification_enabled,NVL(np.is_enabled,1) AS type_enabled FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id LEFT JOIN n_notification_preferences np ON np.user_id=u.user_id AND np.notification_type=:notification_type WHERE u.user_id=:user_id AND u.is_active=1",b).await?;
            if rows
                .first()
                .is_none_or(|r| row_number(r, "TYPE_ENABLED") == 0)
            {
                return Ok(());
            }
            let ids = self
                .executor
                .query(
                    "SELECT seq_notification_id.NEXTVAL AS id FROM dual",
                    BindMap::new(),
                )
                .await?;
            let id = row_id(ids.first().ok_or(SessionStoreError)?, "ID")?;
            let device = &session.device;
            let metadata=serde_json::json!({"session_id":session.id,"device_info":device.info,"device_fingerprint":device.fingerprint,"ip_address":device.ip,"user_agent":device.user_agent}).to_string();
            let mut b = user_bind(session.user_id);
            b.insert("notification_id".into(), DbValue::I64(id as i64));
            b.insert("actor_id".into(), DbValue::Null);
            b.insert("type".into(), DbValue::String("login_alert".into()));
            b.insert("title".into(), DbValue::String("新设备登录提醒".into()));
            b.insert(
                "message".into(),
                DbValue::String(format!(
                    "你的账号刚刚通过新设备登录：{}",
                    if device.info.is_empty() {
                        "unknown"
                    } else {
                        &device.info
                    }
                )),
            );
            b.insert(
                "resource_type".into(),
                DbValue::String("auth_session".into()),
            );
            b.insert("resource_id".into(), DbValue::Null);
            b.insert("priority".into(), DbValue::String("high".into()));
            b.insert("metadata_json".into(), DbValue::String(metadata));
            self.executor.execute("INSERT INTO n_notifications (notification_id,user_id,actor_id,type,title,message,resource_type,resource_id,priority,metadata_json) VALUES (:notification_id,:user_id,:actor_id,:type,:title,:message,:resource_type,:resource_id,:priority,:metadata_json)",b).await?;
            Ok(())
        })
    }
    fn login_profile<'a>(&'a self, user: u64) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move {
            let mut b = user_bind(user);
            b.insert("viewer_id".into(), DbValue::I64(user as i64));
            let rows = self.executor.query("SELECT user_id,email,username,avatar_url,display_name,bio,location,website,phone,TO_CHAR(birth_date,'YYYY-MM-DD') AS birth_date,email_verified_at,is_verified,is_active,status,followers_count,following_count,posts_count,likes_count,bookmarks_count,comments_count,'online' AS online_status,(SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL) AS last_seen_at,created_at,updated_at,fn_get_user_relationship(:viewer_id,u.user_id) AS relation FROM v_user_profile_self u WHERE u.user_id=:user_id", b).await?;
            Ok(rows.first().map(profile_json))
        })
    }
    fn challenge_lookup<'a>(
        &'a self,
        id: &'a str,
    ) -> StoreFuture<'a, Option<crate::auth::login::ChallengeRow>> {
        Box::pin(async move {
            let b = BindMap::from([("challenge_id".into(), DbValue::String(id.into()))]);
            let rows=self.executor.query("SELECT c.challenge_id,c.user_id,c.remember_me,c.device_info,c.device_fingerprint,c.ip_address,c.user_agent,u.username FROM n_auth_two_factor_challenges c JOIN n_users u ON u.user_id=c.user_id WHERE c.challenge_id=:challenge_id AND c.expires_at>CURRENT_TIMESTAMP AND c.consumed_at IS NULL AND u.is_active=1 AND u.status='active'",b).await?;
            rows.first()
                .map(|r| {
                    Ok(crate::auth::login::ChallengeRow {
                        user_id: row_id(r, "USER_ID")?,
                        username: row_text(r, "USERNAME"),
                        remember: row_number(r, "REMEMBER_ME") != 0,
                        device: crate::auth::login::LoginDevice {
                            fingerprint: row_text(r, "DEVICE_FINGERPRINT"),
                            info: row_text(r, "DEVICE_INFO"),
                            ip: row_text(r, "IP_ADDRESS"),
                            user_agent: row_text(r, "USER_AGENT"),
                        },
                    })
                })
                .transpose()
        })
    }
    fn two_factor_secret<'a>(
        &'a self,
        user: u64,
    ) -> StoreFuture<'a, Option<crate::auth::login::EncryptedSecret>> {
        Box::pin(async move {
            let rows=self.executor.query("SELECT secret_encrypted,secret_iv,secret_auth_tag,enabled_at FROM n_user_two_factor_secrets WHERE user_id=:user_id",user_bind(user)).await?;
            Ok(rows.first().map(|r| crate::auth::login::EncryptedSecret {
                encrypted: row_text(r, "SECRET_ENCRYPTED"),
                iv: row_text(r, "SECRET_IV"),
                tag: row_text(r, "SECRET_AUTH_TAG"),
                enabled: r
                    .get("ENABLED_AT")
                    .is_some_and(|v| !matches!(v, DbValue::Null)),
            }))
        })
    }
    fn recovery_codes<'a>(
        &'a self,
        user: u64,
    ) -> StoreFuture<'a, Vec<crate::auth::login::RecoveryCode>> {
        Box::pin(async move {
            self.executor.query("SELECT recovery_code_id,code_hash FROM n_user_two_factor_recovery_codes WHERE user_id=:user_id AND used_at IS NULL ORDER BY created_at ASC",user_bind(user)).await?.iter().map(|r|Ok(crate::auth::login::RecoveryCode{id:row_id(r,"RECOVERY_CODE_ID")?,hash:row_text(r,"CODE_HASH")})).collect()
        })
    }
    fn consume_recovery<'a>(&'a self, id: u64) -> StoreFuture<'a, u64> {
        self.executor.execute("UPDATE n_user_two_factor_recovery_codes SET used_at=CURRENT_TIMESTAMP WHERE recovery_code_id=:recovery_code_id AND used_at IS NULL",BindMap::from([("recovery_code_id".into(),DbValue::I64(id as i64))]))
    }
    fn consume_challenge<'a>(&'a self, id: &'a str) -> StoreFuture<'a, u64> {
        self.executor.execute("UPDATE n_auth_two_factor_challenges SET consumed_at=CURRENT_TIMESTAMP WHERE challenge_id=:challenge_id AND consumed_at IS NULL AND expires_at>CURRENT_TIMESTAMP",BindMap::from([("challenge_id".into(),DbValue::String(id.into()))]))
    }
    fn trust_challenge_device<'a>(
        &'a self,
        row: &'a crate::auth::login::ChallengeRow,
        expires_at: &'a str,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let fingerprint: String = row.device.fingerprint.chars().take(200).collect();
            if fingerprint.is_empty() || fingerprint == "unknown" {
                return Ok(());
            }
            let idrows = self
                .executor
                .query(
                    "SELECT seq_2fa_trusted_device_id.NEXTVAL AS id FROM dual",
                    BindMap::new(),
                )
                .await?;
            let id = row_id(idrows.first().ok_or(SessionStoreError)?, "ID")?;
            let mut b = device_bind(&row.device, true);
            b.extend(user_bind(row.user_id));
            b.insert("trusted_device_id".into(), DbValue::I64(id as i64));
            b.insert(
                "expires_at".into(),
                DbValue::String(oracle_time(expires_at)),
            );
            self.executor.execute("MERGE INTO n_user_two_factor_trusted_devices target USING (SELECT :user_id AS user_id,:device_fingerprint AS device_fingerprint FROM dual) src ON (target.user_id=src.user_id AND target.device_fingerprint=src.device_fingerprint) WHEN MATCHED THEN UPDATE SET device_info=:device_info,ip_address=:ip_address,user_agent=:user_agent,expires_at=CAST(TO_TIMESTAMP_TZ(:expires_at,'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP),revoked_at=NULL,last_used_at=CURRENT_TIMESTAMP WHEN NOT MATCHED THEN INSERT (trusted_device_id,user_id,device_fingerprint,device_info,ip_address,user_agent,expires_at) VALUES (:trusted_device_id,:user_id,:device_fingerprint,:device_info,:ip_address,:user_agent,CAST(TO_TIMESTAMP_TZ(:expires_at,'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))",b).await?;
            Ok(())
        })
    }
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(claims.user_id, &claims.session_id);
        binds.insert("access_jti".into(), DbValue::String(claims.jti.clone()));
        self.executor.execute(TOUCH_SQL, binds)
    }
    fn revoke<'a>(&'a self, user_id: u64, id: &'a str) -> StoreFuture<'a, u64> {
        self.executor
            .execute(REVOKE_SQL, session_binds(user_id, id))
    }
    fn revoke_others<'a>(&'a self, user_id: u64, current: &'a str) -> StoreFuture<'a, u64> {
        self.executor
            .execute(REVOKE_OTHERS_SQL, session_binds(user_id, current))
    }
    fn revoke_current<'a>(
        &'a self,
        user_id: u64,
        session: &'a str,
        credential: &'a SessionCredential,
    ) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(user_id, session);
        let sql = match credential {
            SessionCredential::AccessJti(jti) => {
                binds.insert("access_jti".into(), DbValue::String(jti.clone()));
                LOGOUT_ACCESS_SQL
            }
            SessionCredential::RefreshHash(hash) => {
                binds.insert("refresh_token_hash".into(), DbValue::String(hash.clone()));
                LOGOUT_REFRESH_SQL
            }
        };
        self.executor.execute(sql, binds)
    }
    fn rotate<'a>(&'a self, rotation: &'a SessionRotation) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(rotation.user_id, &rotation.session_id);
        for (key, value) in [
            ("access_jti", &rotation.access_jti),
            ("refresh_token_hash", &rotation.refresh_hash),
            ("old_refresh_hash", &rotation.old_refresh_hash),
        ] {
            binds.insert(key.into(), DbValue::String(value.clone()));
        }
        for (key, value) in [
            ("access_expires_at", &rotation.access_expires_at),
            ("refresh_expires_at", &rotation.refresh_expires_at),
        ] {
            binds.insert(
                key.into(),
                DbValue::String(value.trim_end_matches('Z').to_owned() + "+00:00"),
            );
        }
        self.executor.execute(ROTATE_SQL, binds)
    }
}
fn session_binds(user: u64, id: &str) -> BindMap {
    BindMap::from([
        ("user_id".into(), DbValue::I64(user as i64)),
        ("session_id".into(), DbValue::String(id.into())),
    ])
}
impl SessionExecutor for OraclePool {
    fn readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async move {
            self.run_blocking(crate::auth::readiness::collect_snapshot)
                .await
                .map_err(|_| SessionStoreError)
        })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.query_rows(sql, binds)
                .await
                .map_err(|_| SessionStoreError)
        })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            OraclePool::execute(self, sql, binds)
                .await
                .map(|r| r.rows_affected)
                .map_err(|_| SessionStoreError)
        })
    }
    fn preflight(&self, sql: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async move {
            self.query_rows(sql, BindMap::new())
                .await
                .map(|_| ())
                .map_err(|_| SessionStoreError)
        })
    }
}

fn user_bind(user: u64) -> BindMap {
    BindMap::from([("user_id".into(), DbValue::I64(user as i64))])
}
fn row_number(row: &DbRow, key: &str) -> i64 {
    row.get(key).and_then(DbValue::as_i64).unwrap_or_default()
}
fn row_id(row: &DbRow, key: &str) -> Result<u64, SessionStoreError> {
    u64::try_from(row_number(row, key))
        .ok()
        .filter(|n| *n > 0 && *n <= 9_007_199_254_740_991)
        .ok_or(SessionStoreError)
}
fn row_text(row: &DbRow, key: &str) -> String {
    row.get(key)
        .and_then(DbValue::as_str)
        .unwrap_or_default()
        .to_owned()
}
fn oracle_time(value: &str) -> String {
    value.trim_end_matches('Z').to_owned() + "+00:00"
}
fn device_bind(device: &crate::auth::login::LoginDevice, truncate: bool) -> BindMap {
    let text = |value: &str| {
        if truncate {
            value.chars().take(200).collect()
        } else {
            value.to_owned()
        }
    };
    BindMap::from([
        (
            "device_fingerprint".into(),
            DbValue::String(text(&device.fingerprint)),
        ),
        ("device_info".into(), DbValue::String(text(&device.info))),
        ("ip_address".into(), DbValue::String(device.ip.clone())),
        (
            "user_agent".into(),
            DbValue::String(device.user_agent.clone()),
        ),
    ])
}
fn profile_json(r: &DbRow) -> serde_json::Value {
    let relation = row_text(r, "RELATION");
    let avatar = row_text(r, "AVATAR_URL");
    let avatar = avatar.trim();
    let optional = |key| r.get(key).and_then(DbValue::as_str).map(str::to_owned);
    serde_json::json!({"user_id":row_number(r,"USER_ID"),"username":row_text(r,"USERNAME"),"display_name":row_text(r,"DISPLAY_NAME"),"avatar_url":if avatar.is_empty() || avatar=="/default-avatar.png" || avatar=="default-avatar.png" {"/storage/default-avatar.png"} else {avatar},"bio":row_text(r,"BIO"),"location":row_text(r,"LOCATION"),"website":row_text(r,"WEBSITE"),"is_verified":row_number(r,"IS_VERIFIED"),"followers_count":row_number(r,"FOLLOWERS_COUNT"),"following_count":row_number(r,"FOLLOWING_COUNT"),"posts_count":row_number(r,"POSTS_COUNT"),"likes_count":row_number(r,"LIKES_COUNT"),"relationship":{"is_self":relation=="self","is_following":relation=="following" || relation=="mutual_follow","is_blocked":relation=="blocked_by","is_blocking":relation=="blocking","relation":if relation.is_empty(){"none"}else{&relation}},"online_status":"online","last_seen_at":optional("LAST_SEEN_AT").map(|s|profile_date(&s)),"email":row_text(r,"EMAIL"),"phone":row_text(r,"PHONE"),"birth_date":optional("BIRTH_DATE"),"email_verified_at":optional("EMAIL_VERIFIED_AT").map(|s|profile_date(&s)),"is_active":row_number(r,"IS_ACTIVE"),"status":row_text(r,"STATUS"),"created_at":optional("CREATED_AT").map(|s|profile_date(&s)).unwrap_or_default(),"updated_at":optional("UPDATED_AT").map(|s|profile_date(&s)).unwrap_or_default()})
}

fn profile_date(text: &str) -> String {
    use chrono::{SecondsFormat, TimeZone};
    if let Ok(date) = chrono::DateTime::parse_from_rfc3339(text) {
        return date
            .with_timezone(&chrono::Utc)
            .to_rfc3339_opts(SecondsFormat::Millis, true);
    }
    if let Ok(date) = chrono::DateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f %:z") {
        return date
            .with_timezone(&chrono::Utc)
            .to_rfc3339_opts(SecondsFormat::Millis, true);
    }
    if let Ok(date) = chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f") {
        if let Some(local) = chrono::Local.from_local_datetime(&date).earliest() {
            return local
                .with_timezone(&chrono::Utc)
                .to_rfc3339_opts(SecondsFormat::Millis, true);
        }
    }
    text.to_owned()
}

#[cfg(test)]
mod profile_tests {
    use super::*;
    #[test]
    fn oracle_timestamp_and_whitespace_avatar_map_like_default_nuxt_shape() {
        use chrono::TimeZone;
        let text = oracle::sql_type::Timestamp::new(2017, 8, 9, 11, 22, 33, 500_000_000)
            .unwrap()
            .to_string();
        let expected = chrono::Local
            .with_ymd_and_hms(2017, 8, 9, 11, 22, 33)
            .earliest()
            .unwrap()
            .with_timezone(&chrono::Utc)
            .format("%Y-%m-%dT%H:%M:%S.500Z")
            .to_string();
        let row = DbRow::from([
            (
                "AVATAR_URL".into(),
                DbValue::String(" /default-avatar.png ".into()),
            ),
            ("CREATED_AT".into(), DbValue::String(text)),
        ]);
        let profile = profile_json(&row);
        assert_eq!(profile["avatar_url"], "/storage/default-avatar.png");
        assert_eq!(profile["created_at"], expected);
        assert_eq!(
            profile_date("2017-08-09 11:22:33.500 -08:00"),
            "2017-08-09T19:22:33.500Z"
        );
    }
}
