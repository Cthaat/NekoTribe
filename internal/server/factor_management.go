package server

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"fmt"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/crypto/bcrypt"
	"net/http"
	"net/url"
	"strings"
)

type FactorMutation struct {
	Action           string
	Expected, New    FactorSecret
	RecoveryHashes   []string
	RecoveryID       int64
	UsesRecoveryCode bool
}

func (FactorMutation) String() string   { return "FactorMutation [redacted]" }
func (FactorMutation) GoString() string { return "FactorMutation [redacted]" }

const (
	factorApplied = iota
	factorChanged
	factorRecoveryUsed
)

type factorManagementStore interface {
	AccountCredential(context.Context, int64) (LoginAccount, bool, error)
	CheckTwoFactorSchema(context.Context) error
	SelfProfile(context.Context, int64) (SelfUser, bool, error)
	FindFactorSecret(context.Context, int64) (FactorSecret, bool, error)
	FindRecoveryCodes(context.Context, int64) ([]RecoveryCode, error)
	ApplyFactorMutation(context.Context, int64, FactorMutation) (int, error)
}

var _ factorManagementStore = OracleSessions{}

func randomFactorText(size int) (string, error) {
	b := make([]byte, size)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b), nil
}
func manageFactor(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, action string) {
	w.Header().Set("Cache-Control", "private, no-store")
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	store, ok := repository.(factorManagementStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	fail := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	if action != "confirm" {
		password := loginString(body["password"])
		if password == "" {
			respond(w, 400, 40001, "password 不能为空", nil)
			return
		}
		account, found, e := store.AccountCredential(r.Context(), user)
		if e != nil {
			fail()
			return
		}
		if !found {
			respond(w, 404, 40401, "用户不存在", nil)
			return
		}
		if !account.Active || account.Status != "active" {
			respond(w, 403, 40301, "账号不可用", nil)
			return
		}
		if !matchesLoginPassword(account.PasswordHash, password) {
			respond(w, 401, 40101, "密码错误", nil)
			return
		}
	}
	code := normalizeFactorCode(loginString(body["code"]))
	if action == "disable" && loginString(body["code"]) == "" {
		respond(w, 400, 40001, "code 不能为空", nil)
		return
	}
	if store.CheckTwoFactorSchema(r.Context()) != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	secret, found, e := store.FindFactorSecret(r.Context(), user)
	if e != nil {
		fail()
		return
	}
	mutation := FactorMutation{Action: action, Expected: secret}
	var data interface{}
	if action == "setup" {
		if found && secret.Enabled {
			respond(w, 422, 42201, "双因素认证已启用，请先关闭后再重新设置", nil)
			return
		}
		profile, found, e := store.SelfProfile(r.Context(), user)
		if e != nil {
			fail()
			return
		}
		if !found {
			respond(w, 404, 40401, "用户不存在", nil)
			return
		}
		value, e := randomFactorText(20)
		if e != nil {
			fail()
			return
		}
		encrypted, iv, tag, e := codec.SealTwoFactorSecret(value)
		if e != nil {
			fail()
			return
		}
		mutation.New = FactorSecret{Encrypted: encrypted, IV: iv, Tag: tag}
		account := profile.Email
		if account == "" {
			account = profile.Username
		}
		label := strings.ReplaceAll(url.QueryEscape("NekoTribe:"+account), "+", "%20")
		data = map[string]interface{}{"secret": value, "otpauth_url": "otpauth://totp/" + label + "?secret=" + value + "&issuer=NekoTribe&algorithm=SHA1&digits=6&period=30"}
	} else {
		if !found || (action == "disable" && !secret.Enabled) {
			message := "请先生成双因素认证密钥"
			if action == "disable" {
				message = "双因素认证尚未启用"
			}
			respond(w, 422, 42201, message, nil)
			return
		}
		if action == "confirm" && secret.Enabled {
			respond(w, 422, 42201, "双因素认证已启用，请先关闭后再重新设置", nil)
			return
		}
		plain, e := codec.OpenTwoFactorSecret(secret.Encrypted, secret.IV, secret.Tag)
		if e != nil {
			fail()
			return
		}
		matched, e := verifyTOTP(plain, code, config.clock())
		if e != nil {
			respond(w, 400, 40001, "双因素密钥格式错误", nil)
			return
		}
		if action == "disable" && !matched && !isSixDigits(code) {
			codes, e := store.FindRecoveryCodes(r.Context(), user)
			if e != nil {
				fail()
				return
			}
			for _, candidate := range codes {
				if matchesLoginPassword(candidate.Hash, code) {
					mutation.RecoveryID = candidate.ID
					mutation.UsesRecoveryCode = true
					matched = true
					break
				}
			}
		}
		if !matched {
			respond(w, 401, 40101, "双因素验证码错误", nil)
			return
		}
		if action == "confirm" {
			codes := make([]string, 10)
			for i := range codes {
				raw, e := randomFactorText(10)
				if e != nil {
					fail()
					return
				}
				codes[i] = fmt.Sprintf("%s-%s-%s", raw[:5], raw[5:10], raw[10:15])
				hash, e := bcrypt.GenerateFromPassword([]byte(normalizeFactorCode(codes[i])), 10)
				if e != nil {
					fail()
					return
				}
				mutation.RecoveryHashes = append(mutation.RecoveryHashes, string(hash))
			}
			data = map[string]interface{}{"enabled": true, "recovery_codes": codes}
		} else {
			data = map[string]interface{}{"enabled": false}
		}
	}
	outcome, e := store.ApplyFactorMutation(r.Context(), user, mutation)
	if e != nil {
		fail()
		return
	}
	if outcome == factorChanged {
		respond(w, 409, 40901, "双因素设置已变更，请重试", nil)
		return
	}
	if outcome == factorRecoveryUsed {
		respond(w, 401, 40101, "双因素验证码错误", nil)
		return
	}
	if outcome != factorApplied {
		fail()
		return
	}
	respond(w, 200, 200, "success", data)
}
