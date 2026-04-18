#!/usr/bin/env python3
"""
Ollamaモデル選択・設定ツール

使い方:
  python3 scripts/model_select.py              # 対話的にモデルを選択
  python3 scripts/model_select.py --list       # モデル一覧表示のみ
  python3 scripts/model_select.py --chat-model llama3.2:3b-instruct-q4_K_M
  python3 scripts/model_select.py --vision-model llava:7b-v1.6-mistral-q4_K_M
  python3 scripts/model_select.py --pull mistral:7b-instruct-q4_K_M  # ダウンロード
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import requests


def find_project_root():
    return Path(__file__).parent.parent


def load_env(env_path):
    """key=value 形式の .env を辞書として読み込む"""
    env = {}
    if env_path.exists():
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                env[key.strip()] = val.strip().strip('"').strip("'")
    return env


def get_ollama_url(env):
    port = env.get("OLLAMA_PORT", os.environ.get("OLLAMA_PORT", "11434"))
    base = env.get("OLLAMA_API_BASE", os.environ.get("OLLAMA_API_BASE", f"http://localhost:{port}"))
    return base.rstrip("/")


def fetch_models(ollama_url):
    """Ollamaから利用可能なモデル一覧を取得する"""
    try:
        resp = requests.get(f"{ollama_url}/api/tags", timeout=10)
        resp.raise_for_status()
        return resp.json().get("models", [])
    except requests.exceptions.ConnectionError:
        print(
            f"エラー: Ollamaに接続できません ({ollama_url})\n"
            "Dockerコンテナが起動しているか確認: docker compose ps",
            file=sys.stderr,
        )
        sys.exit(1)


def format_size(size_bytes):
    """バイト数を人間が読みやすい形式に変換する"""
    if size_bytes >= 1_000_000_000:
        return f"{size_bytes / 1_000_000_000:.1f} GB"
    elif size_bytes >= 1_000_000:
        return f"{size_bytes / 1_000_000:.0f} MB"
    return f"{size_bytes} B"


def print_models_table(models):
    """モデル一覧を表形式で表示する"""
    if not models:
        print("（Ollamaにモデルがありません。setup.sh を実行してダウンロードしてください）")
        return

    header = f"{'#':>3}  {'モデル名':<45} {'サイズ':>8}  {'パラメータ':>10}  {'量子化':<10}"
    print(header)
    print("-" * len(header))
    for i, m in enumerate(models, 1):
        name = m.get("name", "")
        size = format_size(m.get("size", 0))
        details = m.get("details", {})
        params = details.get("parameter_size", "-")
        quant = details.get("quantization_level", "-")
        print(f"{i:>3}  {name:<45} {size:>8}  {params:>10}  {quant:<10}")


def update_env_file(env_path, key, value):
    """
    .env ファイルの指定キーの値をアトミックに更新する。
    キーが存在しなければ末尾に追加する。
    """
    content = env_path.read_text() if env_path.exists() else ""
    lines = content.splitlines(keepends=True)
    pattern = re.compile(rf"^{re.escape(key)}\s*=.*$", re.MULTILINE)

    new_line = f"{key}={value}\n"
    if any(pattern.match(line) for line in lines):
        new_lines = [pattern.sub(new_line.rstrip("\n"), line) if pattern.match(line) else line for line in lines]
    else:
        new_lines = lines + [new_line]

    tmp_path = env_path.with_suffix(".env.tmp")
    tmp_path.write_text("".join(new_lines))
    tmp_path.replace(env_path)


def restart_webui(project_root):
    """Open WebUIコンテナを再起動して新しいモデル設定を反映する"""
    print("Open WebUIを再起動して設定を反映中...")
    result = subprocess.run(
        ["docker", "compose", "up", "-d", "open-webui"],
        cwd=project_root,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print("Open WebUI を再起動しました")
    else:
        print(f"警告: Open WebUI の再起動に失敗しました\n{result.stderr}")


def interactive_select(models, env, env_path, project_root, no_restart=False):
    """対話的にモデルを選択してチャットモデルとビジョンモデルを設定する"""
    print_models_table(models)

    if not models:
        return

    names = [m["name"] for m in models]
    current_chat = env.get("DEFAULT_CHAT_MODEL", "")
    current_vision = env.get("DEFAULT_VISION_MODEL", "")

    def prompt_select(label, current):
        print(f"\n{label} (現在: {current or '未設定'})")
        print("番号を入力してEnter（変更しない場合はEnterのみ）: ", end="")
        choice = input().strip()
        if not choice:
            return current
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(names):
                return names[idx]
            else:
                print("無効な番号です。変更しません")
                return current
        except ValueError:
            print("無効な入力です。変更しません")
            return current

    new_chat = prompt_select("チャットモデル", current_chat)
    new_vision = prompt_select("ビジョン（画像解析）モデル", current_vision)

    changed = False
    if new_chat and new_chat != current_chat:
        update_env_file(env_path, "DEFAULT_CHAT_MODEL", new_chat)
        update_env_file(env_path, "WEBUI_DEFAULT_MODEL", new_chat)
        print(f"チャットモデルを変更: {current_chat} → {new_chat}")
        changed = True

    if new_vision and new_vision != current_vision:
        update_env_file(env_path, "DEFAULT_VISION_MODEL", new_vision)
        update_env_file(env_path, "SCREENSHOT_VISION_MODEL", new_vision)
        print(f"ビジョンモデルを変更: {current_vision} → {new_vision}")
        changed = True

    if changed and not no_restart:
        restart_webui(project_root)
    elif not changed:
        print("変更はありませんでした")


def pull_model(ollama_url, model_name):
    """Ollamaモデルをダウンロードする"""
    print(f"モデルをダウンロード中: {model_name}")
    print("（ファイルサイズによっては数分〜数十分かかります）")

    try:
        resp = requests.post(
            f"{ollama_url}/api/pull",
            json={"name": model_name, "stream": True},
            stream=True,
            timeout=3600,
        )
        resp.raise_for_status()
        for line in resp.iter_lines():
            if line:
                data = json.loads(line)
                status = data.get("status", "")
                if "total" in data and "completed" in data:
                    pct = int(data["completed"] / data["total"] * 100)
                    print(f"\r  {status}: {pct}%", end="", flush=True)
                else:
                    print(f"  {status}")
        print(f"\nダウンロード完了: {model_name}")
    except Exception as e:
        print(f"エラー: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Ollamaモデルの確認・選択・設定ツール",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
例:
  %(prog)s                          # 対話的に選択
  %(prog)s --list                   # 一覧表示のみ
  %(prog)s --chat-model llama3.2:3b-instruct-q4_K_M
  %(prog)s --pull mistral:7b-instruct-q4_K_M
        """,
    )
    parser.add_argument("--list", action="store_true", help="モデル一覧を表示して終了")
    parser.add_argument("--chat-model", metavar="MODEL", help="チャットモデルを直接指定")
    parser.add_argument("--vision-model", metavar="MODEL", help="ビジョンモデルを直接指定")
    parser.add_argument("--pull", metavar="MODEL", help="指定モデルをOllamaにダウンロード")
    parser.add_argument("--no-restart", action="store_true", help="Open WebUIを再起動しない")
    parser.add_argument("--ollama-url", help="Ollama APIのベースURL")

    args = parser.parse_args()

    project_root = find_project_root()
    env_path = project_root / ".env"
    env = load_env(env_path)
    ollama_url = args.ollama_url or get_ollama_url(env)

    if args.pull:
        pull_model(ollama_url, args.pull)
        return

    models = fetch_models(ollama_url)

    if args.list:
        print_models_table(models)
        return

    if args.chat_model or args.vision_model:
        changed = False
        if args.chat_model:
            update_env_file(env_path, "DEFAULT_CHAT_MODEL", args.chat_model)
            update_env_file(env_path, "WEBUI_DEFAULT_MODEL", args.chat_model)
            print(f"チャットモデルを設定: {args.chat_model}")
            changed = True
        if args.vision_model:
            update_env_file(env_path, "DEFAULT_VISION_MODEL", args.vision_model)
            update_env_file(env_path, "SCREENSHOT_VISION_MODEL", args.vision_model)
            print(f"ビジョンモデルを設定: {args.vision_model}")
            changed = True
        if changed and not args.no_restart:
            restart_webui(project_root)
        return

    # 対話モード
    interactive_select(models, env, env_path, project_root, no_restart=args.no_restart)


if __name__ == "__main__":
    main()
