package main

import (
	"embed"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"strings"

	"github.com/grgalex/xpushare/dashboard/internal/config"
	"github.com/grgalex/xpushare/dashboard/internal/httpapi"
	"github.com/grgalex/xpushare/dashboard/internal/k8s"
	"github.com/grgalex/xpushare/dashboard/internal/prom"
	"github.com/grgalex/xpushare/dashboard/internal/service"
)

//go:embed web/*
var webFS embed.FS

func main() {
	configPath := flag.String("config", "", "dashboard config file path (yaml)")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("load config failed: %v", err)
	}

	k8sClient, err := k8s.New(cfg.Kubernetes)
	if err != nil {
		log.Fatalf("init kubernetes client failed: %v", err)
	}

	promClient := prom.New(cfg.Prometheus)
	svc := service.New(k8sClient, promClient)
	api := httpapi.New(svc)

	mux := http.NewServeMux()
	api.Register(mux)
	registerStatic(mux)

	log.Printf("xpushare dashboard backend listening on %s", cfg.Server.ListenAddr)
	log.Printf("kubernetes mode=%s apiServer=%s", cfg.Kubernetes.Mode, cfg.Kubernetes.APIServer)
	if cfg.Prometheus.BaseURL == "" {
		log.Printf("prometheus integration is disabled (prometheus.baseURL not configured)")
	} else {
		log.Printf("prometheus baseURL=%s", cfg.Prometheus.BaseURL)
	}

	if err := http.ListenAndServe(cfg.Server.ListenAddr, logRequest(mux)); err != nil {
		log.Fatalf("http server failed: %v", err)
	}
}

func registerStatic(mux *http.ServeMux) {
	sub, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("load embedded web files failed: %v", err)
	}
	fileServer := http.FileServer(http.FS(sub))

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		fileServer.ServeHTTP(w, r)
	})
}

func logRequest(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}
