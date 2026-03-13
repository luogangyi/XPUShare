package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	defaultServiceAccountTokenFile = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	defaultServiceAccountCAFile    = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
)

type Config struct {
	Server     ServerConfig     `yaml:"server"`
	Kubernetes KubernetesConfig `yaml:"kubernetes"`
	Prometheus PrometheusConfig `yaml:"prometheus"`
}

type ServerConfig struct {
	ListenAddr string `yaml:"listenAddr"`
}

type KubernetesConfig struct {
	Mode                  string `yaml:"mode"`
	APIServer             string `yaml:"apiServer"`
	Token                 string `yaml:"token"`
	TokenFile             string `yaml:"tokenFile"`
	CAFile                string `yaml:"caFile"`
	InsecureSkipTLSVerify bool   `yaml:"insecureSkipTLSVerify"`
}

type PrometheusConfig struct {
	BaseURL    string `yaml:"baseURL"`
	Token      string `yaml:"token"`
	TokenFile  string `yaml:"tokenFile"`
	TimeoutSec int    `yaml:"timeoutSec"`
}

func Default() *Config {
	return &Config{
		Server: ServerConfig{
			ListenAddr: ":8080",
		},
		Kubernetes: KubernetesConfig{
			Mode:      "auto",
			TokenFile: defaultServiceAccountTokenFile,
			CAFile:    defaultServiceAccountCAFile,
		},
		Prometheus: PrometheusConfig{
			TimeoutSec: 10,
		},
	}
}

func Load(path string) (*Config, error) {
	cfg := Default()

	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				return nil, fmt.Errorf("read config file %q: %w", path, err)
			}
		} else {
			if err := yaml.Unmarshal(data, cfg); err != nil {
				return nil, fmt.Errorf("parse config file %q: %w", path, err)
			}
		}
	}

	applyEnvOverrides(cfg)

	if err := cfg.resolveKubernetes(); err != nil {
		return nil, err
	}
	if err := cfg.resolvePrometheus(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(cfg.Server.ListenAddr) == "" {
		cfg.Server.ListenAddr = ":8080"
	}

	return cfg, nil
}

func applyEnvOverrides(cfg *Config) {
	applyString(&cfg.Server.ListenAddr, "DASHBOARD_LISTEN_ADDR")

	applyString(&cfg.Kubernetes.Mode, "DASHBOARD_K8S_MODE")
	applyString(&cfg.Kubernetes.APIServer, "DASHBOARD_K8S_API_SERVER")
	applyString(&cfg.Kubernetes.Token, "DASHBOARD_K8S_TOKEN")
	applyString(&cfg.Kubernetes.TokenFile, "DASHBOARD_K8S_TOKEN_FILE")
	applyString(&cfg.Kubernetes.CAFile, "DASHBOARD_K8S_CA_FILE")
	applyBool(&cfg.Kubernetes.InsecureSkipTLSVerify, "DASHBOARD_K8S_INSECURE_SKIP_TLS_VERIFY")

	applyString(&cfg.Prometheus.BaseURL, "DASHBOARD_PROM_BASE_URL")
	applyString(&cfg.Prometheus.Token, "DASHBOARD_PROM_TOKEN")
	applyString(&cfg.Prometheus.TokenFile, "DASHBOARD_PROM_TOKEN_FILE")
	applyInt(&cfg.Prometheus.TimeoutSec, "DASHBOARD_PROM_TIMEOUT_SEC")
}

func applyString(target *string, envKey string) {
	if value := strings.TrimSpace(os.Getenv(envKey)); value != "" {
		*target = value
	}
}

func applyBool(target *bool, envKey string) {
	value := strings.TrimSpace(strings.ToLower(os.Getenv(envKey)))
	if value == "" {
		return
	}
	switch value {
	case "1", "true", "yes", "y", "on":
		*target = true
	case "0", "false", "no", "n", "off":
		*target = false
	}
}

func applyInt(target *int, envKey string) {
	value := strings.TrimSpace(os.Getenv(envKey))
	if value == "" {
		return
	}
	if parsed, err := strconv.Atoi(value); err == nil {
		*target = parsed
	}
}

func (c *Config) resolveKubernetes() error {
	k := &c.Kubernetes
	k.Mode = strings.ToLower(strings.TrimSpace(k.Mode))
	if k.Mode == "" {
		k.Mode = "auto"
	}

	if k.Mode == "auto" {
		hasExternal := strings.TrimSpace(k.APIServer) != "" &&
			(strings.TrimSpace(k.Token) != "" || strings.TrimSpace(k.TokenFile) != "")
		if hasExternal {
			k.Mode = "external"
		} else {
			k.Mode = "incluster"
		}
	}

	switch k.Mode {
	case "incluster":
		if strings.TrimSpace(k.APIServer) == "" {
			host := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_HOST"))
			port := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_PORT"))
			if host == "" {
				host = "kubernetes.default.svc"
			}
			if port == "" {
				port = "443"
			}
			k.APIServer = fmt.Sprintf("https://%s:%s", host, port)
		}
		if strings.TrimSpace(k.TokenFile) == "" {
			k.TokenFile = defaultServiceAccountTokenFile
		}
		if strings.TrimSpace(k.CAFile) == "" {
			k.CAFile = defaultServiceAccountCAFile
		}
	case "external":
		if strings.TrimSpace(k.APIServer) == "" {
			return errors.New("kubernetes.apiServer is required in external mode")
		}
	default:
		return fmt.Errorf("unsupported kubernetes.mode: %s", k.Mode)
	}

	k.APIServer = normalizeBaseURL(k.APIServer)
	if k.APIServer == "" {
		return errors.New("kubernetes.apiServer is empty after normalization")
	}

	if strings.TrimSpace(k.Token) == "" && strings.TrimSpace(k.TokenFile) != "" {
		token, err := readTrimmedFile(k.TokenFile)
		if err != nil {
			if k.Mode == "incluster" {
				return fmt.Errorf("read service account token %q: %w", k.TokenFile, err)
			}
			return fmt.Errorf("read kubernetes token file %q: %w", k.TokenFile, err)
		}
		k.Token = token
	}

	if strings.TrimSpace(k.Token) == "" {
		return errors.New("kubernetes token is empty")
	}

	if k.CAFile != "" {
		k.CAFile = filepath.Clean(k.CAFile)
	}
	return nil
}

func (c *Config) resolvePrometheus() error {
	p := &c.Prometheus
	p.BaseURL = normalizeBaseURL(p.BaseURL)

	if strings.TrimSpace(p.Token) == "" && strings.TrimSpace(p.TokenFile) != "" {
		token, err := readTrimmedFile(p.TokenFile)
		if err != nil {
			return fmt.Errorf("read prometheus token file %q: %w", p.TokenFile, err)
		}
		p.Token = token
	}

	if p.TimeoutSec <= 0 {
		p.TimeoutSec = 10
	}

	return nil
}

func readTrimmedFile(path string) (string, error) {
	data, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func normalizeBaseURL(raw string) string {
	trimmed := strings.TrimSpace(raw)
	trimmed = strings.TrimRight(trimmed, "/")
	return trimmed
}
