#!/usr/bin/env python3
"""
スクリーンショット → Ollamaビジョンモデル解析ツール

使い方:
  python3 scripts/screenshot_analyze.py
  python3 scripts/screenshot_analyze.py --file /path/to/image.png
  python3 scripts/screenshot_analyze.py --prompt "このエラーの原因は何ですか？"
  python3 scripts/screenshot_analyze.py --region 0,0,1920,1080 --save-image

ヘッドレスサーバー環境では --file を使用してください。
"""

import argparse
import base64
import json
import os
import sys
import tempfile
from pathlib import Path


def load_env_defaults():
    """プロジェクトルートの .env から設定値を読み込む"""
    script_dir = Path(__file__).parent
    env_path = script_dir.parent / ".env"
    defaults = {
        "model": os.environ.get("SCREENSHOT_VISION_MODEL", "llava:7b-v1.6-mistral-q4_K_M"),
        "prompt": os.environ.get(
            "SCREENSHOT_PROMPT",
            "Describe everything visible in this screenshot in detail. If there is text, transcribe it accurately.",
        ),
        "ollama_url": os.environ.get("OLLAMA_API_BASE", "http://localhost:11434"),
    }
    if env_path.exists():
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                if key == "SCREENSHOT_VISION_MODEL" and val:
                    defaults["model"] = val
                elif key == "SCREENSHOT_PROMPT" and val:
                    defaults["prompt"] = val
                elif key == "OLLAMA_API_BASE" and val:
                    defaults["ollama_url"] = val
    return defaults


def capture_screen(region=None, output_path=None):
    """スクリーンをキャプチャしてPNG bytesを返す。ヘッドレス環境ではエラーを返す。"""
    try:
        import mss
        import mss.tools

        with mss.mss() as sct:
            if region:
                x, y, w, h = region
                monitor = {"left": x, "top": y, "width": w, "height": h}
            else:
                monitor = sct.monitors[1]  # プライマリモニター
            screenshot = sct.grab(monitor)
            png_bytes = mss.tools.to_png(screenshot.rgb, screenshot.size)
            if output_path:
                Path(output_path).write_bytes(png_bytes)
            return png_bytes
    except Exception as mss_error:
        # mss が失敗した場合（ヘッドレス環境など）はscrotにフォールバック
        if not os.environ.get("DISPLAY"):
            raise RuntimeError(
                "スクリーンキャプチャに失敗しました。\n"
                "ヘッドレスサーバー環境では --file オプションで画像ファイルを指定してください。\n"
                "例: python3 scripts/screenshot_analyze.py --file /path/to/screenshot.png\n"
                f"（内部エラー: {mss_error}）"
            ) from mss_error

        import subprocess

        tmp = output_path or tempfile.mktemp(suffix=".png")
        result = subprocess.run(
            ["scrot", "-z", tmp], capture_output=True, timeout=10
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"scrot でのキャプチャに失敗しました: {result.stderr.decode()}\n"
                "scrotがインストールされているか確認: sudo apt-get install scrot"
            ) from mss_error
        png_bytes = Path(tmp).read_bytes()
        if not output_path:
            os.unlink(tmp)
        return png_bytes


def encode_image(image_bytes):
    """画像bytesをbase64文字列に変換する"""
    return base64.b64encode(image_bytes).decode("utf-8")


def send_to_ollama(model, prompt, image_b64, ollama_url, stream=True, timeout=180):
    """OllamaのvisionモデルAPIに画像と質問を送信する"""
    import requests

    url = f"{ollama_url.rstrip('/')}/api/generate"
    payload = {
        "model": model,
        "prompt": prompt,
        "images": [image_b64],
        "stream": stream,
    }

    try:
        resp = requests.post(url, json=payload, stream=stream, timeout=timeout)
    except requests.exceptions.ConnectionError:
        print(
            f"\nエラー: Ollamaに接続できません ({ollama_url})\n"
            "Dockerコンテナが起動しているか確認してください:\n"
            "  docker compose ps\n"
            "  docker compose up -d",
            file=sys.stderr,
        )
        sys.exit(1)
    except requests.exceptions.Timeout:
        print(f"\nエラー: タイムアウト（{timeout}秒）。画像が大きいか、モデルが重い可能性があります。", file=sys.stderr)
        sys.exit(1)

    if resp.status_code == 404:
        print(
            f"\nエラー: モデル '{model}' が見つかりません。\n"
            f"以下のコマンドでモデルを取得してください:\n"
            f"  docker exec ollama ollama pull {model}",
            file=sys.stderr,
        )
        sys.exit(1)

    resp.raise_for_status()

    if stream:
        full_response = ""
        for line in resp.iter_lines():
            if line:
                data = json.loads(line)
                token = data.get("response", "")
                print(token, end="", flush=True)
                full_response += token
                if data.get("done"):
                    break
        print()  # 改行
        return full_response
    else:
        data = resp.json()
        result = data.get("response", "")
        print(result)
        return result


def parse_region(region_str):
    """'x,y,w,h' 形式の文字列をタプルに変換する"""
    try:
        parts = [int(v.strip()) for v in region_str.split(",")]
        if len(parts) != 4:
            raise ValueError
        return tuple(parts)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"--region の形式が正しくありません: '{region_str}'\n正しい形式: x,y,幅,高さ (例: 0,0,1920,1080)"
        )


def main():
    defaults = load_env_defaults()

    parser = argparse.ArgumentParser(
        description="スクリーンショットをOllamaビジョンモデルで解析します",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
例:
  %(prog)s
  %(prog)s --prompt "このダイアログは何をしていますか？"
  %(prog)s --file /tmp/screen.png --model llama3.2-vision:11b
  %(prog)s --region 0,0,1280,720 --save-image --output /tmp/capture.png
        """,
    )
    parser.add_argument(
        "--model",
        default=defaults["model"],
        help=f"使用するビジョンモデル (デフォルト: {defaults['model']})",
    )
    parser.add_argument(
        "--prompt",
        default=defaults["prompt"],
        help="解析の質問・指示",
    )
    parser.add_argument(
        "--file",
        metavar="PATH",
        help="既存の画像ファイルを解析（スクリーンキャプチャをスキップ）",
    )
    parser.add_argument(
        "--output",
        metavar="PATH",
        help="キャプチャした画像の保存先",
    )
    parser.add_argument(
        "--region",
        type=parse_region,
        metavar="x,y,w,h",
        help="キャプチャする画面領域（例: 0,0,1920,1080）",
    )
    parser.add_argument(
        "--save-image",
        action="store_true",
        help="解析後も画像ファイルを保持する",
    )
    parser.add_argument(
        "--no-stream",
        action="store_true",
        help="全レスポンスを受信してから表示（デフォルト: ストリーミング表示）",
    )
    parser.add_argument(
        "--ollama-url",
        default=defaults["ollama_url"],
        help=f"Ollama APIのベースURL (デフォルト: {defaults['ollama_url']})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=180,
        help="APIリクエストのタイムアウト秒数 (デフォルト: 180)",
    )

    args = parser.parse_args()

    temp_file = None

    try:
        # 画像の取得
        if args.file:
            image_path = Path(args.file)
            if not image_path.exists():
                print(f"エラー: ファイルが見つかりません: {args.file}", file=sys.stderr)
                sys.exit(1)
            image_bytes = image_path.read_bytes()
            print(f"画像ファイルを読み込みました: {args.file}")
        else:
            print("スクリーンをキャプチャ中...")
            output_path = args.output
            if not output_path and args.save_image:
                output_path = tempfile.mktemp(suffix=".png", prefix="screenshot_")
            elif not output_path:
                temp_file = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
                output_path = temp_file.name
                temp_file.close()

            image_bytes = capture_screen(region=args.region, output_path=output_path)

            if args.save_image or args.output:
                print(f"画像を保存しました: {output_path}")

        image_b64 = encode_image(image_bytes)

        print(f"\nモデル: {args.model}")
        print(f"プロンプト: {args.prompt}")
        print("-" * 60)

        send_to_ollama(
            model=args.model,
            prompt=args.prompt,
            image_b64=image_b64,
            ollama_url=args.ollama_url,
            stream=not args.no_stream,
            timeout=args.timeout,
        )

    finally:
        # 一時ファイルの削除
        if temp_file and not args.save_image and not args.output:
            try:
                os.unlink(temp_file.name)
            except OSError:
                pass


if __name__ == "__main__":
    main()
