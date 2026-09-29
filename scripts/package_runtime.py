"""Build a relocatable Jet .app. Build tooling is not an end-user dependency."""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP = shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store", ".git", ".venv", ".runtime", "build", "tests", "_virtualenv*", "*.pth")

def copy_tree(source, target):
    shutil.copytree(source, target, dirs_exist_ok=True, symlinks=False, ignore=SKIP)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/Jet Browser.app")
    args = parser.parse_args()
    runtime_python = ROOT / ".runtime/portable-python/cpython-3.12.13-macos-aarch64-none"
    service_packages = ROOT / ".runtime/portable-packages/service"
    required = [runtime_python / "bin/python3.12", service_packages / "aiohttp", ROOT / "model-downloads.json", ROOT / "native/JetLauncher/main.swift"]
    if not all(p.exists() for p in required):
        raise SystemExit("Run scripts/prepare_portable_runtime.sh before packaging")
    if not args.no_build:
        subprocess.run(["flutter", "build", "macos", "--release"], cwd=ROOT / "app", check=True)
    source = ROOT / "app/build/macos/Build/Products/Release/Jet Browser.app"
    output = args.output.expanduser().resolve()
    if output == source.resolve() or output.suffix != ".app":
        raise SystemExit("Use a separate .app output path")
    # Rebuild-only generated output; user state is never stored in the bundle.
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        if not (output / 'Contents/Resources/jet-runtime/bundle-manifest.json').is_file():
            raise SystemExit('Refusing to replace an app not built by this packager')
        shutil.rmtree(output)
    shutil.copytree(source, output, symlinks=True)
    resources = output / "Contents/Resources/jet-runtime"
    resources.mkdir(parents=True, exist_ok=True)
    copy_tree(runtime_python, resources / "python")
    copy_tree(ROOT / "backend/jet_browser", resources / "backend/jet_browser")
    copy_tree(ROOT / "backend/jev_ultrafast", resources / "backend/jev_ultrafast")
    copy_tree(ROOT / "vendor/local-engines", resources / "vendor/local-engines")
    copy_tree(service_packages, resources / "packages/service")
    for name in ("lfm", "semif", "laya", "text"):
        packages = ROOT / f".runtime/envs/{name}/lib/python3.12/site-packages"
        if not packages.is_dir():
            raise SystemExit(f"Missing build dependencies: {name}; run scripts/setup_models.sh")
        copy_tree(packages, resources / "packages" / name)
    copy_tree(ROOT / "native/RuntimeLicenses", resources / "licenses")
    shutil.copy2(ROOT / "model-downloads.json", resources / "model-downloads.json")
    binaries = resources / "bin"
    binaries.mkdir(exist_ok=True)
    subprocess.run([str(ROOT / "scripts/build_workflow_runtime.sh"), str(binaries / "JetWorkflow")], check=True)
    grok = Path(os.environ.get("JET_BUILD_GROK", Path.home() / ".grok/bin/grok")).resolve()
    if not grok.is_file():
        raise SystemExit("Provide the pinned Grok binary through JET_BUILD_GROK")
    shutil.copy2(grok, binaries / "grok")
    (binaries / "grok").chmod(0o755)
    launcher = output / "Contents/MacOS/JetLauncher"
    subprocess.run(["xcrun", "swiftc", "-O", "-framework", "AppKit", str(ROOT / "native/JetLauncher/main.swift"), "-o", str(launcher)], check=True)
    plist_path = output / "Contents/Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    info["CFBundleExecutable"] = "JetLauncher"
    plist_path.write_bytes(plistlib.dumps(info))
    versions = {}
    for folder in (resources / "packages").iterdir():
        packages = {}
        for metadata in folder.glob("*.dist-info/METADATA"):
            name = version = None
            for line in metadata.read_text(errors="replace").splitlines():
                if line.startswith("Name: "): name = line[6:]
                if line.startswith("Version: "): version = line[9:]
                if name and version: break
            if name: packages[name] = version
        versions[folder.name] = packages
    (resources / "bundle-manifest.json").write_text(json.dumps({
        "schema_version": 1, "python": "3.12.13", "platform": "macos-arm64",
        "grok_sha256": hashlib.sha256((binaries / "grok").read_bytes()).hexdigest(),
        "packages": versions,
        "mlx_lm_semif_revision": "a63e24c389382619eb6d9af656e3b46024be217a",
        "models_included": False,
    }, indent=2) + "\n")
    # Local ad-hoc signature. Developer ID signing/notarization is a release step.
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "--entitlements", str(ROOT / "app/macos/Runner/Release.entitlements"), str(output)], check=True)
    print(json.dumps({"application": str(output), "runtime_bundled": True, "model_setup": "in_app", "signed": "ad_hoc"}))

if __name__ == "__main__":
    main()
