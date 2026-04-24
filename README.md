# Tether

A macOS menu-bar utility that keeps a local project directory in sync with a remote host over `rsync`/SSH.

For each project, Tether:

- pushes local **code** changes to the remote (debounced, triggered by filesystem events), and
- pulls remote **logs** back to the local machine on a configurable interval.

It runs as a status-bar app (`LSUIElement`), with no Dock icon.

## Requirements

- macOS 14+
- Swift 5.10 toolchain (Xcode 15.3+ or matching Swift CLI)
- `/usr/bin/rsync` and `ssh` reachable on `PATH`
- An SSH identity that can reach your remote host non-interactively

## Build

```sh
./scripts/build-app.sh         # release build → build/Tether.app
./scripts/build-app.sh debug   # debug build
open build/Tether.app
```

The script runs `swift build`, assembles a proper `.app` bundle (so `LSUIElement` is honored), and ad-hoc code-signs it.

## Configuration

Projects are stored at `~/Library/Application Support/Tether/config.json`. Edit them via the menu-bar UI (**Add Project…** / pencil icon). Each project has:

- a local root path and a remote root (e.g. `user@host:/srv/myapp`)
- a `code` subpath (pushed) and a `logs` subpath (pulled)
- a pull interval, optional SSH identity file, and optional extra `rsync` args

A project's `.gitignore` (if present) is reused as the rsync exclude list.

## Layout

```
Sources/Tether/
  TetherApp.swift       # @main entry
  Models/               # ProjectConfig, status types
  Store/                # ConfigStore (persistence)
  Sync/                 # SyncEngine, SyncWorker, RsyncRunner, FileWatcher, IgnoreRules
  UI/                   # MenuBarContent, ProjectEditorView
Resources/Info.plist    # bundle metadata (LSUIElement = true)
scripts/build-app.sh    # build + bundle script
```
