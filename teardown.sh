#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# ローカルAIシステム 停止・削除スクリプト
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

DELETE_VOLUMES=false
DELETE_IMAGES=false

usage() {
    echo "使い方: $0 [オプション]"
    echo ""
    echo "オプション:"
    echo "  (なし)      コンテナを停止（データは保持）"
    echo "  --volumes   コンテナ停止 + データ削除（モデル・DBを含む）"
    echo "  --images    Dockerイメージも削除"
    echo "  --full      --volumes + --images（完全リセット）"
    echo "  -h, --help  このヘルプを表示"
}

for arg in "$@"; do
    case "$arg" in
        --volumes) DELETE_VOLUMES=true ;;
        --images)  DELETE_IMAGES=true ;;
        --full)    DELETE_VOLUMES=true; DELETE_IMAGES=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "不明なオプション: $arg"; usage; exit 1 ;;
    esac
done

echo ""
echo -e "${YELLOW}コンテナを停止します...${NC}"
docker compose down

if $DELETE_VOLUMES; then
    echo ""
    echo -e "${RED}警告: data/ ディレクトリ（モデルキャッシュ・Open WebUIデータ）を削除します。${NC}"
    echo "この操作は取り消せません。続行しますか？ (yes/N)"
    read -r confirm
    if [ "$confirm" = "yes" ]; then
        rm -rf data/ollama data/open-webui
        echo -e "${GREEN}データを削除しました${NC}"
    else
        echo "データ削除をキャンセルしました"
    fi
fi

if $DELETE_IMAGES; then
    echo ""
    echo "Dockerイメージを削除中..."
    docker rmi ollama/ollama:latest ghcr.io/open-webui/open-webui:main 2>/dev/null || true
    echo -e "${GREEN}イメージを削除しました${NC}"
fi

echo ""
echo -e "${GREEN}完了しました${NC}"
echo "再起動する場合: ./setup.sh"
