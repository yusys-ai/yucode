# Yusys CodeMate

Yusys CodeMate is distributed as the `yucode` command. The native installer is
the recommended installation method and does not require Node.js.

## Install

macOS or glibc Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/yusys-ai/yucode/main/install.sh | sh
```

Windows PowerShell 5.1 or later:

```powershell
irm https://raw.githubusercontent.com/yusys-ai/yucode/main/install.ps1 | iex
```

The installer verifies the release archive against `SHA256SUMS`, installs an
exact version under the current user profile, and adds its managed command
directory to the user PATH when needed. It never modifies Yusys CodeMate
settings, credentials, plugins, or sessions.

To inspect a script before running it, download it to a file, review it, then
execute that file instead of piping it directly to a shell.

## Update and uninstall

Rerun the install command to update. It is safe to rerun when the selected
version is already installed.

On macOS or Linux, uninstall with:

```sh
curl -fsSL https://raw.githubusercontent.com/yusys-ai/yucode/main/install.sh | sh -s -- --uninstall
```

On Windows, uninstall with:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yusys-ai/yucode/main/install.ps1))) '--uninstall'
```

During `install`, the native release is installed and verified before a
confirmed user-managed global installation of `@yusys-ai/yucode` is removed.
System-level and ambiguous npm installations are never removed and are reported
with manual guidance.

Uninstall removes only installer-managed binaries, state, and PATH entries.
User data under `~/.yucode` is kept. Add `--purge` to the uninstall command to
remove it as well:

```sh
curl -fsSL https://raw.githubusercontent.com/yusys-ai/yucode/main/install.sh | sh -s -- --uninstall --purge
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yusys-ai/yucode/main/install.ps1))) '--uninstall' '--purge'
```

## Release selection

With no arguments, the installer selects the latest stable release. If no
stable release exists, it selects the latest release candidate. `--preview`
selects whichever available stable or release-candidate version is newer:

```sh
curl -fsSL https://raw.githubusercontent.com/yusys-ai/yucode/main/install.sh | sh -s -- --preview
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yusys-ai/yucode/main/install.ps1))) '--preview'
```

Use `--version <version>` to install any exact public stable or release-candidate
version that is not older than the installed version:

```sh
curl -fsSL https://raw.githubusercontent.com/yusys-ai/yucode/main/install.sh | sh -s -- --version 0.842.0-rc1
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yusys-ai/yucode/main/install.ps1))) '--version' '0.842.0-rc1'
```

Each run selects from its current arguments; an earlier preview installation
does not change later no-argument behavior.

Reinstalling the same version is idempotent. Downgrades are not supported. If a
preview is newer than the current stable release, use `--preview` or a newer
exact release until stable catches up. Use `--no-modify-path` to manage PATH
yourself. After a successful update, superseded installer-managed versions are
removed when no `yucode` process is running.

## npm

Stable releases also support Node.js 22.19 or later:

```sh
npm install --global --ignore-scripts @yusys-ai/yucode
```

`@yusys-ai/yucode` is a launcher for the matching `@yusys-ai/roche-*` platform
binary. Do not disable optional dependencies. Rerun the native installer to
replace an npm installation.

## Supported platforms

- macOS on Apple silicon (`arm64`) or Intel (`x64`)
- glibc Linux on `arm64` or `x64`
- Windows on `arm64` or `x64`

Android/Termux, musl-based Linux distributions such as Alpine, and 32-bit
systems are not supported by the current release artifacts.

The macOS builds are signed but not notarized. If macOS blocks the first launch,
open **System Settings > Privacy & Security**, click **Open Anyway**, then
confirm **Open**. Do not disable Gatekeeper globally. See
[Safely open apps on your Mac](https://support.apple.com/102445) for Apple's
instructions.

The public package does not export a JavaScript SDK or TypeScript declarations.
Use `yucode --mode rpc` for programmatic integration.
