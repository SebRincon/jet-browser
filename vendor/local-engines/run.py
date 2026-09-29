import os
"""Run the pinned RLCD engine with its checksum-verified, bundled weights."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(os.environ.get("JET_DATA_ROOT", Path(__file__).resolve().parents[2]))
UPSTREAM = ROOT / "models/lfm350m"
sys.path.insert(0, str(UPSTREAM))


def verify():
    manifest = json.loads((UPSTREAM / "BASE_MODEL_MANIFEST.json").read_text())
    for name, expected in manifest["files"].items():
        path = UPSTREAM / name
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if (path.stat().st_size != expected["size_bytes"] or
                digest != expected["sha256"]):
            raise ValueError(f"Bundled file does not match upstream manifest: {name}")


def load_engine():
    import torch
    import rlcd.engine as module
    verify()
    # The author bundles byte-identical base weights but defaults to downloading
    # them again. Point at the verified local copy without editing upstream code.
    module.MODEL_ID = str(UPSTREAM)
    module.REVISION = None
    torch.set_num_threads(4)
    torch.manual_seed(42)
    return module.Engine(device="mps", dtype="float16")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("text", nargs="?", default="I was charged twice. Please refund the duplicate charge. No hurry.")
    parser.add_argument("--schema", type=Path, help="Flat closed schema with required boolean/string-enum fields")
    parser.add_argument("--autoregressive", action="store_true")
    args = parser.parse_args()
    from rlcd.tasks import SUPPORT
    schema = json.loads(args.schema.read_text()) if args.schema else SUPPORT
    engine = load_engine()
    output = (engine.autoregressive if args.autoregressive else engine.constrained)(args.text, schema)
    print(json.dumps(output, indent=2, ensure_ascii=False))
