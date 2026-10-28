package server

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRedisNotificationSourceSubscribesAndCloses(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	stopServer := make(chan struct{})
	defer close(stopServer)
	serverDone := make(chan error, 1)
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			serverDone <- e
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
		reader := bufio.NewReader(conn)
		for {
			header, e := reader.ReadString('\n')
			if e != nil {
				serverDone <- e
				return
			}
			if !strings.HasPrefix(header, "*") {
				serverDone <- errors.New("invalid array")
				return
			}
			count, e := strconv.Atoi(strings.TrimSpace(header[1:]))
			if e != nil || count < 1 || count > 32 {
				serverDone <- errors.New("invalid count")
				return
			}
			args := make([]string, count)
			for i := range args {
				line, e := reader.ReadString('\n')
				if e != nil || !strings.HasPrefix(line, "$") {
					serverDone <- errors.New("invalid bulk")
					return
				}
				n, e := strconv.Atoi(strings.TrimSpace(line[1:]))
				if e != nil || n < 0 || n > 100000 {
					serverDone <- errors.New("invalid length")
					return
				}
				body := make([]byte, n+2)
				if _, e = io.ReadFull(reader, body); e != nil {
					serverDone <- e
					return
				}
				args[i] = string(body[:n])
			}
			switch strings.ToUpper(args[0]) {
			case "HELLO":
				_, e = io.WriteString(conn, "-ERR unknown command 'HELLO'\r\n")
			case "SUBSCRIBE":
				if len(args) != 2 || args[1] != "ws:user:42" {
					serverDone <- errors.New("wrong channel")
					return
				}
				channel := args[1]
				body := `{"type":"notification_deleted","data":{},"timestamp":1}`
				_, e = fmt.Fprintf(conn, "*3\r\n$9\r\nsubscribe\r\n$%d\r\n%s\r\n:1\r\n*3\r\n$7\r\nmessage\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", len(channel), channel, len(channel), channel, len(body), body)
				if e != nil {
					serverDone <- e
					return
				}
				<-stopServer
				serverDone <- nil
				return
			default:
				_, e = io.WriteString(conn, "+OK\r\n")
			}
			if e != nil {
				serverDone <- e
				return
			}
		}
	}()
	lookup := func(k string) (string, bool) {
		if k == "REDIS_URL" {
			return "redis://" + listener.Addr().String() + "/0", true
		}
		return "", false
	}
	source, err := NewRedisNotificationSource(lookup)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	events, stop, err := source.Subscribe(ctx, 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	select {
	case message, ok := <-events:
		if !ok || !strings.Contains(string(message), "notification_deleted") {
			t.Fatal("missing event")
		}
	case <-ctx.Done():
		t.Fatal("subscription timeout")
	}
	if err = source.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case _, ok := <-events:
		if ok {
			t.Fatal("source remained open")
		}
	case <-ctx.Done():
		t.Fatal("source did not close")
	}
}
