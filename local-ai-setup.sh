#!/usr/bin/env bash
# ================================================================
#  ローカルAI システム インストーラー v1.0.0
#  Ollama + Open WebUI セットアップ
#  生成日: 2026-04-18
#
#  使い方:
#    chmod +x local-ai-setup.sh
#    ./local-ai-setup.sh
#    ./local-ai-setup.sh --dir /opt/local-ai  # インストール先指定
#    ./local-ai-setup.sh --no-setup           # ファイル展開のみ
# ================================================================
set -euo pipefail

INSTALLER_VERSION="1.0.0"
DEFAULT_INSTALL_DIR="$HOME/local-ai"
INSTALL_DIR=""
RUN_SETUP=true
FORCE=false

# カラー出力
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

usage() {
    cat << EOF
使い方: $0 [オプション]

オプション:
  --dir PATH      インストール先ディレクトリ (デフォルト: $HOME/local-ai)
  --no-setup      ファイル展開のみ（setup.sh を自動実行しない）
  --force         既存ディレクトリに上書きインストール
  -h, --help      このヘルプを表示

例:
  $0                        # ホームディレクトリにインストール
  $0 --dir /opt/local-ai    # 任意のパスにインストール
  $0 --no-setup             # ファイル展開のみ（後で手動 setup.sh を実行）
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dir)     shift; INSTALL_DIR="$1"; shift ;;
        --no-setup) RUN_SETUP=false ;;
        --force)   FORCE=true ;;
        -h|--help) usage; exit 0 ;;
    esac
done

INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

# ── バナー ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  ローカルAI システム インストーラー v${INSTALLER_VERSION}${NC}"
echo -e "${BOLD}  Ollama + Open WebUI${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  インストール先: $INSTALL_DIR"
echo ""

# ── 前提確認 ─────────────────────────────────────────────────────
missing=0
for cmd in docker curl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        error "$cmd がインストールされていません"
        missing=$((missing + 1))
    fi
done
if ! docker compose version &>/dev/null 2>&1; then
    error "docker compose plugin がインストールされていません"
    missing=$((missing + 1))
fi
if [ "$missing" -gt 0 ]; then
    echo ""
    error "$missing 個の必須ツールが不足しています。インストール後に再実行してください。"
    echo ""
    echo "  Dockerインストール: https://docs.docker.com/engine/install/"
    exit 1
fi
success "前提ツールの確認完了"

# ── インストール先の確認 ──────────────────────────────────────────
if [ -d "$INSTALL_DIR" ] && [ "$FORCE" = false ]; then
    echo ""
    warn "ディレクトリが既に存在します: $INSTALL_DIR"
    echo "上書きしますか？ (yes/N): "
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        echo "インストールをキャンセルしました"
        echo "--dir で別のパスを指定するか、--force オプションを使用してください"
        exit 0
    fi
fi

mkdir -p "$INSTALL_DIR"

# ── ファイル展開 ──────────────────────────────────────────────────
info "ファイルを展開中..."

# このスクリプト内のペイロード（base64）を取得して展開
PAYLOAD_LINE=$(grep -n "^#__PAYLOAD__" "$0" | cut -d: -f1)
PAYLOAD_LINE=$((PAYLOAD_LINE + 1))
tail -n +"$PAYLOAD_LINE" "$0" | base64 -d | tar -xzf - -C "$INSTALL_DIR"

# 実行権限を付与
chmod +x "$INSTALL_DIR/setup.sh" "$INSTALL_DIR/teardown.sh" "$INSTALL_DIR/scripts/pull_models.sh"

success "ファイルを展開しました: $INSTALL_DIR"

# ── ファイル一覧表示 ──────────────────────────────────────────────
echo ""
echo "展開されたファイル:"
find "$INSTALL_DIR" -type f | sort | while read -r f; do
    echo "  ${f#$INSTALL_DIR/}"
done

# ── セットアップ実行 ──────────────────────────────────────────────
if $RUN_SETUP; then
    echo ""
    info "セットアップを開始します..."
    cd "$INSTALL_DIR"
    bash setup.sh
else
    echo ""
    echo -e "${BOLD}次のステップ:${NC}"
    echo "  cd $INSTALL_DIR"
    echo "  cp .env.example .env    # 設定ファイルを作成"
    echo "  ./setup.sh              # セットアップ実行"
fi

exit 0
#__PAYLOAD__
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
