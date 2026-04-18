#!/usr/bin/env python3
"""
rapportディレクトリのドキュメントをOpen WebUI RAGにインポートするツール

使い方:
  python3 scripts/import_rapport.py
  python3 scripts/import_rapport.py --dry-run
  python3 scripts/import_rapport.py --force          # 既存ドキュメントを上書き
  python3 scripts/import_rapport.py --api-key sk-...
  python3 scripts/import_rapport.py --rapport-dir /path/to/docs

対応フォーマット: PDF, DOCX, TXT, MD, CSV, XLSX, HTML, XML

事前準備:
  1. Open WebUI (http://localhost:3000) にログイン
  2. Settings > Account > API Keys でAPIキーを発行
  3. .env に WEBUI_API_KEY=sk-... を設定するか --api-key で指定
"""

import argparse
import os
import sys
from pathlib import Path

import requests

SUPPORTED_EXTENSIONS = {".pdf", ".docx", ".txt", ".md", ".csv", ".xlsx", ".html", ".xml"}


def find_project_root():
    return Path(__file__).parent.parent


def load_env(env_path):
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


def get_config(env, args):
    port = env.get("WEBUI_PORT", "3000")
    api_base = args.api_base or env.get("WEBUI_API_BASE", f"http://localhost:{port}")
    api_key = args.api_key or env.get("WEBUI_API_KEY", "")
    return api_base.rstrip("/"), api_key


def check_api_key(api_key, api_base):
    """APIキーの有無を確認し、未設定なら取得方法を案内する"""
    if api_key:
        return True

    print(
        "\n" + "=" * 60 + "\n"
        "  WEBUI_API_KEY が設定されていません\n"
        "=" * 60 + "\n"
        "\n"
        "APIキーの取得方法:\n"
        f"  1. ブラウザで {api_base} を開く\n"
        "  2. 右上のアバター → Settings → Account\n"
        "  3. 'API Keys' セクションで 'Create new secret key' をクリック\n"
        "  4. 生成されたキー (sk-...) を .env に設定:\n"
        "       WEBUI_API_KEY=sk-xxxxxxxxxxxxxxxx\n"
        "\n"
        "または --api-key オプションで直接指定可能:\n"
        "  python3 scripts/import_rapport.py --api-key sk-...\n"
    )
    return False


def fetch_existing_documents(api_base, api_key):
    """Open WebUIに既にインポート済みのドキュメント名セットを取得する"""
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        resp = requests.get(f"{api_base}/api/v1/documents/", headers=headers, timeout=15)
        if resp.status_code == 401:
            print("エラー: APIキーが無効です。Open WebUIで新しいキーを発行してください", file=sys.stderr)
            sys.exit(1)
        resp.raise_for_status()
        docs = resp.json()
        if isinstance(docs, list):
            return {d.get("name", d.get("filename", "")) for d in docs}
        return set()
    except requests.exceptions.ConnectionError:
        print(
            f"エラー: Open WebUIに接続できません ({api_base})\n"
            "docker compose ps でコンテナの状態を確認してください",
            file=sys.stderr,
        )
        sys.exit(1)


def upload_document(file_path, api_base, api_key, collection=None):
    """単一ファイルをOpen WebUI RAGにアップロードする"""
    headers = {"Authorization": f"Bearer {api_key}"}
    params = {}
    if collection:
        params["collection_name"] = collection

    with open(file_path, "rb") as f:
        files = {"file": (file_path.name, f, _mime_type(file_path))}
        try:
            resp = requests.post(
                f"{api_base}/api/v1/documents/upload",
                headers=headers,
                files=files,
                params=params,
                timeout=120,
            )
            resp.raise_for_status()
            return resp.json()
        except requests.exceptions.HTTPError as e:
            return {"error": str(e), "status_code": resp.status_code}


def _mime_type(file_path):
    ext = file_path.suffix.lower()
    mime_map = {
        ".pdf": "application/pdf",
        ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".txt": "text/plain",
        ".md": "text/markdown",
        ".csv": "text/csv",
        ".html": "text/html",
        ".xml": "application/xml",
    }
    return mime_map.get(ext, "application/octet-stream")


def collect_files(rapport_dir):
    """rapportディレクトリを再帰的に走査して対応ファイルを収集する"""
    files = []
    for path in sorted(rapport_dir.rglob("*")):
        if path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS:
            files.append(path)
    return files


def main():
    parser = argparse.ArgumentParser(
        description="rapport/ディレクトリのドキュメントをOpen WebUI RAGにインポートします",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
例:
  %(prog)s                    # rapportディレクトリを一括インポート
  %(prog)s --dry-run          # 実際にはアップロードせず対象ファイルを表示
  %(prog)s --force            # 既存ドキュメントも再アップロード
  %(prog)s --collection 会議資料  # コレクション名を指定
        """,
    )
    parser.add_argument(
        "--rapport-dir",
        metavar="PATH",
        help="インポートするディレクトリ（デフォルト: プロジェクトルートの rapport/）",
    )
    parser.add_argument("--api-base", metavar="URL", help="Open WebUIのベースURL")
    parser.add_argument("--api-key", metavar="KEY", help="Open WebUI APIキー")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="インポート対象を表示するだけで実際にはアップロードしない",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="既にインポート済みのドキュメントも再アップロードする",
    )
    parser.add_argument("--collection", metavar="NAME", help="Open WebUIのコレクション名を指定")

    args = parser.parse_args()

    project_root = find_project_root()
    env_path = project_root / ".env"
    env = load_env(env_path)

    api_base, api_key = get_config(env, args)
    rapport_dir = Path(args.rapport_dir) if args.rapport_dir else project_root / "rapport"

    if not rapport_dir.exists():
        print(f"エラー: ディレクトリが見つかりません: {rapport_dir}", file=sys.stderr)
        sys.exit(1)

    files = collect_files(rapport_dir)

    if not files:
        print(f"インポート可能なファイルが {rapport_dir} に見つかりません")
        print(f"対応フォーマット: {', '.join(sorted(SUPPORTED_EXTENSIONS))}")
        return

    print(f"対象ディレクトリ: {rapport_dir}")
    print(f"対象ファイル数: {len(files)}")

    if args.dry_run:
        print("\n[ドライラン] 以下のファイルがインポートされます:\n")
        for f in files:
            rel = f.relative_to(rapport_dir)
            print(f"  {rel} ({f.stat().st_size / 1024:.1f} KB)")
        return

    if not check_api_key(api_key, api_base):
        sys.exit(1)

    existing = set() if args.force else fetch_existing_documents(api_base, api_key)

    imported = 0
    skipped = 0
    failed = 0

    for file_path in files:
        rel = file_path.relative_to(rapport_dir)
        if file_path.name in existing:
            print(f"  スキップ (既存): {rel}")
            skipped += 1
            continue

        print(f"  アップロード中: {rel} ...", end="", flush=True)
        result = upload_document(file_path, api_base, api_key, collection=args.collection)

        if "error" in result:
            print(f" 失敗: {result['error']}")
            failed += 1
        else:
            print(" 完了")
            imported += 1

    print(f"\n結果: {imported}件インポート / {skipped}件スキップ / {failed}件失敗")

    if imported > 0:
        print(
            "\nOpen WebUIでドキュメントを使用するには:\n"
            f"  1. {api_base} でチャット画面を開く\n"
            "  2. メッセージ入力欄で '#' を入力するとドキュメント名が補完されます\n"
            "  3. ドキュメントを選択するとRAGコンテキストとして参照されます"
        )


if __name__ == "__main__":
    main()
