#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# GGUFファイルをOllamaモデルとして登録するヘルパースクリプト
#
# 使い方:
#   ./scripts/pull_models.sh --gguf /models/my-model.gguf --name my-model
#   ./scripts/pull_models.sh --gguf /models/model.gguf --name chat-model --ctx 8192
#   ./scripts/pull_models.sh --gguf /models/model.gguf --name my-model --system "あなたは日本語専門のAIです"
#
# 手順:
#   1. HuggingFaceなどから .gguf ファイルをダウンロードして models/ に配置
#   2. このスクリプトを実行（Ollamaコンテナ内でモデルを登録）
#   3. python3 scripts/model_select.py で新しいモデルが選択可能になる
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GGUF_PATH=""
MODEL_NAME=""
CONTEXT_SIZE=4096
TEMPERATURE=0.7
SYSTEM_PROMPT=""
OLLAMA_CONTAINER="ollama"

usage() {
    cat << EOF
使い方: $0 --gguf <GGUFパス> --name <モデル名> [オプション]

必須:
  --gguf PATH      GGUFファイルのパス（Ollamaコンテナ内のパス: /models/以降）
  --name NAME      Ollamaで使用するモデル名

オプション:
  --ctx SIZE       コンテキストサイズ (デフォルト: 4096)
  --temp FLOAT     温度パラメータ (デフォルト: 0.7)
  --system TEXT    システムプロンプト
  --container NAME Ollamaコンテナ名 (デフォルト: ollama)
  -h, --help       このヘルプを表示

例:
  # models/ にファイルを配置してから実行（コンテナ内は /models/ にマウント）:
  $0 --gguf /models/llama-3-8b.Q4_K_M.gguf --name llama3-8b-q4

  $0 --gguf /models/mistral-7b.gguf --name mistral-custom \\
     --ctx 8192 --system "あなたは日本語専門のアシスタントです"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gguf)       GGUF_PATH="$2"; shift 2 ;;
        --name)       MODEL_NAME="$2"; shift 2 ;;
        --ctx)        CONTEXT_SIZE="$2"; shift 2 ;;
        --temp)       TEMPERATURE="$2"; shift 2 ;;
        --system)     SYSTEM_PROMPT="$2"; shift 2 ;;
        --container)  OLLAMA_CONTAINER="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "不明なオプション: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$GGUF_PATH" || -z "$MODEL_NAME" ]]; then
    echo "エラー: --gguf と --name は必須です"
    usage
    exit 1
fi

# Ollamaコンテナが起動しているか確認
if ! docker ps --filter "name=$OLLAMA_CONTAINER" --filter "status=running" | grep -q "$OLLAMA_CONTAINER"; then
    echo "エラー: Ollamaコンテナ '$OLLAMA_CONTAINER' が起動していません"
    echo "docker compose up -d を実行してください"
    exit 1
fi

# GGUFファイルの存在確認（コンテナ内）
if ! docker exec "$OLLAMA_CONTAINER" test -f "$GGUF_PATH" 2>/dev/null; then
    # ローカルパスからの変換を試みる
    GGUF_FILENAME="$(basename "$GGUF_PATH")"
    CONTAINER_PATH="/models/$GGUF_FILENAME"
    if ! docker exec "$OLLAMA_CONTAINER" test -f "$CONTAINER_PATH" 2>/dev/null; then
        echo "エラー: GGUFファイルが見つかりません"
        echo "  指定パス: $GGUF_PATH"
        echo "  コンテナ内: $CONTAINER_PATH"
        echo ""
        echo "GGUFファイルを models/ ディレクトリに配置してください:"
        echo "  cp /path/to/your-model.gguf $PROJECT_DIR/models/"
        exit 1
    fi
    GGUF_PATH="$CONTAINER_PATH"
fi

echo "GGUFファイル: $GGUF_PATH"
echo "モデル名: $MODEL_NAME"
echo "コンテキストサイズ: $CONTEXT_SIZE"

# Modelfileの内容を生成
MODELFILE_CONTENT="FROM $GGUF_PATH
PARAMETER num_ctx $CONTEXT_SIZE
PARAMETER temperature $TEMPERATURE
PARAMETER num_predict -1"

if [[ -n "$SYSTEM_PROMPT" ]]; then
    MODELFILE_CONTENT="$MODELFILE_CONTENT
SYSTEM \"$SYSTEM_PROMPT\""
fi

# Modelfileをコンテナ内に一時作成してモデルを登録
MODELFILE_TMP="/tmp/Modelfile.$MODEL_NAME"
echo "Modelfileを作成中..."
echo "$MODELFILE_CONTENT" | docker exec -i "$OLLAMA_CONTAINER" bash -c "cat > $MODELFILE_TMP"

echo "Ollamaにモデルを登録中..."
docker exec "$OLLAMA_CONTAINER" ollama create "$MODEL_NAME" -f "$MODELFILE_TMP"

# 一時ファイルの削除
docker exec "$OLLAMA_CONTAINER" rm -f "$MODELFILE_TMP"

echo ""
echo "✓ モデルを登録しました: $MODEL_NAME"
echo ""
echo "次のステップ:"
echo "  モデルを選択: python3 scripts/model_select.py --chat-model $MODEL_NAME"
echo "  または Open WebUI (http://localhost:3000) のモデルドロップダウンから選択"
echo ""
echo "テスト実行:"
echo "  docker exec -it $OLLAMA_CONTAINER ollama run $MODEL_NAME"
