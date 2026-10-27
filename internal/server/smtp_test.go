package server

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"
)

func localSMTP(t *testing.T, auth string) (string, *x509.CertPool, <-chan string, func()) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"}, DNSNames: []string{"localhost"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan string, 1)
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			result <- "accept failure"
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		reader := bufio.NewReader(conn)
		fmt.Fprint(conn, "220 localhost test\r\n")
		var transcript strings.Builder
		inData := false
		loginStep := 0
		for {
			line, e := reader.ReadString('\n')
			if e != nil {
				result <- transcript.String()
				return
			}
			transcript.WriteString(line)
			if loginStep == 1 {
				loginStep = 2
				fmt.Fprint(conn, "334 UGFzc3dvcmQ6\r\n")
				continue
			}
			if loginStep == 2 {
				loginStep = 0
				fmt.Fprint(conn, "235 authenticated\r\n")
				continue
			}
			if inData {
				if line == ".\r\n" {
					inData = false
					fmt.Fprint(conn, "250 queued\r\n")
				}
				continue
			}
			switch {
			case strings.HasPrefix(line, "EHLO "):
				fmt.Fprintf(conn, "250-localhost\r\n250 AUTH %s\r\n", auth)
			case strings.HasPrefix(line, "AUTH PLAIN "):
				if auth == "PLAIN" {
					fmt.Fprint(conn, "235 authenticated\r\n")
				} else {
					fmt.Fprint(conn, "504 unsupported\r\n")
				}
			case strings.HasPrefix(line, "AUTH LOGIN"):
				loginStep = 1
				fmt.Fprint(conn, "334 VXNlcm5hbWU6\r\n")
			case strings.HasPrefix(line, "MAIL FROM:"):
				fmt.Fprint(conn, "250 ok\r\n")
			case strings.HasPrefix(line, "RCPT TO:"):
				fmt.Fprint(conn, "250 ok\r\n")
			case strings.HasPrefix(line, "DATA"):
				inData = true
				fmt.Fprint(conn, "354 send data\r\n")
			case strings.HasPrefix(line, "QUIT"):
				fmt.Fprint(conn, "221 bye\r\n")
				result <- transcript.String()
				return
			default:
				fmt.Fprint(conn, "500 unsupported\r\n")
			}
		}
	}()
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	return port, roots, result, func() { _ = listener.Close() }
}
func TestSMTPImplicitTLSAndDelivery(t *testing.T) {
	port, roots, result, closeServer := localSMTP(t, "PLAIN")
	defer closeServer()
	config := smtpConfig{host: "localhost", port: port, user: "sender@example.test", password: "fake-password", roots: roots}
	if strings.Contains(fmt.Sprintf("%+v %#v", config, config), "fake-password") {
		t.Fatal("SMTP configuration leaked password")
	}
	if err := config.SendOTP(context.Background(), "recipient@example.test", "123456"); err != nil {
		t.Fatal(err)
	}
	select {
	case transcript := <-result:
		if !strings.Contains(transcript, "RCPT TO:<recipient@example.test>") || !strings.Contains(transcript, "Your verification code is 123456") {
			t.Fatal("message was not delivered to the isolated server")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("local SMTP did not finish")
	}
}
func TestSMTPRejectsUntrustedCertificate(t *testing.T) {
	port, _, result, closeServer := localSMTP(t, "PLAIN")
	defer closeServer()
	config := smtpConfig{host: "localhost", port: port, user: "sender@example.test", password: "fake-password"}
	if err := config.SendOTP(context.Background(), "recipient@example.test", "123456"); err == nil || strings.Contains(err.Error(), "fake-password") {
		t.Fatal("untrusted SMTP certificate accepted or secret leaked")
	}
	select {
	case <-result:
	case <-time.After(10 * time.Second):
		t.Fatal("local SMTP did not finish")
	}
}
func TestSMTPLoginAuthentication(t *testing.T) {
	port, roots, result, closeServer := localSMTP(t, "LOGIN")
	defer closeServer()
	config := smtpConfig{host: "localhost", port: port, user: "sender@example.test", password: "fake-password", roots: roots}
	if err := config.SendOTP(context.Background(), "recipient@example.test", "123456"); err != nil {
		t.Fatal(err)
	}
	select {
	case transcript := <-result:
		if !strings.Contains(transcript, "AUTH LOGIN") || !strings.Contains(transcript, "RCPT TO:<recipient@example.test>") {
			t.Fatal("LOGIN delivery failed")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("local SMTP did not finish")
	}
}
func TestSMTPConfigPrefersNuxtVariables(t *testing.T) {
	values := map[string]string{"SMTP_HOST": "old.test", "NUXT_SMTP_HOST": "new.test", "SMTP_PASS": "fake-password"}
	config := smtpFromLookup(func(k string) (string, bool) { v, ok := values[k]; return v, ok })
	if config.host != "new.test" || config.password != "fake-password" {
		t.Fatal("configuration precedence mismatch")
	}
}
