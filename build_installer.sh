#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# セルフエクストラクト インストーラー ビルダー
# 実行すると local-ai-setup.sh を生成します
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/local-ai-setup.sh"
VERSION="1.0.0"
DATE="$(date +%Y-%m-%d)"

echo "インストーラーをビルド中..."

# 同梱するファイル一覧（data/, .git/ は除外）
INCLUDE_FILES=(
    ".env.example"
    ".gitignore"
    "docker-compose.yml"
    "docker-compose.override.yml"
    "setup.sh"
    "teardown.sh"
    "models/Modelfile.template"
    "models/.gitkeep"
    "rapport/.gitkeep"
    "logs/.gitkeep"
    "scripts/screenshot_analyze.py"
    "scripts/model_select.py"
    "scripts/import_rapport.py"
    "scripts/pull_models.sh"
)

# 一時ディレクトリでtarball作成
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ファイルをコピー（ディレクトリ構造を保持）
for f in "${INCLUDE_FILES[@]}"; do
    dir="$TMP_DIR/$(dirname "$f")"
    mkdir -p "$dir"
    cp "$SCRIPT_DIR/$f" "$TMP_DIR/$f"
done

# tar.gz として圧縮 → base64 エンコード
PAYLOAD="$(tar -czf - -C "$TMP_DIR" . | base64 -w 0)"

# ── インストーラースクリプトを生成 ───────────────────────────────
cat > "$OUTPUT" << INSTALLER_EOF
#!/usr/bin/env bash
# ================================================================
#  ローカルAI システム インストーラー v${VERSION}
#  Ollama + Open WebUI セットアップ
#  生成日: ${DATE}
#
#  使い方:
#    chmod +x local-ai-setup.sh
#    ./local-ai-setup.sh
#    ./local-ai-setup.sh --dir /opt/local-ai  # インストール先指定
#    ./local-ai-setup.sh --no-setup           # ファイル展開のみ
# ================================================================
set -euo pipefail

INSTALLER_VERSION="${VERSION}"
DEFAULT_INSTALL_DIR="\$HOME/local-ai"
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

info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }
warn()    { echo -e "\${YELLOW}[WARN]\${NC} \$*"; }
error()   { echo -e "\${RED}[ERR]\${NC}  \$*" >&2; }

usage() {
    cat << EOF
使い方: \$0 [オプション]

オプション:
  --dir PATH      インストール先ディレクトリ (デフォルト: \$HOME/local-ai)
  --no-setup      ファイル展開のみ（setup.sh を自動実行しない）
  --force         既存ディレクトリに上書きインストール
  -h, --help      このヘルプを表示

例:
  \$0                        # ホームディレクトリにインストール
  \$0 --dir /opt/local-ai    # 任意のパスにインストール
  \$0 --no-setup             # ファイル展開のみ（後で手動 setup.sh を実行）
EOF
}

for arg in "\$@"; do
    case "\$arg" in
        --dir)     shift; INSTALL_DIR="\$1"; shift ;;
        --no-setup) RUN_SETUP=false ;;
        --force)   FORCE=true ;;
        -h|--help) usage; exit 0 ;;
    esac
done

INSTALL_DIR="\${INSTALL_DIR:-\$DEFAULT_INSTALL_DIR}"

# ── バナー ───────────────────────────────────────────────────────
echo ""
echo -e "\${BOLD}================================================================\${NC}"
echo -e "\${BOLD}  ローカルAI システム インストーラー v\${INSTALLER_VERSION}\${NC}"
echo -e "\${BOLD}  Ollama + Open WebUI\${NC}"
echo -e "\${BOLD}================================================================\${NC}"
echo ""
echo "  インストール先: \$INSTALL_DIR"
echo ""

# ── 前提確認 ─────────────────────────────────────────────────────
missing=0
for cmd in docker curl python3; do
    if ! command -v "\$cmd" &>/dev/null; then
        error "\$cmd がインストールされていません"
        missing=\$((missing + 1))
    fi
done
if ! docker compose version &>/dev/null 2>&1; then
    error "docker compose plugin がインストールされていません"
    missing=\$((missing + 1))
fi
if [ "\$missing" -gt 0 ]; then
    echo ""
    error "\$missing 個の必須ツールが不足しています。インストール後に再実行してください。"
    echo ""
    echo "  Dockerインストール: https://docs.docker.com/engine/install/"
    exit 1
fi
success "前提ツールの確認完了"

# ── インストール先の確認 ──────────────────────────────────────────
if [ -d "\$INSTALL_DIR" ] && [ "\$FORCE" = false ]; then
    echo ""
    warn "ディレクトリが既に存在します: \$INSTALL_DIR"
    echo "上書きしますか？ (yes/N): "
    read -r confirm
    if [ "\$confirm" != "yes" ]; then
        echo "インストールをキャンセルしました"
        echo "--dir で別のパスを指定するか、--force オプションを使用してください"
        exit 0
    fi
fi

mkdir -p "\$INSTALL_DIR"

# ── ファイル展開 ──────────────────────────────────────────────────
info "ファイルを展開中..."

# このスクリプト内のペイロード（base64）を取得して展開
PAYLOAD_LINE=\$(grep -n "^#__PAYLOAD__" "\$0" | cut -d: -f1)
PAYLOAD_LINE=\$((PAYLOAD_LINE + 1))
tail -n +"\$PAYLOAD_LINE" "\$0" | base64 -d | tar -xzf - -C "\$INSTALL_DIR"

# 実行権限を付与
chmod +x "\$INSTALL_DIR/setup.sh" "\$INSTALL_DIR/teardown.sh" "\$INSTALL_DIR/scripts/pull_models.sh"

success "ファイルを展開しました: \$INSTALL_DIR"

# ── ファイル一覧表示 ──────────────────────────────────────────────
echo ""
echo "展開されたファイル:"
find "\$INSTALL_DIR" -type f | sort | while read -r f; do
    echo "  \${f#\$INSTALL_DIR/}"
done

# ── セットアップ実行 ──────────────────────────────────────────────
if \$RUN_SETUP; then
    echo ""
    info "セットアップを開始します..."
    cd "\$INSTALL_DIR"
    bash setup.sh
else
    echo ""
    echo -e "\${BOLD}次のステップ:\${NC}"
    echo "  cd \$INSTALL_DIR"
    echo "  cp .env.example .env    # 設定ファイルを作成"
    echo "  ./setup.sh              # セットアップ実行"
fi

exit 0
#__PAYLOAD__
INSTALLER_EOF

# ペイロードを追記
echo "$PAYLOAD" >> "$OUTPUT"

chmod +x "$OUTPUT"

SIZE="$(du -sh "$OUTPUT" | cut -f1)"
echo "インストーラーを生成しました: $OUTPUT ($SIZE)"
echo ""
echo "使い方:"
echo "  chmod +x local-ai-setup.sh"
echo "  ./local-ai-setup.sh"
echo "  ./local-ai-setup.sh --dir /opt/local-ai"
echo "  ./local-ai-setup.sh --no-setup  # 展開のみ"
