#!/bin/bash
###############################################################################
# ParkingProxy - Complete Installation Script
# Версия: 4.1.1
# Описание: Автоматическое развёртывание Parking Proxy
###############################################################################

set -o pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Конфигурационные переменные
PROJECT_DIR="/opt/parking"
CONFIG_DIR="/etc/parking"
SERVICE_NAME="parking-proxy"
GO_VERSION="1.22.5"
GO_ARCH="linux-amd64"
WEB_PORT="8080"

# Настройки MPGS и табло (изменить при необходимости)
MPGS_BASE_URL="http://192.168.50.75:8180"
MPGS_KEY="A10001"
MPGS_SECRET="uqvmk807oehIZ7wS"
MPGS_VERSION="V3.6.0"
TABLE1_IP="192.168.50.241"
TABLE1_PORT="8090"

# Логирование
LOG_FILE="/var/log/parking-proxy-install.log"
STEP_COUNTER=0

###############################################################################
# Функции вывода и логирования
###############################################################################

print_step() {
    STEP_COUNTER=$((STEP_COUNTER + 1))
    echo ""
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}  Шаг ${STEP_COUNTER}: $1${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] STEP ${STEP_COUNTER}: $1" >> "$LOG_FILE"
}

print_status() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1" >> "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >> "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$LOG_FILE"
}

###############################################################################
# Шаг 1: Проверка системы
###############################################################################

check_system() {
    print_step "Проверка системы"
    
    print_status "Проверка прав root..."
    if [[ $EUID -ne 0 ]]; then
        print_error "Скрипт должен запускаться от root"
        exit 1
    fi
    print_success "Права root подтверждены"
    
    print_status "Определение операционной системы..."
    if [ -f /etc/centos-release ]; then
        CENTOS_VERSION=$(rpm -q --queryformat '%{VERSION}' centos-release 2>/dev/null | cut -d. -f1)
        if [ -z "$CENTOS_VERSION" ]; then
            CENTOS_VERSION=$(cat /etc/centos-release | grep -oP '\d+' | head -1)
        fi
    elif [ -f /etc/redhat-release ]; then
        CENTOS_VERSION=$(cat /etc/redhat-release | grep -oP '\d+' | head -1)
    else
        CENTOS_VERSION="7"
    fi
    print_info "ОС: CentOS ${CENTOS_VERSION}"
    
    print_status "Проверка архитектуры..."
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
        print_error "Требуется x86_64, обнаружена: $ARCH"
        exit 1
    fi
    print_success "Архитектура: ${ARCH}"
    
    print_status "Проверка свободного места..."
    FREE_SPACE=$(df -m /opt 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -z "$FREE_SPACE" ] || [ "$FREE_SPACE" -lt 100 ]; then
        FREE_SPACE=$(df -m / | tail -1 | awk '{print $4}')
    fi
    if [ "$FREE_SPACE" -lt 100 ]; then
        print_error "Недостаточно места: ${FREE_SPACE}MB (нужно минимум 100MB)"
        exit 1
    fi
    print_success "Свободно: ${FREE_SPACE}MB"
    
    print_status "Проверка сети..."
    if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        print_success "Сеть доступна"
    else
        print_warning "Интернет недоступен, установка может не выполниться"
    fi
}

###############################################################################
# Шаг 2: Настройка репозиториев
###############################################################################

configure_repos() {
    print_step "Настройка репозиториев CentOS ${CENTOS_VERSION}"

    print_status "Отключение стандартных репозиториев и настройка Vault..."

    if [ -d /etc/yum.repos.d ]; then
        mkdir -p /etc/yum.repos.d/backup_$(date +%Y%m%d)
        mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup_$(date +%Y%m%d)/ 2>/dev/null || true
    fi

    cat > /etc/yum.repos.d/CentOS-Vault.repo << 'REPOEOF'
[C7-base]
name=CentOS-7 - Base
baseurl=http://vault.centos.org/centos/7/os/$basearch/
enabled=1
gpgcheck=0

[C7-updates]
name=CentOS-7 - Updates
baseurl=http://vault.centos.org/centos/7/updates/$basearch/
enabled=1
gpgcheck=0

[C7-extras]
name=CentOS-7 - Extras
baseurl=http://vault.centos.org/centos/7/extras/$basearch/
enabled=1
gpgcheck=0
REPOEOF

    yum clean all >> "$LOG_FILE" 2>&1
    yum makecache >> "$LOG_FILE" 2>&1
    print_success "Репозитории Vault настроены"
}

###############################################################################
# Шаг 3: Установка зависимостей
###############################################################################

install_deps() {
    print_step "Установка системных зависимостей"
    
    PACKAGES=("curl" "wget" "git" "gcc" "make" "tar")
    
    for pkg in "${PACKAGES[@]}"; do
        if rpm -q "$pkg" > /dev/null 2>&1; then
            print_success "$pkg уже установлен"
        else
            print_status "Установка $pkg..."
            if yum install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                print_success "$pkg установлен"
            else
                print_error "Не удалось установить $pkg"
                exit 1
            fi
        fi
    done
}

###############################################################################
# Шаг 4: Установка Go
###############################################################################

install_golang() {
    print_step "Установка Go ${GO_VERSION}"
    
    if command -v go &> /dev/null; then
        CURRENT_GO=$(go version | grep -oP 'go\K[0-9.]+')
        if [ "$CURRENT_GO" = "$GO_VERSION" ]; then
            print_success "Go ${GO_VERSION} уже установлен"
            return
        fi
        print_info "Обновление с ${CURRENT_GO} до ${GO_VERSION}"
    fi
    
    cd /tmp
    GO_TAR="go${GO_VERSION}.${GO_ARCH}.tar.gz"
    
    if [ ! -f "$GO_TAR" ]; then
        print_status "Скачивание Go..."
        wget --timeout=30 --tries=3 "https://go.dev/dl/${GO_TAR}" -O "$GO_TAR" 2>&1 | tee -a "$LOG_FILE"
        if [ $? -ne 0 ]; then
            print_error "Не удалось скачать Go"
            exit 1
        fi
    fi
    print_success "Go скачан"
    
    print_status "Установка..."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GO_TAR" 2>&1 | tee -a "$LOG_FILE"
    
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
        echo 'export GOPATH=/root/go' >> /etc/profile
        echo 'export PATH=$PATH:$GOPATH/bin' >> /etc/profile
    fi
    
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/root/go
    export PATH=$PATH:$GOPATH/bin
    mkdir -p "$GOPATH"
    
    if go version >> "$LOG_FILE" 2>&1; then
        print_success "Go установлен: $(go version)"
    else
        print_error "Ошибка установки Go"
        exit 1
    fi
}

###############################################################################
# Шаг 5: Создание структуры проекта
###############################################################################

create_structure() {
    print_step "Создание структуры проекта"
    
    if [ ! -d "$PROJECT_DIR" ]; then
        print_status "Создание каталога $PROJECT_DIR..."
        mkdir -p "$PROJECT_DIR"
        print_success "Каталог $PROJECT_DIR создан"
    fi
    
    cd "$PROJECT_DIR" || {
        print_error "Не удалось перейти в $PROJECT_DIR"
        exit 1
    }
    
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_status "Остановка старого сервиса..."
        systemctl stop "$SERVICE_NAME"
        print_success "Старый сервис остановлен"
    fi
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        print_status "Удаление старого сервиса..."
        systemctl disable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        print_success "Старый сервис удалён"
    fi

    print_status "Создание директорий..."
    mkdir -p "$CONFIG_DIR"
    mkdir -p /var/log/parking
    
    rm -f ./*.go
    rm -f ./go.mod
    rm -f ./go.sum
    
    print_success "Структура создана в $PROJECT_DIR"
}

###############################################################################
# Шаг 6: Создание файлов проекта
###############################################################################

create_files() {
    print_step "Создание файлов проекта"
    
    cd "$PROJECT_DIR"
    
    # -------------------------------------------------------------------------
    # go.mod
    # -------------------------------------------------------------------------
    print_status "Создание go.mod..."
    cat > "$PROJECT_DIR/go.mod" << 'GOMOD'
module parking-proxy

go 1.22

require (
	github.com/fsnotify/fsnotify v1.7.0
	github.com/nathan-osman/go-sunrise v1.1.0
	github.com/rs/zerolog v1.33.0
)

require (
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.19 // indirect
	golang.org/x/sys v0.12.0 // indirect
)

GOMOD
    print_success "go.mod создан"

    # -------------------------------------------------------------------------
    # main.go
    # -------------------------------------------------------------------------
    print_status "Создание main.go..."
    cat > "$PROJECT_DIR/main.go" << 'MAINEOF'
package main

import (
    "context"
    "flag"
    "os"
    "os/signal"
    "syscall"
    "time"

    "github.com/rs/zerolog"
    "github.com/rs/zerolog/log"
)

func main() {
    configPath := flag.String("config", "/etc/parking/config.json", "path to config file")
    webAddr := flag.String("web", ":8080", "web interface address")
    flag.Parse()

    zerolog.TimeFieldFormat = zerolog.TimeFormatUnix
    log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.RFC3339})

    cfg, err := Load(*configPath)
    if err != nil {
        log.Fatal().Err(err).Msg("Failed to load config")
    }

    lvl, err := zerolog.ParseLevel(cfg.LogLevel)
    if err != nil {
        lvl = zerolog.InfoLevel
    }
    zerolog.SetGlobalLevel(lvl)

    ctx, cancel := context.WithCancel(context.Background())
    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

    webServer := NewWebServer(*webAddr, *configPath)
    go func() {
        if err := webServer.Start(); err != nil {
            log.Error().Err(err).Msg("Web server error")
        }
    }()

    go func() {
        <-sigChan
        log.Info().Msg("Received shutdown signal")
        webServer.Shutdown(context.Background())
        cancel()
    }()

    svc := NewService(cfg)
    svc.Run(ctx)

    log.Info().Msg("Application stopped")
}
MAINEOF
    print_success "main.go создан"

    # -------------------------------------------------------------------------
    # config.go
    # -------------------------------------------------------------------------
    print_status "Создание config.go..."
    cat > "$PROJECT_DIR/config.go" << 'CONFIGEOF'
package main

import (
    "encoding/json"
    "fmt"
    "os"
    "sync"
    "time"

    "github.com/fsnotify/fsnotify"
    "github.com/rs/zerolog/log"
)

type MPGSConfig struct {
    BaseURL string `json:"base_url"`
    Key     string `json:"key"`
    Secret  string `json:"secret"`
    Version string `json:"version"`
    Timeout int    `json:"timeout_sec"`
}

type NavigationConfig struct {
    URL     string `json:"url"`
    Timeout int    `json:"timeout_sec"`
}

type TableConfig struct {
    IP      string     `json:"ip"`
    Port    int        `json:"port"`
    Mode    string     `json:"mode"`
    Pattern int        `json:"pattern"`
    Row1    *RowConfig `json:"row1,omitempty"`
    Row2    *RowConfig `json:"row2,omitempty"`
    Row3    *RowConfig `json:"row3,omitempty"`
    Row4    *RowConfig `json:"row4,omitempty"`
}

type RowConfig struct {
    Text   string   `json:"text"`
    Img    string   `json:"img"`
    Zones  []string `json:"zones"`
    Floors []string `json:"floors"`
}

type Location struct {
    Lat float64 `json:"lat"`
    Lon float64 `json:"lon"`
}

type Config struct {
    MPGS         MPGSConfig       `json:"mpgs"`
    Navigation   NavigationConfig `json:"navigation"`
    Tables       []TableConfig    `json:"tables"`
    Location     Location         `json:"location"`
    LogLevel     string           `json:"log_level"`
    SunriseHour  int              `json:"sunrise_hour"`
    SunsetHour   int              `json:"sunset_hour"`
}

// maxRowsForPattern returns the maximum number of rows allowed for a given pattern.
// pattern 0 -> 4 rows, pattern 1 -> 3 rows (str1..str3), pattern 2 -> 1 row (str1 only).
func maxRowsForPattern(pattern int) int {
    switch pattern {
    case 1:
        return 3
    case 2:
        return 1
    default:
        return 4
    }
}

// imgAllowedForPattern returns true when img value is valid for the given pattern.
// pattern 0/1: car, ecar, moto, 2car
// pattern 2  : car, ecar, moto, 2car, arrow_up, arrow_down, arrow_left, arrow_right
func imgAllowedForPattern(img string, pattern int) bool {
    base := map[string]bool{"car": true, "ecar": true, "moto": true, "2car": true}
    if base[img] {
        return true
    }
    if pattern == 2 {
        arrows := map[string]bool{
            "arrow_up": true, "arrow_down": true,
            "arrow_left": true, "arrow_right": true,
        }
        return arrows[img]
    }
    return false
}

var (
    cfg  *Config
    once sync.Once
    mu   sync.RWMutex
)

func Load(path string) (*Config, error) {
    var loadErr error
    once.Do(func() {
        cfg, loadErr = loadConfig(path)
        if loadErr != nil {
            return
        }
        go watchConfig(path)
    })
    return cfg, loadErr
}

func loadConfig(path string) (*Config, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return nil, fmt.Errorf("read config: %w", err)
    }
    var c Config
    if err := json.Unmarshal(data, &c); err != nil {
        return nil, fmt.Errorf("parse config: %w", err)
    }
    if err := c.Validate(); err != nil {
        return nil, err
    }
    log.Info().Str("path", path).Msg("Config loaded successfully")
    return &c, nil
}

func watchConfig(path string) {
    watcher, err := fsnotify.NewWatcher()
    if err != nil {
        log.Error().Err(err).Msg("Failed to create config watcher")
        return
    }
    defer watcher.Close()

    if err := watcher.Add(path); err != nil {
        log.Error().Err(err).Msg("Failed to watch config file")
        return
    }

    var debounceTimer *time.Timer
    for {
        select {
        case event, ok := <-watcher.Events:
            if !ok {
                return
            }
            if event.Op&fsnotify.Write == fsnotify.Write {
                if debounceTimer != nil {
                    debounceTimer.Stop()
                }
                debounceTimer = time.AfterFunc(1*time.Second, func() {
                    newCfg, err := loadConfig(path)
                    if err != nil {
                        log.Error().Err(err).Msg("Hot reload failed: invalid config")
                        return
                    }
                    mu.Lock()
                    cfg = newCfg
                    mu.Unlock()
                    log.Info().Msg("Config hot-reloaded successfully")
                })
            }
        case err, ok := <-watcher.Errors:
            if !ok {
                return
            }
            log.Error().Err(err).Msg("Config watcher error")
        }
    }
}

func (c *Config) Validate() error {
    if c.MPGS.BaseURL == "" || c.MPGS.Key == "" || c.MPGS.Secret == "" {
        return fmt.Errorf("mpgs.base_url, key and secret are required")
    }
    if c.Location.Lat == 0 || c.Location.Lon == 0 {
        return fmt.Errorf("location.lat/lon are required")
    }
    if len(c.Tables) == 0 || len(c.Tables) > 30 {
        return fmt.Errorf("tables count must be 1..30")
    }
    for i, t := range c.Tables {
        if t.Mode != "push" && t.Mode != "pull" {
            return fmt.Errorf("table %d: mode must be 'push' or 'pull'", i)
        }
        if t.Pattern < 0 || t.Pattern > 2 {
            return fmt.Errorf("table %d: pattern must be 0, 1 or 2", i)
        }
        maxRows := maxRowsForPattern(t.Pattern)
        rows := []*RowConfig{t.Row1, t.Row2, t.Row3, t.Row4}
        for j := maxRows; j < 4; j++ {
            if rows[j] != nil {
                return fmt.Errorf("table %d: pattern %d allows max %d rows, but row%d is defined",
                    i, t.Pattern, maxRows, j+1)
            }
        }
        for j := 0; j < maxRows; j++ {
            r := rows[j]
            if r == nil {
                continue
            }
            if r.Img != "" && !imgAllowedForPattern(r.Img, t.Pattern) {
                return fmt.Errorf("table %d row%d: img '%s' not allowed for pattern %d",
                    i, j+1, r.Img, t.Pattern)
            }
        }
    }
    return nil
}

func Get() *Config {
    mu.RLock()
    defer mu.RUnlock()
    return cfg
}
CONFIGEOF
    print_success "config.go создан"

    # -------------------------------------------------------------------------
    # mpgs.go
    # -------------------------------------------------------------------------
    print_status "Создание mpgs.go..."
    cat > "$PROJECT_DIR/mpgs.go" << 'FETCHEREOF'
package main

import (
    "bytes"
    "context"
    "crypto/md5"
    "encoding/json"
    "fmt"
    "io"
    "net"
    "net/http"
    "sort"
    "strings"
    "time"

    "github.com/rs/zerolog/log"
)

type MPGSResponse struct {
    Ret  int             `json:"ret"`
    Msg  string          `json:"msg"`
    Data json.RawMessage `json:"data"`
}

type SpaceInfo struct {
    ParkingSpaceNumber string `json:"parkingSpaceNumber"`
    ParkingSpaceStatus int    `json:"parkingSpaceStatus"`
    BelongArea         string `json:"belongArea"`
    MapName            string `json:"mapName"`
}

type SpaceListResponse struct {
    Count int         `json:"count"`
    List  []SpaceInfo `json:"list"`
}

type MPGSFetcher struct {
    baseURL    string
    key        string
    secret     string
    version    string
    httpClient *http.Client
    apiURL     string
}

func NewMPGSFetcher(baseURL, key, secret, version string, timeout int) *MPGSFetcher {
    baseURL = strings.TrimRight(baseURL, "/")
    apiURL := baseURL + "/mpgs/api/v3/parkingSpace/getParkingSpaceInfo"

    return &MPGSFetcher{
        baseURL: baseURL,
        key:     key,
        secret:  secret,
        version: version,
        apiURL:  apiURL,
        httpClient: &http.Client{
            Timeout: time.Duration(timeout) * time.Second,
            Transport: &http.Transport{
                MaxIdleConns:        100,
                MaxIdleConnsPerHost: 10,
                IdleConnTimeout:     90 * time.Second,
                DialContext: (&net.Dialer{
                    Timeout:   5 * time.Second,
                    KeepAlive: 30 * time.Second,
                }).DialContext,
            },
        },
    }
}

func (f *MPGSFetcher) generateSign(timestamp string) string {
    params := map[string]string{
        "key":       f.key,
        "timestamp": timestamp,
        "version":   f.version,
    }
    keys := make([]string, 0, len(params))
    for k := range params {
        keys = append(keys, k)
    }
    sort.Strings(keys)

    var signStr string
    for i, k := range keys {
        if i > 0 {
            signStr += "&"
        }
        signStr += fmt.Sprintf("%s=%s", k, params[k])
    }
    signStr += "secret=" + f.secret

    hash := md5.Sum([]byte(signStr))
    return fmt.Sprintf("%X", hash)
}

func (f *MPGSFetcher) Fetch(ctx context.Context) ([]SpaceInfo, error) {
    startTime := time.Now()
    timestamp := time.Now().Format("20060102150405")
    sign := f.generateSign(timestamp)

    body := map[string]interface{}{
        "key":       f.key,
        "timestamp": timestamp,
        "version":   f.version,
        "sign":      sign,
    }
    bodyJSON, _ := json.Marshal(body)

    req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.apiURL, bytes.NewReader(bodyJSON))
    if err != nil {
        return nil, fmt.Errorf("create request: %w", err)
    }
    req.Header.Set("Content-Type", "application/json; charset=utf-8")

    resp, err := f.httpClient.Do(req)
    if err != nil {
        return nil, fmt.Errorf("do request: %w", err)
    }
    defer resp.Body.Close()

    bodyBytes, err := io.ReadAll(resp.Body)
    if err != nil {
        return nil, fmt.Errorf("read response: %w", err)
    }

    log.Info().
        Str("url", f.apiURL).
        Str("request", string(bodyJSON)).
        Str("response", string(bodyBytes)).
        Int("status", resp.StatusCode).
        Dur("duration", time.Since(startTime)).
        Msg("MPGS request")

    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("bad status %d: %s", resp.StatusCode, string(bodyBytes))
    }

    var mpgsResp MPGSResponse
    if err := json.Unmarshal(bodyBytes, &mpgsResp); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    if mpgsResp.Ret != 0 {
        return nil, fmt.Errorf("mpgs error ret=%d msg=%s", mpgsResp.Ret, mpgsResp.Msg)
    }

    if mpgsResp.Data == nil || string(mpgsResp.Data) == "{}" {
        return []SpaceInfo{}, nil
    }

    var listResp SpaceListResponse
    if err := json.Unmarshal(mpgsResp.Data, &listResp); err != nil {
        return nil, fmt.Errorf("unmarshal data: %w", err)
    }

    log.Debug().Int("count", listResp.Count).Msg("Fetched parking spaces")
    return listResp.List, nil
}
FETCHEREOF
    print_success "mpgs.go создан"

    # -------------------------------------------------------------------------
    # astro.go
    # -------------------------------------------------------------------------
    print_status "Создание astro.go..."
    cat > "$PROJECT_DIR/astro.go" << 'ASTROEOF'
package main

import (
    "time"

    "github.com/nathan-osman/go-sunrise"
    "github.com/rs/zerolog/log"
)

type SunCalc struct {
    Lat, Lon float64
}

func NewSunCalc(lat, lon float64) *SunCalc {
    return &SunCalc{Lat: lat, Lon: lon}
}

func (s *SunCalc) IsDay(t time.Time) bool {
    rise, set := sunrise.SunriseSunset(s.Lat, s.Lon, t.Year(), t.Month(), t.Day())
    return t.After(rise) && t.Before(set)
}

func (s *SunCalc) WatchDayNight(onChange func(bool)) {
    ticker := time.NewTicker(30 * time.Second)
    lastState := s.IsDay(time.Now())
    log.Info().Bool("is_day", lastState).Msg("Initial day/night state")

    for range ticker.C {
        currentState := s.IsDay(time.Now())
        if currentState != lastState {
            log.Info().Bool("new_state", currentState).Msg("Day/Night changed")
            onChange(currentState)
            lastState = currentState
        }
    }
}
ASTROEOF
    print_success "astro.go создан"

    # -------------------------------------------------------------------------
    # processor.go
    # -------------------------------------------------------------------------
    print_status "Создание processor.go..."
    cat > "$PROJECT_DIR/processor.go" << 'PROCESSOREOF'
package main

import (
    "fmt"
    "sync"
    "time"

    "github.com/rs/zerolog/log"
)

type TablePayload struct {
    Type     string `json:"type"`
    Version  int    `json:"version"`
    DateTime int64  `json:"datetime"`
    Pattern  int    `json:"pattern"`
    IsDay    bool   `json:"is_day"`
    Str1     *Row   `json:"str1,omitempty"`
    Str2     *Row   `json:"str2,omitempty"`
    Str3     *Row   `json:"str3,omitempty"`
    Str4     *Row   `json:"str4,omitempty"`
}

type Row struct {
    Img  string `json:"img,omitempty"`
    Text string `json:"text,omitempty"`
}

type Processor struct {
    mu            sync.RWMutex
    lastFreeCount map[string]int
}

func NewProcessor() *Processor {
    return &Processor{
        lastFreeCount: make(map[string]int),
    }
}

func (p *Processor) Process(data []SpaceInfo, cfg *Config) (map[string]TablePayload, bool) {
    p.mu.Lock()
    defer p.mu.Unlock()

    zoneFree := make(map[string]int)
    floorFree := make(map[string]int)

    for _, s := range data {
        if s.ParkingSpaceStatus == 0 {
            zone := s.BelongArea
            if zone == "" {
                zone = "unknown"
            }
            zoneFree[zone]++

            floor := s.MapName
            if floor == "" {
                floor = "unknown"
            }
            floorFree[floor]++
        }
    }

    log.Debug().
        Interface("zones", zoneFree).
        Interface("floors", floorFree).
        Msg("Free spaces by zone/floor")

    changed := false
    result := make(map[string]TablePayload)

    for _, t := range cfg.Tables {
        maxRows := maxRowsForPattern(t.Pattern)
        payload := TablePayload{
            Type:    "strs",
            Version: 1,
            Pattern: t.Pattern,
            IsDay:   isDaytime(),
        }

        hasAnyRow := false
        rows := []*RowConfig{t.Row1, t.Row2, t.Row3, t.Row4}

        for j := 0; j < maxRows; j++ {
            row := rows[j]
            if row == nil || (len(row.Zones) == 0 && len(row.Floors) == 0) {
                continue
            }
            free := countFreeSpaces(zoneFree, floorFree, row.Zones, row.Floors)
            key := fmt.Sprintf("%s_row%d", t.IP, j+1)
            if old, ok := p.lastFreeCount[key]; !ok || old != free {
                changed = true
            }
            p.lastFreeCount[key] = free
            r := &Row{Img: row.Img, Text: fmt.Sprintf("%d", free)}
            switch j {
            case 0:
                payload.Str1 = r
            case 1:
                payload.Str2 = r
            case 2:
                payload.Str3 = r
            case 3:
                payload.Str4 = r
            }
            hasAnyRow = true
        }

        if hasAnyRow {
            result[t.IP] = payload
        }
    }
    return result, changed
}

func countFreeSpaces(zoneFree, floorFree map[string]int, zones, floors []string) int {
    count := 0
    for _, z := range zones {
        count += zoneFree[z]
    }
    for _, f := range floors {
        count += floorFree[f]
    }
    return count
}

func isDaytime() bool {
    cfg := Get()
    now := time.Now()
    sunrise := 7
    sunset := 18
    if cfg != nil {
        if cfg.SunriseHour > 0 {
            sunrise = cfg.SunriseHour
        }
        if cfg.SunsetHour > 0 {
            sunset = cfg.SunsetHour
        }
    }
    return now.Hour() >= sunrise && now.Hour() < sunset
}
PROCESSOREOF
    print_success "processor.go создан"

    # -------------------------------------------------------------------------
    # sender.go
    # -------------------------------------------------------------------------
    print_status "Создание sender.go..."
    cat > "$PROJECT_DIR/sender.go" << 'SENDEREOF'
package main

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "time"

    "github.com/rs/zerolog/log"
)

type TableSender struct {
    httpClient *http.Client
}

func NewTableSender(timeout int) *TableSender {
    return &TableSender{
        httpClient: &http.Client{
            Timeout: time.Duration(timeout) * time.Second,
            Transport: &http.Transport{
                MaxIdleConnsPerHost: 5,
                IdleConnTimeout:     30 * time.Second,
            },
        },
    }
}

func (s *TableSender) SendWithRetry(ctx context.Context, ip string, port int, payload TablePayload) error {
    startTime := time.Now()
    payload.DateTime = time.Now().Unix()
    url := fmt.Sprintf("http://%s:%d/places", ip, port)
    jsonData, _ := json.Marshal(payload)

    var lastErr error
    for attempt := 1; attempt <= 3; attempt++ {
        req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(jsonData))
        req.Header.Set("Content-Type", "application/json; charset=utf-8")
        req.Header.Set("Connection", "close")

        resp, err := s.httpClient.Do(req)
        if err == nil {
            body, _ := io.ReadAll(resp.Body)
            resp.Body.Close()

            log.Info().
                Str("ip", ip).
                Int("port", port).
                Str("request", string(jsonData)).
                Str("response", string(body)).
                Int("status", resp.StatusCode).
                Int("attempt", attempt).
                Dur("duration", time.Since(startTime)).
                Msg("Table request")

            if resp.StatusCode == http.StatusOK {
                return nil
            }
            lastErr = fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
        } else {
            log.Warn().
                Str("ip", ip).
                Int("port", port).
                Str("request", string(jsonData)).
                Err(err).
                Int("attempt", attempt).
                Dur("duration", time.Since(startTime)).
                Msg("Table request failed")
            lastErr = err
        }

        if attempt < 3 {
            select {
            case <-time.After(2 * time.Second):
            case <-ctx.Done():
                return ctx.Err()
            }
        }
    }
    return fmt.Errorf("failed after 3 attempts: %w", lastErr)
}
SENDEREOF
    print_success "sender.go создан"

    # -------------------------------------------------------------------------
    # service.go
    # -------------------------------------------------------------------------
    print_status "Создание service.go..."
    cat > "$PROJECT_DIR/service.go" << 'SERVICEEOF'
package main

import (
    "context"
    "sync"
    "time"

    "github.com/rs/zerolog/log"
)

type Service struct {
    cfg         *Config
    fetcher     *MPGSFetcher
    processor   *Processor
    sender      *TableSender
    fetchErrors int
}

func NewService(cfg *Config) *Service {
    return &Service{
        cfg:       cfg,
        fetcher:   NewMPGSFetcher(cfg.MPGS.BaseURL, cfg.MPGS.Key, cfg.MPGS.Secret, cfg.MPGS.Version, cfg.MPGS.Timeout),
        processor: NewProcessor(),
        sender:    NewTableSender(2),
    }
}

func (s *Service) Run(ctx context.Context) {
    log.Info().Str("mpgs_url", s.cfg.MPGS.BaseURL).Msg("Service started")

    go func() {
        t := time.NewTicker(30 * time.Second)
        defer t.Stop()
        for range t.C {
            s.tick(ctx, true)
        }
    }()

    ticker := time.NewTicker(2 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            log.Info().Msg("Shutting down...")
            return
        case <-ticker.C:
            s.tick(ctx, false)
        }
    }
}

func (s *Service) tick(ctx context.Context, forceSend bool) {
    s.cfg = Get()
    s.fetcher = NewMPGSFetcher(s.cfg.MPGS.BaseURL, s.cfg.MPGS.Key, s.cfg.MPGS.Secret, s.cfg.MPGS.Version, s.cfg.MPGS.Timeout)

    data, err := s.fetcher.Fetch(ctx)
    if err != nil {
        s.fetchErrors++
        log.Error().Err(err).Int("errors", s.fetchErrors).Msg("Fetch failed")
        if s.fetchErrors > 5 {
            time.Sleep(8 * time.Second)
        }
        return
    }
    s.fetchErrors = 0

    payloads, changed := s.processor.Process(data, s.cfg)
    if !changed && !forceSend {
        return
    }

    if changed {
        log.Info().Int("tables_to_update", len(payloads)).Msg("Parking data changed, updating tables")
    }

    var wg sync.WaitGroup
    for ip, payload := range payloads {
        wg.Add(1)
        go func(ip string, p TablePayload) {
            defer wg.Done()
            var port int
            var mode string
            for _, t := range s.cfg.Tables {
                if t.IP == ip {
                    port = t.Port
                    mode = t.Mode
                    break
                }
            }

            if mode == "push" {
                if err := s.sender.SendWithRetry(ctx, ip, port, p); err != nil {
                    log.Error().Err(err).Str("ip", ip).Int("port", port).Msg("Send failed")
                }
            } else {
                log.Debug().Str("ip", ip).Msg("Pull mode: waiting for table to request data")
            }
        }(ip, payload)
    }
    wg.Wait()
}
SERVICEEOF
    print_success "service.go создан"

    # -------------------------------------------------------------------------
    # web.go  — ОСНОВНЫЕ ИЗМЕНЕНИЯ: логика pattern в UI
    # -------------------------------------------------------------------------
    print_status "Создание web.go..."
    cat > "$PROJECT_DIR/web.go" << 'WEBEOF'
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "os"
    "strings"
    "time"

    "github.com/rs/zerolog/log"
)

type WebServer struct {
    srv     *http.Server
    cfgPath string
}

func NewWebServer(addr, cfgPath string) *WebServer {
    ws := &WebServer{
        cfgPath: cfgPath,
        srv: &http.Server{
            Addr:         addr,
            ReadTimeout:  10 * time.Second,
            WriteTimeout: 10 * time.Second,
        },
    }

    mux := http.NewServeMux()
    mux.HandleFunc("/", ws.handleIndex)
    mux.HandleFunc("/api/test-mpgs", ws.handleTestMPGS)
    mux.HandleFunc("/api/save-config", ws.handleSaveConfig)
    mux.HandleFunc("/api/test-table", ws.handleTestTable)

    ws.srv.Handler = mux
    return ws
}

func (ws *WebServer) Start() error {
    log.Info().Str("addr", ws.srv.Addr).Msg("Starting web interface")
    return ws.srv.ListenAndServe()
}

func (ws *WebServer) Shutdown(ctx context.Context) error {
    return ws.srv.Shutdown(ctx)
}

func (ws *WebServer) handleIndex(w http.ResponseWriter, r *http.Request) {
    cfg := Get()
    if cfg == nil {
        http.Error(w, "Config not loaded", 500)
        return
    }
    w.Header().Set("Content-Type", "text/html; charset=utf-8")
    w.Write([]byte(buildIndexHTML(cfg)))
}

func savedTablesJSON(cfg *Config) string {
    data, _ := json.Marshal(cfg.Tables)
    return string(data)
}

func buildIndexHTML(cfg *Config) string {
    tablesHTML := ""
    for i, t := range cfg.Tables {
        tablesHTML += buildTableBlockHTML(i, t)
    }

    return fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Parking Proxy</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: Arial, sans-serif; background: #f0f2f5; padding: 20px; }
.container { max-width: 1200px; margin: 0 auto; }
.header { background: #1a73e8; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
.block { background: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
.block h2 { color: #1a73e8; margin-bottom: 15px; border-bottom: 2px solid #1a73e8; padding-bottom: 10px; }
.form-group { margin-bottom: 15px; }
label { display: block; margin-bottom: 5px; font-weight: bold; }
input, select { width: 100%%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; }
.row { display: flex; gap: 15px; }
.col { flex: 1; }
button { background: #1a73e8; color: white; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer; margin: 5px; }
button:hover { background: #1557b0; }
button.danger { background: #dc3545; }
button.success { background: #28a745; }
pre { background: #f4f4f4; padding: 15px; border-radius: 4px; overflow-x: auto; font-size: 12px; max-height: 600px; overflow-y: auto; white-space: pre-wrap; word-wrap: break-word; }
.result { margin-top: 15px; }
.table-block { border: 1px solid #ddd; padding: 15px; margin-bottom: 15px; border-radius: 4px; }
.remove-btn { float: right; }
.row-data { background: #f8f9fa; padding: 10px; margin: 5px 0; border-radius: 4px; position: relative; }
.row-data input, .row-data select { width: auto; display: inline; }
.row-data.hidden { display: none; }
.stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px; margin: 10px 0; }
.stat-card { background: #e8f0fe; padding: 10px; border-radius: 4px; text-align: center; }
.stat-card .value { font-size: 24px; font-weight: bold; color: #1a73e8; }
.stat-card .label { font-size: 12px; color: #666; }
table { width: 100%%; border-collapse: collapse; margin: 10px 0; }
th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
th { background: #f0f0f0; }
.checkbox-group { display: flex; flex-wrap: wrap; gap: 8px; margin: 5px 0; }
.checkbox-group label { display: inline-flex; align-items: center; gap: 3px; font-weight: normal; cursor: pointer; font-size: 13px; }
.checkbox-group input[type=checkbox] { width: auto; }
.pattern-badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 12px; font-weight: bold; margin-left: 8px; background: #e8f0fe; color: #1a73e8; }
</style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Parking Proxy</h1>
        <p>MPGS: %s | Tables: %d</p>
    </div>
    <div class="block">
        <h2>MPGS API</h2>
        <div class="row">
            <div class="col"><div class="form-group"><label>URL</label><input id="mpgs_url" value="%s"></div></div>
            <div class="col"><div class="form-group"><label>Timeout (sec)</label><input type="number" id="mpgs_timeout" value="%d"></div></div>
        </div>
        <div class="row">
            <div class="col"><div class="form-group"><label>Key</label><input id="mpgs_key" value="%s"></div></div>
            <div class="col"><div class="form-group"><label>Secret</label><input id="mpgs_secret" value="%s"></div></div>
        </div>
        <button onclick="testMPGS()">Get MPGS Data</button>
        <div id="mpgs_result" class="result"></div>
    </div>
    <div class="block">
        <h2>Tables</h2>
        <div id="tables_container">%s</div>
        <button class="success" onclick="addTable()">+ Add Table</button>
        <br><br>
        <button onclick="saveConfig()">Save Config</button>
        <div id="save_result" class="result"></div>
    </div>
    <div class="block">
        <h2>Day/Night Settings</h2>
        <div class="row">
            <div class="col">
                <div class="form-group">
                    <label>Sunrise Hour (is_day: true from)</label>
                    <input type="number" id="sunrise_hour" value="%d" min="0" max="23">
                </div>
            </div>
            <div class="col">
                <div class="form-group">
                    <label>Sunset Hour (is_day: false from)</label>
                    <input type="number" id="sunset_hour" value="%d" min="0" max="23">
                </div>
            </div>
        </div>
        <button onclick="saveDayNight()">Save Day/Night</button>
        <div id="daynight_result" class="result"></div>
    </div>
</div>
<script>
// ─── constants ────────────────────────────────────────────────────────────────
const IMG_BASE    = ["car","ecar","moto","2car"];
const IMG_PATTERN2 = ["car","ecar","moto","2car","arrow_up","arrow_down","arrow_left","arrow_right"];

// maxRows[pattern] and which img list to use
const PATTERN_MAX_ROWS = {0: 4, 1: 3, 2: 1};
const PATTERN_IMG = {0: IMG_BASE, 1: IMG_BASE, 2: IMG_PATTERN2};

let tablesCount = %d;
let lastMPGSData = null;

// ─── helpers ──────────────────────────────────────────────────────────────────
function buildImgSelectHTML(id, selected, pattern) {
    const opts = PATTERN_IMG[pattern] || IMG_BASE;
    let html = '<select id="' + id + '">';
    opts.forEach(function(img) {
        html += '<option value="' + img + '"' + (img === selected ? ' selected' : '') + '>' + img + '</option>';
    });
    html += '</select>';
    return html;
}

// ─── pattern change ──────────────────────────────────────────────────────────
function onPatternChange(tableIdx) {
    const patternVal = parseInt(document.getElementById('table_' + tableIdx + '_pattern').value);
    const maxRows = PATTERN_MAX_ROWS[patternVal] || 4;

    for (let j = 1; j <= 4; j++) {
        const container = document.getElementById('table_' + tableIdx + '_row' + j + '_container');
        if (!container) continue;

        if (j > maxRows) {
            // Hide and clear rows that exceed the pattern limit
            container.classList.add('hidden');
            clearRow(tableIdx, j);
        } else {
            container.classList.remove('hidden');
            // Rebuild img select with correct options for new pattern
            const imgSel = document.getElementById('table_' + tableIdx + '_row' + j + '_img');
            if (imgSel) {
                const currentVal = imgSel.value;
                const newOpts = PATTERN_IMG[patternVal] || IMG_BASE;
                let newHTML = '';
                newOpts.forEach(function(img) {
                    const sel = (img === currentVal && newOpts.includes(currentVal)) ? ' selected' : '';
                    newHTML += '<option value="' + img + '"' + sel + '>' + img + '</option>';
                });
                imgSel.innerHTML = newHTML;
            }
        }
    }
}

// ─── MPGS test ────────────────────────────────────────────────────────────────
function testMPGS() {
    const data = {
        base_url: document.getElementById("mpgs_url").value,
        key:      document.getElementById("mpgs_key").value,
        secret:   document.getElementById("mpgs_secret").value,
        version:  "V3.6.0",
        timeout:  parseInt(document.getElementById("mpgs_timeout").value)
    };
    document.getElementById("mpgs_result").innerHTML = "<pre>Loading...</pre>";
    fetch("/api/test-mpgs", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(data)})
    .then(r => r.json())
    .then(result => {
        document.getElementById("mpgs_result").innerHTML = formatMPGSResult(result);
    });
}

function formatMPGSResult(result) {
    let html = '';
    if (result.success) {
        lastMPGSData = result;
        html += '<div class="stats-grid">';
        html += '<div class="stat-card"><div class="value">' + result.total_spaces + '</div><div class="label">Total Spaces</div></div>';
        html += '<div class="stat-card"><div class="value" style="color:green">' + result.total_free + '</div><div class="label">Free</div></div>';
        html += '<div class="stat-card"><div class="value" style="color:red">' + result.total_occupied + '</div><div class="label">Occupied</div></div>';
        html += '<div class="stat-card"><div class="value">' + result.elapsed_ms + 'ms</div><div class="label">Response Time</div></div>';
        html += '</div>';
        if (result.zones && Object.keys(result.zones).length > 0) {
            html += '<h3>By Zone</h3><table><tr><th>Zone</th><th>Total</th><th>Free</th><th>Occupied</th></tr>';
            for (const zone in result.zones) {
                const z = result.zones[zone];
                html += '<tr><td>' + zone + '</td><td>' + z.total + '</td><td style="color:green">' + z.free + '</td><td style="color:red">' + z.occupied + '</td></tr>';
            }
            html += '</table>';
        }
        if (result.floors && Object.keys(result.floors).length > 0) {
            html += '<h3>By Floor</h3><table><tr><th>Floor</th><th>Total</th><th>Free</th><th>Occupied</th></tr>';
            for (const floor in result.floors) {
                const f = result.floors[floor];
                html += '<tr><td>' + floor + '</td><td>' + f.total + '</td><td style="color:green">' + f.free + '</td><td style="color:red">' + f.occupied + '</td></tr>';
            }
            html += '</table>';
        }
        html += '<h3>Detailed Data</h3><pre>' + JSON.stringify(result.spaces, null, 2) + '</pre>';
        updateAllCheckboxes(result);
    } else {
        html += '<pre style="color:red">Error (' + result.elapsed_ms + 'ms): ' + result.error + '</pre>';
    }
    return html;
}

// ─── checkbox helpers ─────────────────────────────────────────────────────────
function updateAllCheckboxes(data) {
    for (let i = 0; i < tablesCount; i++) {
        const patternEl = document.getElementById('table_' + i + '_pattern');
        const maxRows = patternEl ? (PATTERN_MAX_ROWS[parseInt(patternEl.value)] || 4) : 4;
        for (let j = 1; j <= maxRows; j++) {
            updateRowCheckboxes(i, j, data);
        }
    }
}

function updateRowCheckboxes(tableIdx, rowIdx, data) {
    const zoneDiv  = document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_zonecheckboxes');
    const floorDiv = document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_floorcheckboxes');
    if (!zoneDiv || !floorDiv) return;
    if (!data) { zoneDiv.innerHTML = 'Zones: no data'; floorDiv.innerHTML = 'Floors: no data'; return; }

    const zones  = Object.keys(data.zones  || {}).sort();
    const floors = Object.keys(data.floors || {}).sort();

    zoneDiv.innerHTML = 'Zones: ' + zones.map(function(z) {
        return '<label><input type="checkbox" class="table_' + tableIdx + '_row' + rowIdx + '_zone" value="' + z + '" onchange="updateRowValue(' + tableIdx + ',' + rowIdx + ')"> ' + z + '</label>';
    }).join('');
    floorDiv.innerHTML = 'Floors: ' + floors.map(function(f) {
        return '<label><input type="checkbox" class="table_' + tableIdx + '_row' + rowIdx + '_floor" value="' + f + '" onchange="updateRowValue(' + tableIdx + ',' + rowIdx + ')"> ' + f + '</label>';
    }).join('');
}

function getCheckedValues(tableIdx, rowIdx, type) {
    return Array.from(document.querySelectorAll('.table_' + tableIdx + '_row' + rowIdx + '_' + type + ':checked'))
                .map(cb => cb.value);
}

function updateRowValue(tableIdx, rowIdx) {
    if (!lastMPGSData) return;
    const selectedZones  = getCheckedValues(tableIdx, rowIdx, 'zone');
    const selectedFloors = getCheckedValues(tableIdx, rowIdx, 'floor');
    if (selectedZones.length === 0 && selectedFloors.length === 0) {
        document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_text').value = '0';
        return;
    }
    let totalFree = 0;
    if (lastMPGSData.spaces) {
        lastMPGSData.spaces.forEach(function(space) {
            if (space.parkingSpaceStatus === 0) {
                const zm = selectedZones.length  === 0 || selectedZones.includes(space.belongArea || 'unknown');
                const fm = selectedFloors.length === 0 || selectedFloors.includes(space.mapName   || 'unknown');
                if (zm && fm) totalFree++;
            }
        });
    }
    document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_text').value = totalFree;
    const zd = document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_zones_display');
    const fd = document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_floors_display');
    if (zd) zd.textContent = selectedZones.join(', ')  || 'any';
    if (fd) fd.textContent = selectedFloors.join(', ') || 'any';
}

function clearRow(tableIdx, rowIdx) {
    const textEl = document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_text');
    if (textEl) textEl.value = '';
    document.querySelectorAll(
        '.table_' + tableIdx + '_row' + rowIdx + '_zone:checked, ' +
        '.table_' + tableIdx + '_row' + rowIdx + '_floor:checked'
    ).forEach(cb => { cb.checked = false; });
    const zd = document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_zones_display');
    const fd = document.getElementById('table_' + tableIdx + '_row' + rowIdx + '_floors_display');
    if (zd) zd.textContent = '-';
    if (fd) fd.textContent = '-';
}

// ─── row block HTML builder ───────────────────────────────────────────────────
function buildRowHTML(i, j, pattern, textVal, imgVal) {
    const imgOptions = PATTERN_IMG[pattern] || IMG_BASE;
    let imgSel = '<select id="table_' + i + '_row' + j + '_img">';
    imgOptions.forEach(function(img) {
        imgSel += '<option value="' + img + '"' + (img === imgVal ? ' selected' : '') + '>' + img + '</option>';
    });
    imgSel += '</select>';

    const maxRows = PATTERN_MAX_ROWS[pattern] || 4;
    const hiddenClass = j > maxRows ? ' hidden' : '';

    return '<div class="row-data' + hiddenClass + '" id="table_' + i + '_row' + j + '_container">' +
        '<strong>Row ' + j + ':</strong> ' +
        '<button class="remove-btn danger" onclick="clearRow(' + i + ',' + j + ')" style="padding:2px 8px;font-size:12px">X</button> ' +
        'Text: <input id="table_' + i + '_row' + j + '_text" value="' + (textVal||'') + '" style="width:80px" placeholder="0" type="number"> ' +
        'Img: ' + imgSel +
        '<div style="margin-top:5px">' +
        '<strong>Zones:</strong> <span id="table_' + i + '_row' + j + '_zones_display">-</span>&nbsp;' +
        '<strong>Floors:</strong> <span id="table_' + i + '_row' + j + '_floors_display">-</span></div>' +
        '<div class="checkbox-group">' +
        '<div id="table_' + i + '_row' + j + '_zonecheckboxes">Zones: no data</div> ' +
        '<div id="table_' + i + '_row' + j + '_floorcheckboxes">Floors: no data</div></div>' +
        '<button onclick="updateRowValue(' + i + ',' + j + ')" style="background:#ff9800;padding:5px 10px;font-size:12px">Update from MPGS</button>' +
        '</div>';
}

// ─── table HTML builder ───────────────────────────────────────────────────────
function buildTableHTML(i, ip, port, pattern) {
    let rowsHTML = '';
    for (let j = 1; j <= 4; j++) {
        rowsHTML += buildRowHTML(i, j, pattern, '', IMG_BASE[j-1] || 'car');
    }
    return '<button class="remove-btn danger" onclick="removeTable(' + i + ')">X</button>' +
        '<h3>Table ' + i + '</h3>' +
        '<div class="row">' +
        '<div class="col"><label>IP</label><input id="table_' + i + '_ip" value="' + (ip||'192.168.50.241') + '"></div>' +
        '<div class="col"><label>Port</label><input type="number" id="table_' + i + '_port" value="' + (port||8090) + '"></div>' +
        '</div>' +
        '<div class="form-group"><label>Pattern' +
        ' <span class="pattern-badge" id="table_' + i + '_pattern_hint">0 — up to 4 rows: car/ecar/moto/2car</span></label>' +
        '<select id="table_' + i + '_pattern" onchange="onPatternChange(' + i + ')">' +
        '<option value="0"' + (pattern===0?' selected':'') + '>0 — 4 rows (car/ecar/moto/2car)</option>' +
        '<option value="1"' + (pattern===1?' selected':'') + '>1 — 3 rows (car/ecar/moto/2car)</option>' +
        '<option value="2"' + (pattern===2?' selected':'') + '>2 — 1 row  (+arrow_up/down/left/right)</option>' +
        '</select></div>' +
        '<div class="form-group"><label>is_day</label>' +
        '<select id="table_' + i + '_isday"><option value="true">true (day)</option><option value="false">false (night)</option></select></div>' +
        '<div id="table_' + i + '_rows">' + rowsHTML + '</div>' +
        '<button onclick="testTable(' + i + ')">Test Send</button>' +
        '<div id="table_' + i + '_result" class="result"></div>';
}

// ─── add / remove table ───────────────────────────────────────────────────────
function addTable() {
    const container = document.getElementById("tables_container");
    const i = tablesCount++;
    const div = document.createElement("div");
    div.className = "table-block";
    div.id = "table_" + i;
    div.innerHTML = buildTableHTML(i, '', 8090, 0);
    container.appendChild(div);
    if (lastMPGSData) {
        for (let j = 1; j <= 4; j++) updateRowCheckboxes(i, j, lastMPGSData);
    }
}

function removeTable(i) {
    const elem = document.getElementById("table_" + i);
    if (elem) elem.remove();
}

// ─── test table send ──────────────────────────────────────────────────────────
function testTable(i) {
    const patternEl = document.getElementById("table_" + i + "_pattern");
    const pattern   = patternEl ? parseInt(patternEl.value) : 0;
    const maxRows   = PATTERN_MAX_ROWS[pattern] || 4;

    if (lastMPGSData && lastMPGSData.spaces) {
        for (let j = 1; j <= maxRows; j++) {
            const textElem = document.getElementById("table_" + i + "_row" + j + "_text");
            if (!textElem) continue;
            const sz = getCheckedValues(i, j, 'zone');
            const sf = getCheckedValues(i, j, 'floor');
            if (sz.length > 0 || sf.length > 0) {
                let free = 0;
                lastMPGSData.spaces.forEach(function(space) {
                    if (space.parkingSpaceStatus === 0) {
                        const zm = sz.length === 0 || sz.includes(space.belongArea || 'unknown');
                        const fm = sf.length === 0 || sf.includes(space.mapName    || 'unknown');
                        if (zm && fm) free++;
                    }
                });
                textElem.value = free;
            }
        }
    }

    const data = {
        ip:      document.getElementById("table_" + i + "_ip").value,
        port:    parseInt(document.getElementById("table_" + i + "_port").value),
        pattern: pattern,
        is_day:  document.getElementById("table_" + i + "_isday").value === "true"
    };

    let hasAnyRow = false;
    for (let j = 1; j <= maxRows; j++) {
        const textElem = document.getElementById("table_" + i + "_row" + j + "_text");
        const imgElem  = document.getElementById("table_" + i + "_row" + j + "_img");
        const textVal  = textElem ? textElem.value.trim() : "";
        const imgVal   = imgElem  ? imgElem.value : "";
        const sz = getCheckedValues(i, j, 'zone');
        const sf = getCheckedValues(i, j, 'floor');
        if ((sz.length > 0 || sf.length > 0) && textVal !== "") {
            data["row" + j] = {text: textVal, img: imgVal};
            hasAnyRow = true;
        }
    }

    if (!hasAnyRow) {
        document.getElementById("table_" + i + "_result").innerHTML =
            "<pre style='color:orange'>No rows to send (no checkboxes selected)</pre>";
        return;
    }

    document.getElementById("table_" + i + "_result").innerHTML = "<pre>Sending...</pre>";
    fetch("/api/test-table", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(data)})
    .then(r => r.json())
    .then(function(result) {
        let html = "";
        if (result.success) {
            html += "<div class='stat-card'><div class='value' style='color:green'>OK</div><div class='label'>" + result.elapsed_ms + "ms</div></div>";
            html += "<pre>Response: " + result.response + "</pre>";
        } else {
            html += "<div class='stat-card'><div class='value' style='color:red'>FAIL</div><div class='label'>" + result.elapsed_ms + "ms</div></div>";
            html += "<pre>Error: " + (result.error || "status " + result.status) + "</pre>";
        }
        html += "<pre>Payload sent:\n" + JSON.stringify(JSON.parse(result.payload), null, 2) + "</pre>";
        document.getElementById("table_" + i + "_result").innerHTML = html;
    });
}

// ─── save config ──────────────────────────────────────────────────────────────
function collectConfig() {
    const tables = [];
    for (let i = 0; i < tablesCount; i++) {
        const ipElem = document.getElementById("table_" + i + "_ip");
        if (!ipElem) continue;
        const patternEl = document.getElementById("table_" + i + "_pattern");
        const pattern   = patternEl ? parseInt(patternEl.value) : 0;
        const maxRows   = PATTERN_MAX_ROWS[pattern] || 4;
        const table = {
            ip: ipElem.value,
            port: parseInt(document.getElementById("table_" + i + "_port").value),
            mode: "push",
            pattern: pattern
        };
        for (let j = 1; j <= maxRows; j++) {
            const textElem = document.getElementById("table_" + i + "_row" + j + "_text");
            const imgElem  = document.getElementById("table_" + i + "_row" + j + "_img");
            const textVal  = textElem ? textElem.value.trim() : "";
            const imgVal   = imgElem  ? imgElem.value : "";
            const sz = getCheckedValues(i, j, 'zone');
            const sf = getCheckedValues(i, j, 'floor');
            if ((sz.length > 0 || sf.length > 0) && textVal !== "") {
                table["row" + j] = {text: textVal, img: imgVal, zones: sz, floors: sf};
            }
        }
        tables.push(table);
    }
    return {
        mpgs: {
            base_url:    document.getElementById("mpgs_url").value,
            key:         document.getElementById("mpgs_key").value,
            secret:      document.getElementById("mpgs_secret").value,
            version:     "V3.6.0",
            timeout_sec: parseInt(document.getElementById("mpgs_timeout").value)
        },
        navigation:   {url: "http://navi.internal/update", timeout_sec: 2},
        location:     {lat: 55.7558, lon: 37.6173},
        log_level:    "debug",
        sunrise_hour: parseInt(document.getElementById("sunrise_hour").value),
        sunset_hour:  parseInt(document.getElementById("sunset_hour").value),
        tables:       tables
    };
}

function saveConfig() {
    fetch("/api/save-config", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(collectConfig())})
    .then(r => r.json())
    .then(result => {
        document.getElementById("save_result").innerHTML = "<pre>" + JSON.stringify(result, null, 2) + "</pre>";
    });
}

function saveDayNight() {
    fetch("/api/save-config", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(collectConfig())})
    .then(r => r.json())
    .then(result => {
        document.getElementById("daynight_result").innerHTML = "<pre>" + JSON.stringify(result, null, 2) + "</pre>";
    });
}

// ─── restore saved checkboxes after MPGS load ────────────────────────────────
function loadSavedCheckboxes() {
    if (!lastMPGSData) { setTimeout(loadSavedCheckboxes, 1000); return; }
    const savedTables = %s;
    if (!savedTables || savedTables.length === 0) return;
    for (let i = 0; i < savedTables.length; i++) {
        const table   = savedTables[i];
        const pattern = table.pattern || 0;
        const maxRows = PATTERN_MAX_ROWS[pattern] || 4;
        for (let j = 1; j <= maxRows; j++) {
            const row = table['row' + j];
            if (!row) continue;
            const textElem = document.getElementById('table_' + i + '_row' + j + '_text');
            const imgElem  = document.getElementById('table_' + i + '_row' + j + '_img');
            if (textElem && row.text) textElem.value = row.text;
            if (imgElem  && row.img)  imgElem.value  = row.img;
            if (row.zones)  row.zones.forEach(z => { const cb = document.querySelector('.table_' + i + '_row' + j + '_zone[value="'  + z + '"]'); if (cb) cb.checked = true; });
            if (row.floors) row.floors.forEach(f => { const cb = document.querySelector('.table_' + i + '_row' + j + '_floor[value="' + f + '"]'); if (cb) cb.checked = true; });
            updateRowValue(i, j);
        }
    }
}

// ─── boot ─────────────────────────────────────────────────────────────────────
testMPGS();
setTimeout(loadSavedCheckboxes, 3000);
</script>
</body>
</html>`,
        cfg.MPGS.BaseURL, len(cfg.Tables),
        cfg.MPGS.BaseURL, cfg.MPGS.Timeout,
        cfg.MPGS.Key, cfg.MPGS.Secret,
        tablesHTML,
        cfg.SunriseHour, cfg.SunsetHour,
        len(cfg.Tables),
        savedTablesJSON(cfg))
}

// buildTableBlockHTML renders one saved table block (server-side, on page load).
func buildTableBlockHTML(i int, t TableConfig) string {
    patternOptions := ""
    for _, p := range []int{0, 1, 2} {
        label := map[int]string{
            0: "0 — 4 rows (car/ecar/moto/2car)",
            1: "1 — 3 rows (car/ecar/moto/2car)",
            2: "2 — 1 row  (+arrow_up/down/left/right)",
        }[p]
        sel := ""
        if p == t.Pattern {
            sel = " selected"
        }
        patternOptions += fmt.Sprintf(`<option value="%d"%s>%s</option>`, p, sel, label)
    }

    maxRows := maxRowsForPattern(t.Pattern)
    imgForPattern := func(pattern int) []string {
        if pattern == 2 {
            return []string{"car", "ecar", "moto", "2car", "arrow_up", "arrow_down", "arrow_left", "arrow_right"}
        }
        return []string{"car", "ecar", "moto", "2car"}
    }

    buildImgSel := func(id, selected string, pattern int) string {
        html := fmt.Sprintf(`<select id="%s">`, id)
        for _, img := range imgForPattern(pattern) {
            s := ""
            if img == selected {
                s = " selected"
            }
            html += fmt.Sprintf(`<option value="%s"%s>%s</option>`, img, s, img)
        }
        html += `</select>`
        return html
    }

    rows := []*RowConfig{t.Row1, t.Row2, t.Row3, t.Row4}
    rowsHTML := ""
    for j := 1; j <= 4; j++ {
        hiddenClass := ""
        if j > maxRows {
            hiddenClass = " hidden"
        }
        var textVal, imgVal string
        if j <= len(rows) && rows[j-1] != nil {
            textVal = rows[j-1].Text
            imgVal = rows[j-1].Img
        }
        imgID := fmt.Sprintf("table_%d_row%d_img", i, j)
        rowsHTML += fmt.Sprintf(`
<div class="row-data%s" id="table_%d_row%d_container">
    <strong>Row %d:</strong>
    <button class="remove-btn danger" onclick="clearRow(%d,%d)" style="padding:2px 8px;font-size:12px">X</button>
    Text: <input id="table_%d_row%d_text" value="%s" style="width:80px" placeholder="0" type="number">
    Img: %s
    <div style="margin-top:5px">
        <strong>Zones:</strong> <span id="table_%d_row%d_zones_display">-</span>&nbsp;
        <strong>Floors:</strong> <span id="table_%d_row%d_floors_display">-</span>
    </div>
    <div class="checkbox-group">
        <div id="table_%d_row%d_zonecheckboxes">Zones: no data</div>
        <div id="table_%d_row%d_floorcheckboxes">Floors: no data</div>
    </div>
    <button onclick="updateRowValue(%d,%d)" style="background:#ff9800;padding:5px 10px;font-size:12px">Update from MPGS</button>
</div>`,
            hiddenClass,
            i, j, j,
            i, j,
            i, j, textVal, buildImgSel(imgID, imgVal, t.Pattern),
            i, j, i, j,
            i, j, i, j,
            i, j,
        )
    }

    return fmt.Sprintf(`
<div class="table-block" id="table_%d">
    <button class="remove-btn danger" onclick="removeTable(%d)">X</button>
    <h3>Table %d</h3>
    <div class="row">
        <div class="col"><label>IP</label><input id="table_%d_ip" value="%s"></div>
        <div class="col"><label>Port</label><input id="table_%d_port" value="%d" type="number"></div>
    </div>
    <div class="form-group">
        <label>Pattern</label>
        <select id="table_%d_pattern" onchange="onPatternChange(%d)">%s</select>
    </div>
    <div class="form-group">
        <label>is_day</label>
        <select id="table_%d_isday">
            <option value="true">true (day)</option>
            <option value="false">false (night)</option>
        </select>
    </div>
    <div id="table_%d_rows">%s</div>
    <button onclick="testTable(%d)">Test Send</button>
    <div id="table_%d_result" class="result"></div>
</div>`,
        i, i, i,
        i, t.IP,
        i, t.Port,
        i, i, patternOptions,
        i,
        i, rowsHTML,
        i, i,
    )
}

func (ws *WebServer) handleTestMPGS(w http.ResponseWriter, r *http.Request) {
    if r.Method != "POST" { http.Error(w, "Method not allowed", 405); return }

    var req struct {
        BaseURL string `json:"base_url"`
        Key     string `json:"key"`
        Secret  string `json:"secret"`
        Version string `json:"version"`
        Timeout int    `json:"timeout"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        respondJSON(w, map[string]interface{}{"error": err.Error()}); return
    }
    if req.Timeout == 0 { req.Timeout = 5 }
    if req.Version == "" { req.Version = "V3.6.0" }

    f := NewMPGSFetcher(req.BaseURL, req.Key, req.Secret, req.Version, req.Timeout)
    ctx, cancel := context.WithTimeout(r.Context(), time.Duration(req.Timeout)*time.Second)
    defer cancel()

    startTime := time.Now()
    data, err := f.Fetch(ctx)
    elapsed := time.Since(startTime)

    result := map[string]interface{}{"elapsed_ms": elapsed.Milliseconds(), "success": err == nil}
    if err != nil {
        result["error"] = err.Error()
    } else {
        zones  := make(map[string]map[string]int)
        floors := make(map[string]map[string]int)
        totalFree, totalOccupied := 0, 0
        for _, space := range data {
            zone := space.BelongArea; if zone == "" { zone = "unknown" }
            if _, ok := zones[zone]; !ok { zones[zone] = map[string]int{"free": 0, "occupied": 0, "total": 0} }
            zones[zone]["total"]++
            floor := space.MapName; if floor == "" { floor = "unknown" }
            if _, ok := floors[floor]; !ok { floors[floor] = map[string]int{"free": 0, "occupied": 0, "total": 0} }
            floors[floor]["total"]++
            if space.ParkingSpaceStatus == 0 {
                zones[zone]["free"]++; floors[floor]["free"]++; totalFree++
            } else {
                zones[zone]["occupied"]++; floors[floor]["occupied"]++; totalOccupied++
            }
        }
        result["total_spaces"] = len(data)
        result["total_free"]   = totalFree
        result["total_occupied"] = totalOccupied
        result["zones"]  = zones
        result["floors"] = floors
        result["spaces"] = data
    }
    respondJSON(w, result)
}

func (ws *WebServer) handleTestTable(w http.ResponseWriter, r *http.Request) {
    if r.Method != "POST" { http.Error(w, "Method not allowed", 405); return }

    var req struct {
        IP      string `json:"ip"`
        Port    int    `json:"port"`
        Pattern int    `json:"pattern"`
        IsDay   bool   `json:"is_day"`
        Row1    *struct{ Text string `json:"text"`; Img string `json:"img"` } `json:"row1"`
        Row2    *struct{ Text string `json:"text"`; Img string `json:"img"` } `json:"row2"`
        Row3    *struct{ Text string `json:"text"`; Img string `json:"img"` } `json:"row3"`
        Row4    *struct{ Text string `json:"text"`; Img string `json:"img"` } `json:"row4"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        respondJSON(w, map[string]interface{}{"error": err.Error()}); return
    }

    // Enforce pattern constraints server-side
    maxRows := maxRowsForPattern(req.Pattern)
    if maxRows < 4 { req.Row4 = nil }
    if maxRows < 3 { req.Row3 = nil }
    if maxRows < 2 { req.Row2 = nil }

    payload := map[string]interface{}{
        "type": "strs", "version": 1,
        "datetime": time.Now().Unix(),
        "pattern":  req.Pattern,
        "is_day":   req.IsDay,
    }
    if req.Row1 != nil { payload["str1"] = req.Row1 }
    if req.Row2 != nil { payload["str2"] = req.Row2 }
    if req.Row3 != nil { payload["str3"] = req.Row3 }
    if req.Row4 != nil { payload["str4"] = req.Row4 }

    payloadJSON, _ := json.Marshal(payload)
    url := fmt.Sprintf("http://%s:%d/places", req.IP, req.Port)
    client := &http.Client{Timeout: 5 * time.Second}
    startTime := time.Now()
    httpReq, _ := http.NewRequest("POST", url, strings.NewReader(string(payloadJSON)))
    httpReq.Header.Set("Content-Type", "application/json")
    httpReq.Header.Set("Connection", "close")

    resp, err := client.Do(httpReq)
    elapsed := time.Since(startTime)
    result := map[string]interface{}{
        "url": url, "payload": string(payloadJSON),
        "elapsed_ms": elapsed.Milliseconds(),
        "success":    err == nil && resp != nil && resp.StatusCode == 200,
    }
    if err != nil {
        result["error"] = err.Error()
    } else {
        result["status"] = resp.StatusCode
        body, _ := io.ReadAll(resp.Body)
        resp.Body.Close()
        result["response"] = string(body)
    }
    respondJSON(w, result)
}

func (ws *WebServer) handleSaveConfig(w http.ResponseWriter, r *http.Request) {
    if r.Method != "POST" { http.Error(w, "Method not allowed", 405); return }

    var newCfg Config
    if err := json.NewDecoder(r.Body).Decode(&newCfg); err != nil {
        respondJSON(w, map[string]interface{}{"error": "Invalid JSON: " + err.Error()}); return
    }

    // Strip rows that exceed the pattern limit before validating / saving
    for idx := range newCfg.Tables {
        t := &newCfg.Tables[idx]
        maxRows := maxRowsForPattern(t.Pattern)
        if maxRows < 4 { t.Row4 = nil }
        if maxRows < 3 { t.Row3 = nil }
        if maxRows < 2 { t.Row2 = nil }
    }

    if err := newCfg.Validate(); err != nil {
        respondJSON(w, map[string]interface{}{"error": "Validation: " + err.Error()}); return
    }

    data, err := json.MarshalIndent(newCfg, "", "  ")
    if err != nil { respondJSON(w, map[string]interface{}{"error": "Marshal: " + err.Error()}); return }
    if err := os.WriteFile(ws.cfgPath, data, 0644); err != nil {
        respondJSON(w, map[string]interface{}{"error": "Write: " + err.Error()}); return
    }

    go func() {
        time.Sleep(1 * time.Second)
        cfg := Get()
        if cfg == nil { return }
        f := NewMPGSFetcher(cfg.MPGS.BaseURL, cfg.MPGS.Key, cfg.MPGS.Secret, cfg.MPGS.Version, cfg.MPGS.Timeout)
        ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.MPGS.Timeout)*time.Second)
        defer cancel()
        spaces, err := f.Fetch(ctx)
        if err != nil { log.Error().Err(err).Msg("MPGS fetch after config save failed"); return }
        zoneFree  := make(map[string]int)
        floorFree := make(map[string]int)
        for _, s := range spaces {
            if s.ParkingSpaceStatus == 0 {
                z := s.BelongArea; if z == "" { z = "unknown" }; zoneFree[z]++
                fl := s.MapName;   if fl == "" { fl = "unknown" }; floorFree[fl]++
            }
        }
        for _, table := range cfg.Tables {
            if table.Mode != "push" { continue }
            maxRows := maxRowsForPattern(table.Pattern)
            payload := map[string]interface{}{
                "type": "strs", "version": 1,
                "datetime": time.Now().Unix(),
                "pattern":  table.Pattern,
                "is_day":   isDaytime(),
            }
            rowPtrs := []*RowConfig{table.Row1, table.Row2, table.Row3, table.Row4}
            strKeys := []string{"str1", "str2", "str3", "str4"}
            for j := 0; j < maxRows; j++ {
                rp := rowPtrs[j]
                if rp == nil || (len(rp.Zones) == 0 && len(rp.Floors) == 0) { continue }
                cnt := countFreeSpaces(zoneFree, floorFree, rp.Zones, rp.Floors)
                payload[strKeys[j]] = map[string]string{"text": fmt.Sprintf("%d", cnt), "img": rp.Img}
            }
            payloadJSON, _ := json.Marshal(payload)
            url := fmt.Sprintf("http://%s:%d/places", table.IP, table.Port)
            client := &http.Client{Timeout: 5 * time.Second}
            httpReq, _ := http.NewRequest("POST", url, strings.NewReader(string(payloadJSON)))
            httpReq.Header.Set("Content-Type", "application/json")
            httpReq.Header.Set("Connection", "close")
            resp, err := client.Do(httpReq)
            if err != nil {
                log.Error().Err(err).Str("ip", table.IP).Msg("Send after config save failed")
            } else {
                body, _ := io.ReadAll(resp.Body); resp.Body.Close()
                log.Info().Str("ip", table.IP).Int("status", resp.StatusCode).Str("response", string(body)).Msg("Sent to table after config save")
            }
        }
    }()

    respondJSON(w, map[string]interface{}{
        "success": true,
        "message": "Config saved. MPGS fetch and table update triggered.",
    })
}

func respondJSON(w http.ResponseWriter, data interface{}) {
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(data)
}
WEBEOF
    print_success "web.go создан"

    print_success "Все файлы проекта созданы"
}

###############################################################################
# Шаг 7: Компиляция
###############################################################################

build_project() {
    print_step "Компиляция проекта"

    cd "$PROJECT_DIR"

    print_status "Загрузка зависимостей..."
    go mod tidy >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        print_warning "Проблемы с загрузкой зависимостей, пробуем с прокси..."
        go env -w GOPROXY=https://goproxy.io,direct
        go mod tidy >> "$LOG_FILE" 2>&1
    fi
    print_success "Зависимости загружены"

    print_status "Очистка кэша..."
    go clean -cache >> "$LOG_FILE" 2>&1
    print_success "Кэш очищен"

    print_status "Компиляция..."
    CGO_ENABLED=0 go build -o "$PROJECT_DIR/$SERVICE_NAME" . >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        print_error "Ошибка компиляции. Лог:"
        tail -20 "$LOG_FILE"
        exit 1
    fi

    chmod +x "$PROJECT_DIR/$SERVICE_NAME"
    print_success "Скомпилирован: $PROJECT_DIR/$SERVICE_NAME ($(ls -lh $PROJECT_DIR/$SERVICE_NAME | awk '{print $5}'))"
}

###############################################################################
# Шаг 8: Создание конфигурации
###############################################################################

create_config() {
    print_step "Создание конфигурации"

    cat > "$CONFIG_DIR/config.json" << EOF
{
  "mpgs": {
    "base_url": "${MPGS_BASE_URL}",
    "key": "${MPGS_KEY}",
    "secret": "${MPGS_SECRET}",
    "version": "${MPGS_VERSION}",
    "timeout_sec": 2
  },
  "navigation": {
    "url": "http://navi.internal/update",
    "timeout_sec": 2
  },
  "location": {
    "lat": 55.7558,
    "lon": 37.6173
  },
  "log_level": "info",
  "sunrise_hour": 7,
  "sunset_hour": 18,
  "tables": [
    {
      "ip": "${TABLE1_IP}",
      "port": ${TABLE1_PORT},
      "mode": "push",
      "pattern": 0,
      "row1": {"text": "", "img": "car",  "zones": [], "floors": []},
      "row2": {"text": "", "img": "ecar", "zones": [], "floors": []},
      "row3": {"text": "", "img": "moto", "zones": [], "floors": []},
      "row4": {"text": "", "img": "2car", "zones": [], "floors": []}
    }
  ]
}
EOF

    print_success "Конфигурация создана: $CONFIG_DIR/config.json"
}

###############################################################################
# Шаг 9: Создание systemd-сервиса
###############################################################################

create_service() {
    print_step "Создание systemd-сервиса"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Parking Proxy Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${PROJECT_DIR}
ExecStart=${PROJECT_DIR}/${SERVICE_NAME} -config=${CONFIG_DIR}/config.json -web=:${WEB_PORT}
Restart=always
RestartSec=10
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "Сервис создан"
}

###############################################################################
# Шаг 10: Проверка файрвола
###############################################################################

check_firewall() {
    print_step "Проверка файрвола"

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        print_status "Настройка firewalld для порта ${WEB_PORT}..."
        firewall-cmd --add-port=${WEB_PORT}/tcp --permanent >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
        print_success "Порт ${WEB_PORT} открыт"
    else
        print_info "Файрвол не активен"
    fi
}

###############################################################################
# Шаг 11: Запуск сервиса
###############################################################################

start_service() {
    print_step "Запуск сервиса"

    print_status "Включение автозапуска..."
    systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1
    print_success "Автозапуск включен"

    print_status "Запуск сервиса..."
    systemctl start "$SERVICE_NAME" >> "$LOG_FILE" 2>&1

    sleep 3

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "Сервис запущен"
    else
        print_error "Сервис не запустился"
        print_info "Статус:"
        systemctl status "$SERVICE_NAME" --no-pager -l
        print_info "Логи:"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
        exit 1
    fi
}

###############################################################################
# Шаг 12: Создание скриптов обслуживания
###############################################################################

create_scripts() {
    print_step "Создание скриптов обслуживания"

    cat > "$PROJECT_DIR/check.sh" << 'CHECKEOF'
#!/bin/bash
echo "=== Parking Proxy Diagnostics ==="
echo ""
echo "Service Status:"
systemctl status parking-proxy --no-pager -l | head -15
echo ""
echo "Last 30 log entries:"
journalctl -u parking-proxy -n 30 --no-pager
echo ""
echo "Process:"
ps aux | grep parking-proxy | grep -v grep
CHECKEOF
    chmod +x "$PROJECT_DIR/check.sh"

    cat > "$PROJECT_DIR/restart.sh" << 'RESTARTEOF'
#!/bin/bash
systemctl restart parking-proxy
sleep 2
journalctl -u parking-proxy -n 15 --no-pager
RESTARTEOF
    chmod +x "$PROJECT_DIR/restart.sh"

    cat > "$PROJECT_DIR/logs.sh" << 'LOGSEOF'
#!/bin/bash
journalctl -u parking-proxy -f
LOGSEOF
    chmod +x "$PROJECT_DIR/logs.sh"

    print_success "Скрипты созданы: check.sh, restart.sh, logs.sh"
}

###############################################################################
# Финальный вывод
###############################################################################

show_summary() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}  УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
    echo "============================================="
    echo ""
    echo -e "${CYAN}Расположение:${NC}"
    echo "  Проект:    $PROJECT_DIR"
    echo "  Конфиг:    $CONFIG_DIR/config.json"
    echo "  Логи:      journalctl -u $SERVICE_NAME"
    echo ""
    echo -e "${CYAN}Управление:${NC}"
    echo "  Статус:    systemctl status $SERVICE_NAME"
    echo "  Логи:      $PROJECT_DIR/logs.sh"
    echo "  Проверка:  $PROJECT_DIR/check.sh"
    echo "  Перезапуск: $PROJECT_DIR/restart.sh"
    echo "  Веб:       http://$(hostname -I | awk '{print $1}'):${WEB_PORT}"
    echo ""
    echo -e "${CYAN}Конфигурация:${NC}"
    echo "  MPGS:      $MPGS_BASE_URL"
    echo "  Табло:     $TABLE1_IP:$TABLE1_PORT"
    echo ""
    echo -e "${YELLOW}Изменение настроек:${NC}"
    echo "  $CONFIG_DIR/config.json (применяются автоматически)"
    echo ""
    echo "Последние логи:"
    journalctl -u "$SERVICE_NAME" -n 10 --no-pager
}

###############################################################################
# Главная функция
###############################################################################

main() {
    clear
    echo ""
    echo "============================================="
    echo "  Parking Proxy Installation Script v4.1.0"
    echo "============================================="
    echo ""

    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR" || exit 1

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Installation started at $(date) ===" > "$LOG_FILE"

    check_system
    configure_repos
    install_deps
    install_golang
    create_structure
    create_files
    build_project
    create_config
    create_service
    check_firewall
    start_service
    create_scripts
    show_summary

    echo ""
    echo "Лог установки: $LOG_FILE"
}

trap 'echo -e "\n${RED}Установка прервана${NC}"; exit 1' INT TERM

main "$@"
