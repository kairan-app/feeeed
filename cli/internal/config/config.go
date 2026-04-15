package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	DefaultEndpoint    = "https://fh.lvh.me/graphql"
	DefaultProfileName = "default"
	ProfileEnvVar      = "RURURU_PROFILE"
	filePerm           = 0o600
	dirPerm            = 0o700
)

type Profile struct {
	Endpoint    string `json:"endpoint"`
	AppPassword string `json:"app_password"`
}

type Config struct {
	Default  string             `json:"default"`
	Profiles map[string]Profile `json:"profiles"`
}

// fileFormat は設定ファイルのJSONを表す。
// 旧フォーマット(top-levelに endpoint/app_password がある形式)もここに吸収して
// LoadFile時にプロファイル形式へマイグレートする。
type fileFormat struct {
	Default  string             `json:"default,omitempty"`
	Profiles map[string]Profile `json:"profiles,omitempty"`

	// 旧フォーマット用フィールド
	Endpoint    string `json:"endpoint,omitempty"`
	AppPassword string `json:"app_password,omitempty"`
}

// configDir は XDG Base Directory Spec に従い、設定ファイルのベースディレクトリを返す。
// $XDG_CONFIG_HOME が設定されていればそれを、無ければ $HOME/.config を使う。
func configDir() (string, error) {
	if dir := os.Getenv("XDG_CONFIG_HOME"); dir != "" {
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config"), nil
}

func Path() (string, error) {
	dir, err := configDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "rururu", "config.json"), nil
}

// Load は設定ファイルを読み込む。ファイルが存在しない場合は空のConfigを返す。
// 旧フォーマット(プロファイルなし)を発見した場合はDefaultProfileNameに移行して返す。
func Load() (*Config, error) {
	path, err := Path()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return &Config{Profiles: map[string]Profile{}}, nil
		}
		return nil, err
	}

	var raw fileFormat
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}

	cfg := &Config{
		Default:  raw.Default,
		Profiles: raw.Profiles,
	}
	if cfg.Profiles == nil {
		cfg.Profiles = map[string]Profile{}
	}

	// 旧フォーマット → 新フォーマットへのマイグレーション
	if len(cfg.Profiles) == 0 && (raw.Endpoint != "" || raw.AppPassword != "") {
		cfg.Profiles[DefaultProfileName] = Profile{
			Endpoint:    raw.Endpoint,
			AppPassword: raw.AppPassword,
		}
		cfg.Default = DefaultProfileName
	}

	return cfg, nil
}

func Save(c *Config) error {
	path, err := Path()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), dirPerm); err != nil {
		return err
	}
	out := fileFormat{
		Default:  c.Default,
		Profiles: c.Profiles,
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, filePerm)
}

// ResolveProfileName は --profile フラグ・環境変数・設定ファイルのDefaultから
// 使うべきプロファイル名を決める。プロファイルが1つだけならそれを採用する。
func (c *Config) ResolveProfileName(flagValue string) (string, error) {
	if flagValue != "" {
		return flagValue, nil
	}
	if env := os.Getenv(ProfileEnvVar); env != "" {
		return env, nil
	}
	if c.Default != "" {
		return c.Default, nil
	}
	if len(c.Profiles) == 1 {
		for name := range c.Profiles {
			return name, nil
		}
	}
	if len(c.Profiles) == 0 {
		return "", fmt.Errorf("no profile configured. Run 'rururu auth login' first")
	}
	return "", fmt.Errorf("no profile selected. Use --profile or set %s. Available: %s",
		ProfileEnvVar, strings.Join(c.SortedProfileNames(), ", "))
}

// CurrentProfile は ResolveProfileName で決まった名前のProfileを返す。
// 見つからない場合はエラー。
func (c *Config) CurrentProfile(flagValue string) (string, *Profile, error) {
	name, err := c.ResolveProfileName(flagValue)
	if err != nil {
		return "", nil, err
	}
	p, ok := c.Profiles[name]
	if !ok {
		return "", nil, fmt.Errorf("profile %q not found. Available: %s", name, strings.Join(c.SortedProfileNames(), ", "))
	}
	return name, &p, nil
}

func (c *Config) SortedProfileNames() []string {
	names := make([]string, 0, len(c.Profiles))
	for name := range c.Profiles {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
