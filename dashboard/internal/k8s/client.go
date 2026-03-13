package k8s

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"time"

	"github.com/grgalex/xpushare/dashboard/internal/config"
)

const (
	ResourceXPUShareGPU = "xpushare.com/gpu"
)

type Client struct {
	baseURL    string
	token      string
	httpClient *http.Client
}

type ObjectMeta struct {
	Name        string            `json:"name"`
	Namespace   string            `json:"namespace"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
}

type Node struct {
	Metadata ObjectMeta `json:"metadata"`
	Status   NodeStatus `json:"status"`
}

type NodeStatus struct {
	Capacity    map[string]string `json:"capacity"`
	Allocatable map[string]string `json:"allocatable"`
}

type NodeList struct {
	Items []Node `json:"items"`
}

type Pod struct {
	Metadata ObjectMeta `json:"metadata"`
	Spec     PodSpec    `json:"spec"`
	Status   PodStatus  `json:"status"`
}

type PodSpec struct {
	NodeName   string         `json:"nodeName"`
	Containers []PodContainer `json:"containers"`
}

type PodStatus struct {
	Phase string `json:"phase"`
}

type PodContainer struct {
	Name      string               `json:"name"`
	Resources ResourceRequirements `json:"resources"`
}

type ResourceRequirements struct {
	Limits   map[string]string `json:"limits"`
	Requests map[string]string `json:"requests"`
}

type PodList struct {
	Items []Pod `json:"items"`
}

func New(cfg config.KubernetesConfig) (*Client, error) {
	tlsConfig := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: cfg.InsecureSkipTLSVerify,
	}

	if !cfg.InsecureSkipTLSVerify && strings.TrimSpace(cfg.CAFile) != "" {
		caData, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read kubernetes CA file %q: %w", cfg.CAFile, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caData) {
			return nil, fmt.Errorf("append kubernetes CA cert failed: %s", cfg.CAFile)
		}
		tlsConfig.RootCAs = pool
	}

	transport := &http.Transport{
		Proxy:               http.ProxyFromEnvironment,
		TLSClientConfig:     tlsConfig,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	}

	return &Client{
		baseURL: strings.TrimRight(cfg.APIServer, "/"),
		token:   cfg.Token,
		httpClient: &http.Client{
			Timeout:   15 * time.Second,
			Transport: transport,
		},
	}, nil
}

func (c *Client) GetNodes(ctx context.Context) ([]Node, error) {
	body, err := c.do(ctx, http.MethodGet, "/api/v1/nodes", nil, nil, "")
	if err != nil {
		return nil, err
	}

	var list NodeList
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("decode node list: %w", err)
	}
	return list.Items, nil
}

func (c *Client) ListPods(ctx context.Context) ([]Pod, error) {
	body, err := c.do(ctx, http.MethodGet, "/api/v1/pods", nil, nil, "")
	if err != nil {
		return nil, err
	}

	var list PodList
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("decode pod list: %w", err)
	}
	return list.Items, nil
}

func (c *Client) PatchPodAnnotations(ctx context.Context, namespace, podName string, annotations map[string]interface{}) error {
	if len(annotations) == 0 {
		return fmt.Errorf("annotations payload is empty")
	}

	patch := map[string]interface{}{
		"metadata": map[string]interface{}{
			"annotations": annotations,
		},
	}
	data, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("marshal patch payload: %w", err)
	}

	endpoint := path.Join("/api/v1/namespaces", url.PathEscape(namespace), "pods", url.PathEscape(podName))
	_, err = c.do(ctx, http.MethodPatch, endpoint, nil, data, "application/merge-patch+json")
	if err != nil {
		return err
	}
	return nil
}

func (c *Client) do(ctx context.Context, method, endpoint string, query url.Values, body []byte, contentType string) ([]byte, error) {
	u, err := url.Parse(c.baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid kubernetes base url %q: %w", c.baseURL, err)
	}
	u.Path = strings.TrimRight(u.Path, "/") + endpoint
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}

	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return nil, fmt.Errorf("build kubernetes request: %w", err)
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	request.Header.Set("Accept", "application/json")

	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("kubernetes request %s %s: %w", method, u.String(), err)
	}
	defer response.Body.Close()

	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, fmt.Errorf("read kubernetes response: %w", err)
	}

	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		trimmed := strings.TrimSpace(string(responseBody))
		if len(trimmed) > 512 {
			trimmed = trimmed[:512]
		}
		return nil, fmt.Errorf("kubernetes API %s %s returned %d: %s", method, endpoint, response.StatusCode, trimmed)
	}
	return responseBody, nil
}
