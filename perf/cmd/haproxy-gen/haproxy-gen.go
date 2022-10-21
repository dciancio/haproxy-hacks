package main

import (
	"bytes"
	_ "embed"
	"flag"
	"fmt"
	"html/template"
	"io/ioutil"
	"log"
	"math/rand"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/frobware/haproxy-hacks/perf"
)

type HAProxyConfig struct {
	ConfigDir string
	HTTPPort  int
	HTTPSPort int
	Maxconn   int
	Nbthread  int
	StatsPort int
	Backends  []BackendConfig
}

type BackendConfig struct {
	BackendCookie   string
	ConfigDir       string
	HostAddr        string
	Name            string
	Port            string
	ServerCookie    string
	TerminationType perf.TerminationType
}

//go:embed globals.tmpl
var globalTemplate string

//go:embed defaults.tmpl
var defaultTemplate string

//go:embed backends.tmpl
var backendTemplate string

var (
	discoveryURL = flag.String("discovery", "http://localhost:2000", "backend discovery URL")
	httpPort     = flag.Int("http-port", 8080, "haproxy http port setting")
	httpsPort    = flag.Int("https-port", 8443, "haproxy https port setting")
	maxconn      = flag.Int("maxconn", 0, "haproxy maxconn setting")
	nbthread     = flag.Int("nbthread", 4, "haproxy nbthread setting")
	statsPort    = flag.Int("stats-port", 1936, "haproxy https port setting")
	configDir    = flag.String("config-dir", fmt.Sprintf("/tmp/%v-haproxy-gen", os.Getenv("USER")), "output path")
)

func cookie() string {
	letterRunes := []rune("0123456789abcdef")
	b := make([]rune, 32)
	for i := 0; i < 32; i++ {
		b[i] = letterRunes[rand.Intn(len(letterRunes))]
	}
	return string(b)
}

func fetchBackendMetadata[T perf.TerminationType](t T) ([]string, error) {
	url := fmt.Sprintf("%s/backends/%v", *discoveryURL, t)
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		body, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}
		return strings.Split(strings.Trim(string(body), "\n"), "\n"), nil
	}

	return nil, fmt.Errorf("unexpected status %v", resp.StatusCode)
}

func fetchAllBackendMetadata() ([]BackendConfig, error) {
	var backends []BackendConfig

	for _, t := range perf.AllTerminationTypes {
		metadata, err := fetchBackendMetadata(t)
		if err != nil {
			return nil, err
		}
		for i := range metadata {
			words := strings.Split(metadata[i], " ")
			backends = append(backends, BackendConfig{
				BackendCookie:   cookie(),
				ConfigDir:       *configDir,
				HostAddr:        words[1],
				Name:            words[0],
				Port:            words[2],
				ServerCookie:    cookie(),
				TerminationType: t,
			})
		}
	}

	return backends, nil
}

func writeFileData(filename string, data bytes.Buffer) error {
	dirname := filepath.Dir(filename)
	if err := os.MkdirAll(dirname, 0755); err != nil {
		return err
	}
	f, err := os.Create(filename)
	if err != nil {
		return err
	}
	_, err = f.Write(data.Bytes())
	if err != nil {
		return err
	}
	return f.Close()
}

func main() {
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	backends, err := fetchAllBackendMetadata()
	if err != nil {
		log.Fatal(err)
	}

	config := HAProxyConfig{
		ConfigDir: *configDir,
		HTTPPort:  *httpPort,
		HTTPSPort: *httpsPort,
		Maxconn:   *maxconn,
		Nbthread:  *nbthread,
		StatsPort: *statsPort,
		Backends:  backends,
	}

	var haproxyConf bytes.Buffer

	for _, tmpl := range []*template.Template{
		template.Must(template.New("globals").Parse(globalTemplate)),
		template.Must(template.New("defaults").Parse(defaultTemplate)),
		template.Must(template.New("backends").Parse(backendTemplate)),
	} {
		if err := tmpl.Execute(&haproxyConf, config); err != nil {
			log.Fatal(err)
		}
	}

	if err := writeFileData(path.Join(*configDir, "haproxy.config"), haproxyConf); err != nil {
		log.Fatal(err)
	}

	mapData := map[perf.TerminationType]*bytes.Buffer{}

	for _, backend := range backends {
		switch backend.TerminationType {
		case perf.EdgeTermination:
			"^${name}-edge.${domain}\.?(:[0-9]+)?(/.*)?$ be_edge_http:${name}-edge"			
		case perf.HTTPTermination:
		case perf.PassthroughTermination:
		case perf.ReEncryptTermination:
		default:
			panic("unexpected termination type")
		}
	}
}
