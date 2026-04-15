package graphql

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

type Client struct {
	Endpoint    string
	AppPassword string
	HTTPClient  *http.Client
}

type request struct {
	Query     string         `json:"query"`
	Variables map[string]any `json:"variables,omitempty"`
}

type response struct {
	Data   json.RawMessage `json:"data"`
	Errors []gqlError      `json:"errors"`
}

type gqlError struct {
	Message string `json:"message"`
}

type ErrorList []gqlError

func (e ErrorList) Error() string {
	msgs := make([]string, 0, len(e))
	for _, err := range e {
		msgs = append(msgs, err.Message)
	}
	return fmt.Sprintf("GraphQL errors: %v", msgs)
}

// Query は指定されたクエリをPOSTし、`data` フィールドを out にunmarshalする。
func (c *Client) Query(ctx context.Context, query string, variables map[string]any, out any) error {
	body, err := json.Marshal(request{Query: query, Variables: variables})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.AppPassword != "" {
		req.Header.Set("Authorization", "Bearer "+c.AppPassword)
	}

	httpClient := c.HTTPClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("graphql: unexpected status %d: %s", resp.StatusCode, string(raw))
	}

	var r response
	if err := json.Unmarshal(raw, &r); err != nil {
		return fmt.Errorf("graphql: invalid response: %w", err)
	}
	if len(r.Errors) > 0 {
		return ErrorList(r.Errors)
	}
	if out != nil {
		return json.Unmarshal(r.Data, out)
	}
	return nil
}
