package config

import (
	"os"
	"path/filepath"
	"testing"
)

func setupTempConfigDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(ProfileEnvVar, "")
	return dir
}

func writeRawConfig(t *testing.T, content string) {
	t.Helper()
	path, err := Path()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestLoad_NoFile(t *testing.T) {
	setupTempConfigDir(t)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Profiles) != 0 {
		t.Errorf("expected empty profiles, got %v", cfg.Profiles)
	}
}

func TestLoad_MigratesLegacyFormat(t *testing.T) {
	setupTempConfigDir(t)
	writeRawConfig(t, `{"endpoint":"https://example.com/graphql","app_password":"rururu_test"}`)

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Default != DefaultProfileName {
		t.Errorf("expected default=%q, got %q", DefaultProfileName, cfg.Default)
	}
	p, ok := cfg.Profiles[DefaultProfileName]
	if !ok {
		t.Fatalf("expected profile %q, profiles=%v", DefaultProfileName, cfg.Profiles)
	}
	if p.Endpoint != "https://example.com/graphql" || p.AppPassword != "rururu_test" {
		t.Errorf("migrated values mismatch: %+v", p)
	}
}

func TestSaveAndLoad_RoundTrip(t *testing.T) {
	setupTempConfigDir(t)
	cfg := &Config{
		Default: "prod",
		Profiles: map[string]Profile{
			"local": {Endpoint: "https://fh.lvh.me/graphql", AppPassword: "rururu_local"},
			"prod":  {Endpoint: "https://feedhub.example.com/graphql", AppPassword: "rururu_prod"},
		},
	}
	if err := Save(cfg); err != nil {
		t.Fatal(err)
	}
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.Default != "prod" {
		t.Errorf("default mismatch: %q", got.Default)
	}
	if got.Profiles["local"].AppPassword != "rururu_local" {
		t.Errorf("local profile mismatch: %+v", got.Profiles["local"])
	}
	if got.Profiles["prod"].Endpoint != "https://feedhub.example.com/graphql" {
		t.Errorf("prod profile mismatch: %+v", got.Profiles["prod"])
	}
}

func TestResolveProfileName_FlagWins(t *testing.T) {
	setupTempConfigDir(t)
	cfg := &Config{
		Default:  "prod",
		Profiles: map[string]Profile{"local": {}, "prod": {}},
	}
	t.Setenv(ProfileEnvVar, "local")
	name, err := cfg.ResolveProfileName("prod")
	if err != nil {
		t.Fatal(err)
	}
	if name != "prod" {
		t.Errorf("flag should win, got %q", name)
	}
}

func TestResolveProfileName_EnvOverDefault(t *testing.T) {
	setupTempConfigDir(t)
	cfg := &Config{
		Default:  "prod",
		Profiles: map[string]Profile{"local": {}, "prod": {}},
	}
	t.Setenv(ProfileEnvVar, "local")
	name, err := cfg.ResolveProfileName("")
	if err != nil {
		t.Fatal(err)
	}
	if name != "local" {
		t.Errorf("env should override default, got %q", name)
	}
}

func TestResolveProfileName_FallsBackToDefault(t *testing.T) {
	setupTempConfigDir(t)
	cfg := &Config{
		Default:  "prod",
		Profiles: map[string]Profile{"local": {}, "prod": {}},
	}
	name, err := cfg.ResolveProfileName("")
	if err != nil {
		t.Fatal(err)
	}
	if name != "prod" {
		t.Errorf("expected default profile, got %q", name)
	}
}

func TestResolveProfileName_SingleProfile(t *testing.T) {
	setupTempConfigDir(t)
	cfg := &Config{
		Profiles: map[string]Profile{"only": {}},
	}
	name, err := cfg.ResolveProfileName("")
	if err != nil {
		t.Fatal(err)
	}
	if name != "only" {
		t.Errorf("expected single profile to be resolved, got %q", name)
	}
}

func TestResolveProfileName_NoProfileError(t *testing.T) {
	setupTempConfigDir(t)
	cfg := &Config{Profiles: map[string]Profile{}}
	if _, err := cfg.ResolveProfileName(""); err == nil {
		t.Error("expected error when no profile configured")
	}
}

func TestCurrentProfile_NotFound(t *testing.T) {
	setupTempConfigDir(t)
	cfg := &Config{
		Profiles: map[string]Profile{"local": {AppPassword: "x"}},
	}
	if _, _, err := cfg.CurrentProfile("nope"); err == nil {
		t.Error("expected error when profile name does not exist")
	}
}
