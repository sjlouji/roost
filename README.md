# Roost

A native Mac app that sets up a developer Mac: GitHub accounts with their own SSH keys, project folders, repos cloned with the right account, and task worktrees. No secrets ever leave your Mac or go into Roost's data.

Requires macOS 26 or later on Apple silicon.

## Download

**[Download Roost for Mac (Apple silicon)](https://github.com/sjlouji/roost/releases/latest/download/Roost-macOS-arm64.zip)** · [All releases](https://github.com/sjlouji/roost/releases)

Unzip it and move **Roost.app** to Applications.

**Opening it the first time.** This build isn't notarized by Apple yet, so macOS blocks it on first launch. Don't click **Move to Bin**: the app isn't broken. The quickest fix works for every version of the warning. Run this once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Roost.app
```

Or, if the warning says Apple **"could not verify"** Roost (not that it's **"damaged"**):

1. Click **Done**.
2. Go to **System Settings → Privacy & Security**, scroll to "Roost was blocked…", click **Open Anyway** and confirm.

After that it opens normally. To check the download matches the release, compare `shasum -a 256 Roost-macOS-arm64.zip` with the `.sha256` file attached to the release.

## What it does today

**GitHub accounts**
- **New account:** creates an ed25519 key (`~/.ssh/id_ed25519_<name>`) and a host alias (`github-<name>`) in `~/.ssh/config`, so each account always uses its own key.
- **Import:** picks up GitHub aliases already in `~/.ssh/config`.
- **Connect:** copies the public key and opens GitHub's "New SSH key" page; **Test connection** shows which GitHub user the key signs in as.

**Projects**
- A project is a folder: main clones in `<project>/default/<repo>`, task worktrees in `<project>/<task>/<repo>`.
- **Add repository:** paste any GitHub address and pick the account; Roost clones over SSH through that account's alias.
- **New task:** creates a worktree of each chosen repo on a new or existing branch.

## Safety

- Every command Roost runs is shown in the Activity log, as `$ …`, before it runs.
- It never overwrites a key file, and backs up `~/.ssh/config` to `~/.ssh/config.roost-backup` before its first change.
- Its own data (`~/Library/Application Support/Roost/roost.json`) holds names, paths and addresses only.
- "Remove" in Roost only forgets an item; keys, config entries and files on disk stay.

## Build and run

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Roost.xcodeproj -scheme Roost -derivedDataPath build build
open build/Build/Products/Debug/Roost.app
```

Logic lives in `Packages/RoostCore` (no UI) and is tested on its own:

```bash
cd Packages/RoostCore && swift test
```

## Layout

| Path | Holds |
|---|---|
| `App/` | SwiftUI app: windows, sheets, `AppModel` (state and actions) |
| `Packages/RoostCore/` | Accounts, SSH config, Git remotes, projects, shell runner, storage, and their tests |
| `project.yml` | xcodegen spec; `Roost.xcodeproj` is generated from it and not committed |
