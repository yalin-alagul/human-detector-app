#!/usr/bin/env python3
"""Export the human-detector models to CoreML.

Person models come from Ultralytics (YOLO11 / YOLO26, detect or segment).
The optional face specialist is SCRFD, converted from the InsightFace buffalo_l
pack. Everything is dropped into Resources/Models/ with the file names the Swift
app resolves.

Setup:
    python3 -m venv .venv && source .venv/bin/activate
    pip install ultralytics coremltools onnx onnxruntime onnx2torch torch

Examples:
    python Models/export_models.py --family yolo26 --sizes n s m x --task seg
    python Models/export_models.py --family yolo11 --sizes x --task seg
    python Models/export_models.py --scrfd-only

Notes:
    * Person exports are FP16 by default; pass --quantize 8 for INT8 weights.
    * We export RAW outputs (no embedded NMS) because the Swift decoder does its
      own NMS and understands the raw [1, C, N] / [1, N, C] layouts.
    * SCRFD outputs are renamed to score_<stride>/bbox_<stride>/kps_<stride>,
      which is exactly what SCRFDFaceDetector expects.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEST = REPO_ROOT / "Resources" / "Models"
CACHE = REPO_ROOT / ".model-cache"

BUFFALO_URL = (
    "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
)
SCRFD_STEM = "scrfd_10g_bnkps"


def log(message: str) -> None:
    print(f"[export] {message}", flush=True)


def ensure_dirs() -> None:
    DEST.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)


# --------------------------------------------------------------------------- #
# Person models (Ultralytics)
# --------------------------------------------------------------------------- #

DEFAULT_IMGSZ_MAP = {"n": 640, "s": 960, "m": 960, "l": 960, "x": 1280}


def parse_size_map(raw: str | None) -> dict[str, int]:
    if not raw:
        return dict(DEFAULT_IMGSZ_MAP)
    mapping: dict[str, int] = {}
    for pair in raw.split(","):
        key, _, value = pair.partition("=")
        mapping[key.strip()] = int(value)
    return mapping


def export_person(
    family: str,
    sizes: list[str],
    task: str,
    imgsz: int | None,
    size_map: dict[str, int],
    quantize: int | None,
) -> None:
    try:
        from ultralytics import YOLO
    except ImportError:
        log("ultralytics is not installed. Run: pip install ultralytics")
        sys.exit(2)

    for size in sizes:
        stem = f"{family}{size}-{task}"
        weights = f"{stem}.pt"
        target_size = imgsz or size_map.get(size, 960)
        log(f"exporting {stem} at {target_size}px ...")
        model = YOLO(weights)
        kwargs = dict(format="coreml", imgsz=target_size)
        if quantize:
            kwargs["quantize"] = quantize
        path = model.export(**kwargs)

        exported = Path(path)
        target = DEST / f"{stem}.mlpackage"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(exported, target)
        log(f"  -> {target.relative_to(REPO_ROOT)}")


# --------------------------------------------------------------------------- #
# SCRFD face specialist
# --------------------------------------------------------------------------- #

def download_scrfd() -> Path:
    onnx_path = CACHE / "det_10g.onnx"
    if onnx_path.exists():
        return onnx_path

    zip_path = CACHE / "buffalo_l.zip"
    if not zip_path.exists():
        log("downloading buffalo_l pack (contains det_10g.onnx / SCRFD 10G) ...")
        urllib.request.urlretrieve(BUFFALO_URL, zip_path)

    log("extracting ...")
    with zipfile.ZipFile(zip_path) as archive:
        for name in archive.namelist():
            if name.endswith("det_10g.onnx"):
                with archive.open(name) as source, open(onnx_path, "wb") as dest:
                    shutil.copyfileobj(source, dest)
                return onnx_path
    raise FileNotFoundError("det_10g.onnx not found inside buffalo_l.zip")


def export_scrfd(input_size: int, quantize: int | None) -> None:
    """Convert SCRFD to CoreML.

    Recent coremltools releases dropped the ONNX frontend, so we route through
    ONNX -> PyTorch (onnx2torch) -> TorchScript -> CoreML instead. SCRFD is a
    plain conv/bn/relu network, which onnx2torch handles cleanly.
    """
    try:
        import coremltools as ct
    except ImportError:
        log("coremltools is not installed. Run: pip install coremltools")
        sys.exit(2)
    try:
        import onnx
        import torch
        from onnx2torch import convert as onnx_to_torch
    except ImportError:
        log("onnx2torch is required for SCRFD. Run: pip install onnx onnx2torch torch")
        sys.exit(2)

    onnx_path = download_scrfd()
    log(f"converting SCRFD {onnx_path.name} to CoreML (onnx -> torch -> coreml) ...")

    graph = onnx.load(str(onnx_path))
    torch_model = onnx_to_torch(graph).eval()
    example = torch.rand(1, 3, input_size, input_size)
    with torch.no_grad():
        torch_model(example)
    traced = torch.jit.trace(torch_model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 3, input_size, input_size))],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    if quantize == 8:
        try:
            from coremltools.optimize.coreml import OpLinearQuantizerConfig, linear_quantize_weights

            config = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
            mlmodel = linear_quantize_weights(mlmodel, config)
        except Exception as error:  # pragma: no cover - optional optimisation
            log(f"  INT8 weight quantisation skipped: {error}")

    spec = mlmodel.get_spec()
    rename_scrfd_outputs(spec)
    out_path = DEST / f"{SCRFD_STEM}.mlpackage"
    if out_path.exists():
        shutil.rmtree(out_path)
    mlmodel.save(str(out_path))
    log(f"  -> {out_path.relative_to(REPO_ROOT)}")


def rename_scrfd_outputs(spec) -> None:
    """Map SCRFD's numeric ONNX outputs to score/bbox/kps_<stride> names.

    SCRFD emits three heads per stride (8, 16, 32) with last dimensions 1
    (scores), 4 (box distances) and 10 (5 keypoints). Larger spatial grids mean
    smaller strides, so sorting each group by element count recovers the stride.
    """
    import coremltools as ct

    outputs = list(spec.description.output)
    groups: dict[int, list] = {1: [], 4: [], 10: []}
    for output in outputs:
        try:
            shape = list(output.type.multiArrayType.shape)
        except Exception:
            continue
        last = int(shape[-1])
        if last in groups:
            groups[last].append((output.name, shape))

    renamed = 0
    for last, kind in ((1, "score"), (4, "bbox"), (10, "kps")):
        items = sorted(groups[last], key=lambda item: _element_count(item[1]), reverse=True)
        for index, (name, _) in enumerate(items):
            stride = [8, 16, 32][index] if index < 3 else 8 * (index + 1)
            ct.utils.rename_feature(spec, name, f"{kind}_{stride}", rename_inputs=False)
            renamed += 1
    log(f"  renamed {renamed} output tensors")


def _element_count(shape: list) -> int:
    total = 1
    for dim in shape:
        total *= int(dim)
    return total


# --------------------------------------------------------------------------- #

def main() -> None:
    parser = argparse.ArgumentParser(description="Export CoreML models for HumanDetector")
    parser.add_argument("--family", default="yolo26", choices=["yolo26", "yolo11"])
    parser.add_argument("--sizes", nargs="+", default=["n", "s", "m", "x"])
    parser.add_argument("--task", default="seg", choices=["seg", "detect"])
    parser.add_argument("--imgsz", type=int, default=None,
                        help="Force one input size for every model (overrides --imgsz-map)")
    parser.add_argument("--imgsz-map", default=None,
                        help='Per-size input sizes, e.g. "n=640,s=960,m=960,x=1280"')
    parser.add_argument("--quantize", type=int, default=None, choices=[8, 16, 32])
    parser.add_argument("--scrfd", action="store_true", help="also export the SCRFD face model")
    parser.add_argument("--scrfd-only", action="store_true", help="export only SCRFD")
    parser.add_argument("--scrfd-size", type=int, default=640)
    args = parser.parse_args()

    ensure_dirs()

    if not args.scrfd_only:
        export_person(
            args.family,
            args.sizes,
            args.task,
            args.imgsz,
            parse_size_map(args.imgsz_map),
            args.quantize,
        )

    if args.scrfd or args.scrfd_only:
        export_scrfd(args.scrfd_size, args.quantize)

    log("done. Reopen the app and press Reload on the Models screen.")


if __name__ == "__main__":
    main()
