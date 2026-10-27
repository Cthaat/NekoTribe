package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"github.com/oracle/go-oracledb/v26/oracle"
	"net"
	"net/http"
	"time"
)

func NewHTTPServer(address string, handler http.Handler) *http.Server {
	return &http.Server{Addr: address, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20}
}
func Serve(ctx context.Context, srv *http.Server, listener net.Listener) error {
	stopped := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(stopped)
		select {
		case <-ctx.Done():
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if srv.Shutdown(shutdownCtx) != nil {
				_ = srv.Close()
			}
		case <-finished:
		}
	}()
	err := srv.Serve(listener)
	close(finished)
	<-stopped
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return errors.New("HTTP server stopped unexpectedly")
}
func OpenOracle(c Config) (*sql.DB, error) {
	config := oracle.NewOracleDriverConfig()
	config.ConnectDescriptor = fmt.Sprintf("%s:%d/%s", c.OracleHost, c.OraclePort, c.OracleService)
	config.Credentials.User = c.OracleUser
	config.Credentials.Password = c.OraclePassword
	connector, e := oracle.NewOracleConnector(config)
	if e != nil {
		return nil, errSessionStore
	}
	db := sql.OpenDB(connector)
	db.SetMaxOpenConns(c.PoolMax)
	db.SetMaxIdleConns(c.PoolMin)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)
	return db, nil
}
func CloseOracle(db *sql.DB) error {
	if db.Close() != nil {
		return errSessionStore
	}
	return nil
}
