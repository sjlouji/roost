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

## What it does

Roost opens on what's already set up on your Mac, and lets you add to it.

**GitHub accounts** (read from `~/.ssh/config`)
- **New account:** creates an ed25519 key (`~/.ssh/id_ed25519_<name>`) and a host alias (`github-<name>`), so each account always uses its own key.
- **Connect:** copies the public key and opens GitHub's "New SSH key" page; **Test connection** shows which GitHub user the key signs in as.

**Projects** (found in `~/Documents`)
- A project is a folder with main clones in `<project>/default/<repo>` and task worktrees in `<project>/<task>/<repo>`. Existing ones are found automatically, with each repo's account taken from its remote.
- **Add repository:** paste any GitHub address and pick the account; Roost clones over SSH through that account's alias.
- **New task:** creates a worktree of a repo on a new or existing branch.

**AWS** (read from `~/.aws/config` and `~/.aws/credentials`)
- Lists every profile by how it signs in, and **Check** asks AWS which account and user it is.
- **Add profile:** a permanent key stored encrypted in the Keychain (through aws-vault), temporary credentials with a session token, or SSO sign-in with no keys stored.
- **Refresh** expired temporary credentials, **Sign in** to SSO, and **Move to Keychain** for plain-text keys: Roost checks the profile still works before deleting the plain copy.
- Installs the AWS CLI and aws-vault with Homebrew if they're missing.

**Claude Code** (read from `~/.claude` and `~/.claude.json`)
- Shows your CLAUDE.md, rules, agents, commands, hooks, skills, plugins, MCP servers and memory per project.
- **Export** writes a folder to carry to another Mac. Keys and tokens become `{{secret:…}}` placeholders, your home folder becomes `{{HOME}}`, permission rules that contain a secret are left out, and skill dependency folders (`node_modules`, `.venv`) are skipped. Your login, history, sessions and caches are never included. Turn off "my CLAUDE.md and rules" and "memory" when exporting for someone else.
- **Import** previews every file first, backs up anything it replaces to `~/.claude/backups`, asks for the secrets, reinstalls plugins and MCP servers with the `claude` CLI, and puts memory back under the right project.

## Safety

- Every command Roost runs is shown in the Activity log, as `$ …`, before it runs.
- It never overwrites a key file, and backs up `~/.ssh/config` to `~/.ssh/config.roost-backup` before its first change.
- Its own data (`~/Library/Application Support/Roost/state.json`) holds project names, paths and addresses only.
- Keys typed into Roost go straight to the Keychain or the AWS CLI's files, never to its log or its data. Secrets inside commands are masked in the log.
- Removing a repository that isn't cloned yet only forgets it. Removing an AWS profile asks first, then deletes it from `~/.aws` (and its Keychain entry); the key itself stays active in AWS.

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
| `Packages/RoostCore/` | Accounts, SSH config, projects, AWS, Claude Code, secret scanning, shell runner, storage, and their tests |
| `project.yml` | xcodegen spec; `Roost.xcodeproj` is generated from it and not committed |
