package config

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

const (
	DefaultEndpoint = "https://fh.lvh.me/graphql"
	filePerm        = 0o600
	dirPerm         = 0o700
)

type Config struct {
	Endpoint    string `json:"endpoint"`
	AppPassword string `json:"app_password"`
}

// configDir は XDG Base Directory Spec に従い、設定ファイルのベースディレクトリを返す。
// $XDG_CONFIG_HOME が設定されていればそれを、無ければ $HOME/.config を使う。
// os.UserConfigDir() を使うとmacOSでは ~/Library/Application Support になるが、
// ターミナル向けCLIでは ~/.config/ 配下に統一する。
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

// Load は設定ファイルを読み込む。ファイルが存在しない場合はゼロ値のConfigを返す。
func Load() (*Config, error) {
	path, err := Path()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return &Config{}, nil
		}
		return nil, err
	}
	c := &Config{}
	if err := json.Unmarshal(data, c); err != nil {
		return nil, err
	}
	return c, nil
}

func Save(c *Config) error {
	path, err := Path()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), dirPerm); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, filePerm)
}

func Delete() error {
	path, err := Path()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}
