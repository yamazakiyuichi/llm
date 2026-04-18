#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# ローカルAIシステム セットアップスクリプト
# Ollama + Open WebUI 一括初期設定
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

# ── フェーズ1: 前提確認 ─────────────────────────────────────────
phase1_preflight() {
    echo ""
    info "=== フェーズ1: 前提確認 ==="

    local missing=0

    for cmd in docker curl python3; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd が見つかりました"
        else
            error "$cmd がインストールされていません"
            missing=$((missing + 1))
        fi
    done

    # docker compose (plugin形式) の確認
    if docker compose version &>/dev/null 2>&1; then
        success "docker compose (plugin) が見つかりました"
    else
        error "docker compose plugin が見つかりません。Docker Desktop または docker-compose-plugin をインストールしてください"
        missing=$((missing + 1))
    fi

    # Dockerデーモンの確認
    if docker info &>/dev/null 2>&1; then
        success "Dockerデーモンが起動しています"
    else
        error "Dockerデーモンに接続できません。'sudo systemctl start docker' を実行してください"
        missing=$((missing + 1))
    fi

    # ディスク空き容量確認（最低20GB推奨）
    local free_gb
    free_gb=$(df -BG "$SCRIPT_DIR" | awk 'NR==2 {gsub("G",""); print $4}')
    if [ "$free_gb" -ge 20 ]; then
        success "ディスク空き容量: ${free_gb}GB（十分です）"
    else
        warn "ディスク空き容量: ${free_gb}GB（推奨: 20GB以上。モデルダウンロード時に不足する可能性があります）"
    fi

    # RAM確認
    local ram_gb
    ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    if [ "$ram_gb" -ge 16 ]; then
        success "RAM: ${ram_gb}GB（7Bモデル動作可能）"
    elif [ "$ram_gb" -ge 8 ]; then
        warn "RAM: ${ram_gb}GB（3B/7B Q4モデルまで推奨）"
    else
        warn "RAM: ${ram_gb}GB（3Bモデルのみ推奨）"
    fi

    # GPU確認（なくても動作可能）
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        success "NVIDIA GPU 検出。docker-compose.override.yml のGPU設定を有効化することでより高速に動作します"
    else
        info "GPU未検出（CPU-onlyモードで動作します）"
    fi

    if [ "$missing" -gt 0 ]; then
        error "$missing 個の必須ツールが不足しています。インストール後に再実行してください"
        exit 1
    fi
}

# ── フェーズ2: 環境設定 ─────────────────────────────────────────
phase2_env_setup() {
    echo ""
    info "=== フェーズ2: 環境設定 ==="

    if [ ! -f ".env" ]; then
        cp .env.example .env
        info ".env.example から .env を作成しました"
    else
        info ".env が既に存在します（スキップ）"
    fi

    # SECRET_KEYが未設定の場合は自動生成
    if grep -q "change_me_before_first_run" .env; then
        local secret
        secret=$(python3 -c "import secrets; print(secrets.token_hex(24))")
        sed -i "s/change_me_before_first_run/$secret/" .env
        success "WEBUI_SECRET_KEY を自動生成しました"
    fi

    # 必要ディレクトリ作成
    local dirs=(
        "data/ollama"
        "data/open-webui"
        "models"
        "rapport"
        "logs"
        "scripts"
    )
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
    done
    success "必要なディレクトリを作成しました"
}

# ── フェーズ3: コンテナ起動 ─────────────────────────────────────
phase3_docker_start() {
    echo ""
    info "=== フェーズ3: Dockerコンテナ起動 ==="

    info "最新イメージを取得中..."
    if docker compose pull; then
        success "イメージ取得完了"
    else
        error "イメージ取得に失敗しました。ネットワーク接続を確認してください"
        exit 2
    fi

    info "コンテナを起動中..."
    docker compose up -d

    # Ollamaのヘルスチェック待機（最大90秒）
    info "Ollamaの起動を待機中..."
    local count=0
    until curl -sf "http://localhost:${OLLAMA_PORT:-11434}/api/tags" &>/dev/null; do
        count=$((count + 1))
        if [ "$count" -ge 30 ]; then
            error "Ollamaが起動しませんでした（タイムアウト90秒）"
            docker compose logs ollama | tail -20
            exit 2
        fi
        sleep 3
    done
    success "Ollama が起動しました"

    # Open WebUIのヘルスチェック待機（最大120秒）
    info "Open WebUIの起動を待機中..."
    count=0
    until curl -sf "http://localhost:${WEBUI_PORT:-3000}/health" &>/dev/null; do
        count=$((count + 1))
        if [ "$count" -ge 40 ]; then
            warn "Open WebUIの起動確認がタイムアウトしました（後で http://localhost:${WEBUI_PORT:-3000} にアクセスしてください）"
            break
        fi
        sleep 3
    done
    if [ "$count" -lt 40 ]; then
        success "Open WebUI が起動しました"
    fi
}

# ── フェーズ4: モデル取得 ─────────────────────────────────────────
phase4_pull_models() {
    echo ""
    info "=== フェーズ4: Ollamaモデル取得 ==="

    # .envから値を読み込み
    # shellcheck source=/dev/null
    source .env

    local models_to_pull=(
        "${DEFAULT_CHAT_MODEL:-llama3.2:3b-instruct-q4_K_M}"
        "${DEFAULT_VISION_MODEL:-llava:7b-v1.6-mistral-q4_K_M}"
        "${RAG_EMBEDDING_MODEL:-nomic-embed-text:latest}"
    )

    if [ -n "${EXTRA_MODELS:-}" ]; then
        read -ra extra <<< "$EXTRA_MODELS"
        models_to_pull+=("${extra[@]}")
    fi

    for model in "${models_to_pull[@]}"; do
        if [ -z "$model" ]; then continue; fi
        info "モデルを取得中: $model（容量によっては数分〜数十分かかります）"
        if docker exec ollama ollama pull "$model"; then
            success "$model の取得完了"
        else
            warn "$model の取得に失敗しました（後で 'docker exec ollama ollama pull $model' で再試行可能）"
        fi
    done

    info "取得済みモデル一覧:"
    docker exec ollama ollama list
}

# ── フェーズ5: Python依存インストール ───────────────────────────
phase5_python_deps() {
    echo ""
    info "=== フェーズ5: Python依存関係のインストール ==="

    local pkgs=("mss" "Pillow" "requests")
    for pkg in "${pkgs[@]}"; do
        if python3 -c "import ${pkg,,}" &>/dev/null 2>&1; then
            success "Python: $pkg は既にインストール済み"
        else
            info "pip install: $pkg"
            pip3 install --user "$pkg" --quiet && success "Python: $pkg をインストールしました"
        fi
    done

    # scrot（スクリーンキャプチャ CLI）
    if command -v scrot &>/dev/null; then
        success "scrot が見つかりました"
    else
        info "scrotをインストール中..."
        if sudo apt-get install -y scrot &>/dev/null 2>&1; then
            success "scrot をインストールしました"
        else
            warn "scrot のインストールに失敗しました（ヘッドレス環境では --file オプションで代替可能）"
        fi
    fi
}

# ── フェーズ6: 完了メッセージ ─────────────────────────────────────
phase6_summary() {
    echo ""
    echo "================================================================"
    echo -e "${GREEN}  セットアップ完了！${NC}"
    echo "================================================================"
    echo ""
    echo "  Open WebUI: http://localhost:${WEBUI_PORT:-3000}"
    echo "    → 初回アクセス時に管理者アカウントを作成してください"
    echo ""
    echo "  Ollama API: http://localhost:${OLLAMA_PORT:-11434}"
    echo ""
    echo "  使い方:"
    echo "    スクリーンショット解析:"
    echo "      python3 scripts/screenshot_analyze.py --help"
    echo "      python3 scripts/screenshot_analyze.py --file /path/to/image.png"
    echo ""
    echo "    モデル切り替え:"
    echo "      python3 scripts/model_select.py"
    echo ""
    echo "    rapportデータ投入:"
    echo "      # rapport/ にPDF/DOCX/TXTを配置してから:"
    echo "      python3 scripts/import_rapport.py"
    echo ""
    echo "    GGUFモデル追加:"
    echo "      # models/ に .gguf ファイルを配置してから:"
    echo "      ./scripts/pull_models.sh --gguf /models/model.gguf --name my-model"
    echo ""
    echo "    停止:"
    echo "      ./teardown.sh"
    echo "================================================================"
}

# ── メイン実行 ───────────────────────────────────────────────────
main() {
    echo ""
    echo "================================================================"
    echo "  ローカルAI システム セットアップ"
    echo "  Ollama + Open WebUI"
    echo "================================================================"

    phase1_preflight
    phase2_env_setup
    phase3_docker_start
    phase4_pull_models
    phase5_python_deps
    phase6_summary
}

main "$@"
