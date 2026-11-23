package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/Cthaat/NekoTribe/backend-go/internal/server"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--check-config" {
		if len(os.Args) != 2 {
			fmt.Fprintln(os.Stderr, "usage: nekotribe-go --check-config")
			os.Exit(2)
		}
		config, err := server.LoadConfig(os.LookupEnv)
		if err == nil {
			err = checkConfig(config)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("go backend configuration valid (offline)")
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "skills" {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		result, err := server.RunSkillMaintenance(ctx, os.Args[2:], os.LookupEnv)
		cancel()
		if err == nil {
			err = json.NewEncoder(os.Stdout).Encode(result)
			if err != nil {
				err = errors.New("SKILL_CONFIG_OPERATION_FAILED")
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if run() != nil {
		fmt.Fprintln(os.Stderr, "backend startup or shutdown failed")
		os.Exit(1)
	}
}

func checkConfig(config server.Config) error {
	if _, err := newTokenManager(config); err != nil {
		return err
	}
	source, err := server.NewRedisNotificationSource(os.LookupEnv)
	if err != nil {
		return errors.New("invalid Redis configuration")
	}
	if source.Close() != nil {
		return errors.New("Redis configuration check failed")
	}
	return nil
}

func newTokenManager(config server.Config) (*auth.TokenManager, error) {
	manager, err := auth.NewTokenManager([]byte(config.AccessKey), []byte(config.RefreshKey), time.Now)
	if err != nil {
		return nil, errors.New("invalid authentication configuration")
	}
	return manager, nil
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
	redisPublisher, e := server.NewConfiguredUserEventPublisher(os.LookupEnv)
	if e != nil {
		return e
	}
	defer redisPublisher.Close()
	otpLimiter, e := server.NewRedisOTPSendLimiter(os.LookupEnv)
	if e != nil {
		return e
	}
	defer otpLimiter.Close()
	config.Refresh.OTPSendLimiter = otpLimiter
	config.Refresh.OTPAttemptLimiter = otpLimiter
	aiQuota, e := server.NewRedisAIModelQuota(os.LookupEnv)
	if e != nil {
		return e
	}
	defer aiQuota.Close()
	config.Refresh.AIModelQuotaLimiter = aiQuota
	localPresence, e := server.NewLocalPresenceEvents(redisEvents, redisPublisher)
	if e != nil {
		return e
	}
	defer localPresence.Close()
	config.Refresh.NotificationEvents = localPresence
	config.Refresh.ChatChannelEvents = redisEvents
	config.Refresh.DirectEvents = localPresence
	config.Refresh.NotificationPublisher = redisPublisher
	config.Refresh.PresencePublisher = localPresence
	codec, e := newTokenManager(config)
	if e != nil {
		return e
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
	repo := server.OracleSessions{DB: db}
	sweeperDone := make(chan struct{})
	draftSweeperDone := make(chan struct{})
	go func() {
		defer close(sweeperDone)
		repo.RunBanExpiry(ctx)
	}()
	go func() {
		defer close(draftSweeperDone)
		repo.RunPostDraftSweep(ctx, config.Refresh)
	}()
	defer func() {
		stop()
		<-sweeperDone
		<-draftSweeperDone
	}()
	handler := server.NewHandlerWithConfig(codec, repo, config.Cors, config.Refresh)
	handler = server.WithReadiness(handler, config.Cors, db.PingContext, redisEvents.Ping)
	fmt.Println("nekotribe go native session service listening")
	return server.Serve(ctx, server.NewHTTPServer(listener.Addr().String(), handler), listener)
}
