package server

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"html"
	"mime"
	"mime/multipart"
	"net"
	"net/mail"
	"net/smtp"
	"net/textproto"
	"strconv"
	"strings"
	"time"
)

var errMailDelivery = errors.New("mail delivery failed")

type smtpLoginAuth struct {
	user, password, host string
	step                 int
}

func (smtpLoginAuth) String() string   { return "SMTPLoginAuth [redacted]" }
func (smtpLoginAuth) GoString() string { return "SMTPLoginAuth [redacted]" }

func (a *smtpLoginAuth) Start(server *smtp.ServerInfo) (string, []byte, error) {
	if !server.TLS || server.Name != a.host {
		return "", nil, errMailDelivery
	}
	return "LOGIN", nil, nil
}
func (a *smtpLoginAuth) Next(_ []byte, more bool) ([]byte, error) {
	if !more {
		return nil, nil
	}
	a.step++
	switch a.step {
	case 1:
		return []byte(a.user), nil
	case 2:
		return []byte(a.password), nil
	default:
		return nil, errMailDelivery
	}
}

type smtpConfig struct {
	host, port, user, password string
	roots                      *x509.CertPool
}

func (smtpConfig) String() string   { return "SMTPConfig [redacted]" }
func (smtpConfig) GoString() string { return "SMTPConfig [redacted]" }
func smtpFromLookup(lookup func(string) (string, bool)) smtpConfig {
	get := func(key string) string {
		if v, ok := lookup("NUXT_" + key); ok {
			return v
		}
		v, _ := lookup(key)
		return v
	}
	return smtpConfig{host: get("SMTP_HOST"), port: get("SMTP_PORT"), user: get("SMTP_USER"), password: get("SMTP_PASS")}
}
func (s smtpConfig) SendOTP(ctx context.Context, to, code string) error {
	return s.sendMail(ctx, to, "Your verification code", "Your verification code is "+code,
		"<p>Your verification code is <strong>"+code+"</strong></p>")
}

func (s smtpConfig) SendLoginAlert(ctx context.Context, to, message, ip, agent string) error {
	const advice = "如果这不是你本人操作，请尽快修改密码并注销其他设备。"
	text := message + "\r\nIP: " + ip + "\r\nUser-Agent: " + agent + "\r\n" + advice
	body := "<p>" + html.EscapeString(message) + "</p><p><strong>IP:</strong> " +
		html.EscapeString(ip) + "</p><p><strong>User-Agent:</strong> " + html.EscapeString(agent) + "</p><p>" + advice + "</p>"
	return s.sendMail(ctx, to, loginAlertTitle, text, body)
}

func (s smtpConfig) sendMail(ctx context.Context, to, subject, text, htmlBody string) error {
	port, err := strconv.Atoi(s.port)
	if err != nil || port < 1 || port > 65535 || s.host == "" || strings.ContainsAny(s.host, "/\r\n") || s.user == "" || s.password == "" || strings.ContainsAny(s.user+to, "\r\n") {
		return errMailDelivery
	}
	from, err := mail.ParseAddress(s.user)
	if err != nil {
		return errMailDelivery
	}
	recipient, err := mail.ParseAddress(to)
	if err != nil {
		return errMailDelivery
	}
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for _, part := range []struct{ contentType, text string }{{"text/plain; charset=UTF-8", text}, {"text/html; charset=UTF-8", htmlBody}} {
		h := textproto.MIMEHeader{}
		h.Set("Content-Type", part.contentType)
		h.Set("Content-Transfer-Encoding", "8bit")
		w, e := writer.CreatePart(h)
		if e != nil {
			return errMailDelivery
		}
		if _, e = w.Write([]byte(part.text)); e != nil {
			return errMailDelivery
		}
	}
	if writer.Close() != nil {
		return errMailDelivery
	}
	message := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=%q\r\n\r\n", from.String(), recipient.String(), mime.QEncoding.Encode("UTF-8", subject), writer.Boundary()) + body.String()
	dialer := net.Dialer{Timeout: 15 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(s.host, strconv.Itoa(port)))
	if err != nil {
		return errMailDelivery
	}
	defer conn.Close()
	if conn.SetDeadline(time.Now().Add(15*time.Second)) != nil {
		return errMailDelivery
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()
	secure := tls.Client(conn, &tls.Config{ServerName: s.host, RootCAs: s.roots, MinVersion: tls.VersionTLS12})
	if secure.HandshakeContext(ctx) != nil {
		return errMailDelivery
	}
	client, err := smtp.NewClient(secure, s.host)
	if err != nil {
		return errMailDelivery
	}
	defer client.Close()
	available, mechanisms := client.Extension("AUTH")
	if !available {
		return errMailDelivery
	}
	var authentication smtp.Auth
	for _, mechanism := range strings.Fields(mechanisms) {
		if strings.EqualFold(mechanism, "PLAIN") {
			authentication = smtp.PlainAuth("", s.user, s.password, s.host)
			break
		}
	}
	if authentication == nil {
		for _, mechanism := range strings.Fields(mechanisms) {
			if strings.EqualFold(mechanism, "LOGIN") {
				authentication = &smtpLoginAuth{user: s.user, password: s.password, host: s.host}
				break
			}
		}
	}
	if authentication == nil || client.Auth(authentication) != nil || client.Mail(from.Address) != nil || client.Rcpt(recipient.Address) != nil {
		return errMailDelivery
	}
	data, err := client.Data()
	if err != nil {
		return errMailDelivery
	}
	if _, err = data.Write([]byte(message)); err != nil {
		_ = data.Close()
		return errMailDelivery
	}
	if data.Close() != nil {
		return errMailDelivery
	}
	if client.Quit() != nil {
		return errMailDelivery
	}
	return nil
}
