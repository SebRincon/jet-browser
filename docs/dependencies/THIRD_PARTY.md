# Third-party components

Every dependency Jet uses, where it comes from, the exact commit or revision it is pinned
to, its license, and how it enters the build. "Private" means the source repository is
not public yet.

## Flutter packages (git submodules under `vendor/`)

| Package | Repository | Pinned commit | License | Notes |
| --- | --- | --- | --- | --- |
| `flutter_cef_browser` | [SebRincon/flutter_cef_browser](https://github.com/SebRincon/flutter_cef_browser) | `ef3853107d70c246661ffcc424b5c5a7dbf1c396` | BSD 3-Clause | From SebRincon/webview_cef (private) at `a14b590`, plus Jet's allowlisted input dispatcher; see its `PROVENANCE.md` |
| `vten_chat` | [SebRincon/vten_chat](https://github.com/SebRincon/vten_chat) | `3b40f88c3ff57b04545d4762ff2f5f07b133dea0` | Apache-2.0 | Chat widgets from vten.ai (private) at `cc49791` |
| `shadcn_flutter` 0.0.47 | [SebRincon/shadcn_flutter_jet](https://github.com/SebRincon/shadcn_flutter_jet) | `f0a4b5c8104e871741df280a2dc806e9760c28f1` | BSD 3-Clause | Fork of [sunarya-thito/shadcn_flutter](https://github.com/sunarya-thito/shadcn_flutter), via vibe-coder-app/shadcn_flutter (private) at `8dc009e` |
| Other pub packages | pub.dev | `app/pubspec.lock` (content hashes) | various | e.g. `markdown_widget` |

`.gitmodules` records the URLs; the gitlinks record the SHAs. Clone with
`git clone --recurse-submodules`.

## Browser engine

| Component | Source | Pin | License |
| --- | --- | --- | --- |
| CEF 147.0.11 / Chromium 147.0.7727.138, macOS arm64, vten frame-lease build | Release `cef-147.0.11-vten-frame-lease-075` of SebRincon/webview_cef (**private for now**) | archive SHA-256 `122fca7115b530a09e604ffbd217448a5a287d6e15daf6b76bfe5dfda9ff8103`; framework, wrapper and header-tree hashes in [`packaging/pins.json`](../../packaging/pins.json) | CEF BSD 3-Clause; Chromium third-party notices ship as `CEF-CREDITS.html` |

This build was compiled with proprietary codecs (H.264, AAC, HEVC), so the maintainer
keeps it private until a public CEF build is chosen. `scripts/install_cef.sh` installs and
verifies it. See [cef-artifact-manifest.yaml](cef-artifact-manifest.yaml) for build flags.

## Python code vendored in this repository

| Component | Location | Upstream | Commit | License | Modified? |
| --- | --- | --- | --- | --- | --- |
| `jev_ultrafast` | `backend/jev_ultrafast/` | [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) | `1231850a0bf1a0c0341fe408ef1668dbbfdfac46` | MIT (Browser Use) | Yes: taken from the maintainer's working copy of that commit, then changed for Jet (`agent.py`, `browser.py`, `local_models.py`, `native_worker.py`, `snapshot.js`; demos and scenarios omitted). File sources: [extracted-source.json](../extracted-source.json) |
| `semif_phase1` | `vendor/local-engines/semif_phase1/` | [TheoLeeCJ/SemIf-OpenJev](https://github.com/TheoLeeCJ/SemIf-OpenJev) `src/semif_phase1` | `ca3ba65f142967030ecb453346e94d6f476a69df` | MIT (TheoLeeCJ) | No |
| `rlcd` | `vendor/local-engines/rlcd/` | [notnotsamuel/LFM2.5-350M-RLCD](https://huggingface.co/notnotsamuel/LFM2.5-350M-RLCD/tree/deb589d803d141cabd158ef55f6617b128529f36/rlcd) (Hugging Face) | `deb589d803d141cabd158ef55f6617b128529f36` | MIT (`LICENSE-CODE`) | No |
| Engine glue (`run.py`, `runtime.py`, `contracts.py`, `laya_runtime.py`) | `vendor/local-engines/` | Maintainer's unpublished lfm-rlcd benchmark workspace | — | Apache-2.0 (this repository) | Adapted for Jet |

## Python packages installed at setup

| Component | Pin | License |
| --- | --- | --- |
| [laya-mlx](https://github.com/mizorewww/laya-mlx) 0.2.0 | git commit `0a859518634112655cb97c745dbf04f5191aaf13` | Apache-2.0 |
| [mlx-lm](https://github.com/ml-explore/mlx-lm) | git commit `a63e24c389382619eb6d9af656e3b46024be217a` | MIT |
| Model-engine packages (torch, transformers, mlx, …) | exact versions and wheel SHA-256 in `vendor/local-engines/locks/*.txt` | various |
| Service packages (aiohttp, …) | exact versions and hashes in `backend/uv.lock` | various |
| CPython 3.12.13 | `uv python install 3.12.13` (python-build-standalone) | PSF |

## Runtime binaries

| Component | Pin | License |
| --- | --- | --- |
| Grok Build CLI (xAI) | Not pinned: the packager bundles the latest release (floor 1.0.41) and the app updates it in its own Grok home | See `native/RuntimeLicenses/Grok-Build-LICENSE` (source xai-org/grok-build at `f0e3be1`) |
| JavaScriptCore | Part of macOS | Apple system framework |

## Models (downloaded in the app; not redistributed here)

`model-downloads.json` pins each Hugging Face revision and every file's SHA-256.

| Model | Revision | License |
| --- | --- | --- |
| [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) (SemIf router and tagging) | `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a` | see model card |
| [mlx-community/Qwen3.5-0.8B-4bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit) (typing helper) | `da28692b5f139cb0ec58a356b437486b7dac7462` | see model card |
| [notnotsamuel/LFM2.5-350M-RLCD](https://huggingface.co/notnotsamuel/LFM2.5-350M-RLCD) | `deb589d803d141cabd158ef55f6617b128529f36` | see model card (`docs/BASE_MODEL_LICENSE.txt`) |
| [aac6fef/laya-mlx](https://huggingface.co/aac6fef/laya-mlx) | `047678560251f28113ee8f5df4be82102c7bf336` | see model card |
| [aac6fef/laya-typed-decisions-mlx](https://huggingface.co/aac6fef/laya-typed-decisions-mlx) | `f9e501c2080cc57c13d6887820329758f5351125` | see model card |
