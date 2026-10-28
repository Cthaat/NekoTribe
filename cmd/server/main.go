package main

import (
	"context"
	"errors"
	"fmt"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/Cthaat/NekoTribe/backend-go/internal/server"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	if run() != nil {
		fmt.Fprintln(os.Stderr, "backend startup or shutdown failed")
		os.Exit(1)
	}
}
func run() (err error) {
	config, e := server.LoadConfig(os.LookupEnv)
	if e != nil {
		return e
	}
	redisEvents, e := server.NewRedisNotificationSource(os.LookupEnv)
	if e != nil {
		return e
	}
	defer redisEvents.Close()
	config.Refresh.NotificationEvents = redisEvents
	redisPublisher, e := server.NewConfiguredUserEventPublisher(os.LookupEnv)
	if e != nil {
		return e
	}
	defer redisPublisher.Close()
	config.Refresh.NotificationPublisher = redisPublisher
	codec, e := auth.NewTokenManager([]byte(config.AccessKey), []byte(config.RefreshKey), time.Now)
	if e != nil {
		return errors.New("invalid authentication configuration")
	}
	db, e := server.OpenOracle(config)
	if e != nil {
		return e
	}
	defer func() {
		if server.CloseOracle(db) != nil {
			err = errors.New("database shutdown failed")
		}
	}()
	preflight, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	e = (server.OracleSessions{DB: db}).Preflight(preflight)
	cancel()
	if e != nil {
		return e
	}
	listener, e := net.Listen("tcp", net.JoinHostPort(config.Host, strconv.Itoa(config.Port)))
	if e != nil {
		return errors.New("listener unavailable")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	handler := server.NewHandlerWithConfig(codec, server.OracleSessions{DB: db}, config.Cors, config.Refresh)
	fmt.Println("nekotribe go native session service listening")
	return server.Serve(ctx, server.NewHTTPServer(listener.Addr().String(), handler), listener)
}
