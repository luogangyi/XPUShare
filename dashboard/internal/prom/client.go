package prom

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/grgalex/xpushare/dashboard/internal/config"
)

type Client struct {
	baseURL    string
	token      string
	httpClient *http.Client
}

type Sample struct {
	Metric    map[string]string `json:"metric"`
	Value     float64           `json:"value"`
	Timestamp float64           `json:"timestamp"`
}

type queryResponse struct {
	Status    string `json:"status"`
	ErrorType string `json:"errorType"`
	Error     string `json:"error"`
	Data      struct {
		ResultType string          `json:"resultType"`
		Result     json.RawMessage `json:"result"`
	} `json:"data"`
}

func New(cfg config.PrometheusConfig) *Client {
	timeout := time.Duration(cfg.TimeoutSec) * time.Second
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	return &Client{
		baseURL: strings.TrimRight(cfg.BaseURL, "/"),
		token:   cfg.Token,
		httpClient: &http.Client{
			Timeout: timeout,
		},
	}
}

func (c *Client) Enabled() bool {
	return strings.TrimSpace(c.baseURL) != ""
}

func (c *Client) Query(ctx context.Context, promQL string) ([]Sample, error) {
	if !c.Enabled() {
		return nil, fmt.Errorf("prometheus base URL is not configured")
	}

	u, err := url.Parse(c.baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid prometheus base URL %q: %w", c.baseURL, err)
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/api/v1/query"
	q := u.Query()
	q.Set("query", promQL)
	u.RawQuery = q.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("build prometheus request: %w", err)
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}

	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("prometheus query failed: %w", err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, fmt.Errorf("read prometheus response: %w", err)
	}

	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("prometheus API returned %d: %s", response.StatusCode, strings.TrimSpace(string(body)))
	}

	var parsed queryResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("decode prometheus response: %w", err)
	}
	if parsed.Status != "success" {
		return nil, fmt.Errorf("prometheus error: %s (%s)", parsed.Error, parsed.ErrorType)
	}

	switch parsed.Data.ResultType {
	case "vector":
		return parseVector(parsed.Data.Result)
	case "scalar":
		return parseScalar(parsed.Data.Result)
	default:
		return nil, fmt.Errorf("unsupported prometheus resultType: %s", parsed.Data.ResultType)
	}
}

func (c *Client) QuerySum(ctx context.Context, promQL string) (float64, error) {
	samples, err := c.Query(ctx, promQL)
	if err != nil {
		return 0, err
	}
	total := 0.0
	for _, sample := range samples {
		total += sample.Value
	}
	return total, nil
}

func parseVector(raw json.RawMessage) ([]Sample, error) {
	type vectorValue struct {
		Metric map[string]string `json:"metric"`
		Value  []interface{}     `json:"value"`
	}

	var values []vectorValue
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, fmt.Errorf("decode vector result: %w", err)
	}

	result := make([]Sample, 0, len(values))
	for _, value := range values {
		timestamp, metricValue, err := parsePromValue(value.Value)
		if err != nil {
			return nil, err
		}
		result = append(result, Sample{
			Metric:    value.Metric,
			Timestamp: timestamp,
			Value:     metricValue,
		})
	}

	return result, nil
}

func parseScalar(raw json.RawMessage) ([]Sample, error) {
	var pair []interface{}
	if err := json.Unmarshal(raw, &pair); err != nil {
		return nil, fmt.Errorf("decode scalar result: %w", err)
	}
	timestamp, metricValue, err := parsePromValue(pair)
	if err != nil {
		return nil, err
	}
	return []Sample{{Timestamp: timestamp, Value: metricValue}}, nil
}

func parsePromValue(pair []interface{}) (float64, float64, error) {
	if len(pair) != 2 {
		return 0, 0, fmt.Errorf("unexpected prometheus value tuple length: %d", len(pair))
	}

	timestamp, err := parseFloat(pair[0])
	if err != nil {
		return 0, 0, fmt.Errorf("parse prometheus timestamp: %w", err)
	}
	value, err := parseFloat(pair[1])
	if err != nil {
		return 0, 0, fmt.Errorf("parse prometheus metric value: %w", err)
	}

	return timestamp, value, nil
}

func parseFloat(value interface{}) (float64, error) {
	switch v := value.(type) {
	case float64:
		return v, nil
	case string:
		parsed, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return 0, err
		}
		return parsed, nil
	default:
		return 0, fmt.Errorf("unsupported type %T", value)
	}
}
