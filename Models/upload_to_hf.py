#!/usr/bin/env python3
"""Upload exported CoreML models to the Hugging Face repo the app downloads from.

Each Resources/Models/<stem>.mlpackage is uploaded as a plain folder, so the
app can list the repo and fetch a package file by file, checking every file
against the SHA-256 Hugging Face records for it.

Setup (once):
    .venv/bin/pip install huggingface_hub
    .venv/bin/hf auth login            # or export HF_TOKEN=hf_...  (needs write access)

Examples:
    python Models/upload_to_hf.py --repo you/human-detector-models
    python Models/upload_to_hf.py --repo you/human-detector-models --only yolo26m-seg yolo26x-seg
    python Models/upload_to_hf.py --repo you/human-detector-models --public
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE = REPO_ROOT / "Resources" / "Models"


def main() -> None:
    parser = argparse.ArgumentParser(description="Upload .mlpackage models to Hugging Face")
    parser.add_argument("--repo", required=True, help="<username>/<repository>")
    parser.add_argument("--source", type=Path, default=SOURCE, help="folder with .mlpackage models")
    parser.add_argument("--only", nargs="+", metavar="STEM", help="upload just these stems")
    parser.add_argument("--public", action="store_true", help="create the repo public (default private)")
    args = parser.parse_args()

    try:
        from huggingface_hub import HfApi
    except ImportError:
        sys.exit("huggingface_hub is missing — run: .venv/bin/pip install huggingface_hub")

    packages = sorted(p for p in args.source.glob("*.mlpackage") if p.is_dir())
    if args.only:
        wanted = set(args.only)
        packages = [p for p in packages if p.stem in wanted]
        missing = wanted - {p.stem for p in packages}
        if missing:
            sys.exit(f"not found in {args.source}: {', '.join(sorted(missing))}")
    if not packages:
        sys.exit(f"no .mlpackage models in {args.source} — run `make models` first")

    api = HfApi()
    url = api.create_repo(args.repo, repo_type="model", private=not args.public, exist_ok=True)
    print(f"[upload] repo {url}")

    for package in packages:
        print(f"[upload] {package.name}")
        api.upload_folder(
            repo_id=args.repo,
            repo_type="model",
            folder_path=str(package),
            path_in_repo=package.name,
            ignore_patterns=[".DS_Store", "**/.DS_Store"],
            commit_message=f"Upload {package.name}",
        )

    print(f"[upload] done — in the app, set Settings → Hugging Face to {args.repo}")


if __name__ == "__main__":
    main()
