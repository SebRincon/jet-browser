"""Separate immutable app resources from private user data."""
import os
from pathlib import Path

RESOURCE_ROOT = Path(os.environ.get("JET_RESOURCE_ROOT", Path(__file__).resolve().parents[2])).resolve()
DATA_ROOT = Path(os.environ.get("JET_DATA_ROOT", RESOURCE_ROOT)).expanduser().resolve()
PORT = int(os.environ.get("JET_PORT", "9148"))
if not 1024 <= PORT <= 65533:
    raise ValueError("Invalid Jet port")

def workflow_executable():
    explicit = os.environ.get("JET_WORKFLOW_PATH")
    if explicit:
        return Path(explicit)
    packaged = RESOURCE_ROOT / "bin" / "JetWorkflow"
    return packaged if packaged.is_file() else RESOURCE_ROOT / ".runtime/bin/jet-workflow"
