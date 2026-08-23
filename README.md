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
curl -fsSL https://raw.githubusercontent.com/yusys-ai/yucode/main/install.sh | YUCODE_ACTION=uninstall sh
```

On Windows, uninstall with:

```powershell
$env:YUCODE_ACTION = 'uninstall'
irm https://raw.githubusercontent.com/yusys-ai/yucode/main/install.ps1 | iex
Remove-Item Env:YUCODE_ACTION
```

During `install`, the native release is installed and verified before a
confirmed user-managed global installation of `@yusys-ai/yucode` is removed.
System-level and ambiguous npm installations are never removed and are reported
with manual guidance.

Uninstall removes only installer-managed binaries, state, and PATH entries.
User data under `~/.yucode` is kept.

## Release channels

New installations use the `default` channel. Before the first stable release,
`default` follows `rc`; afterward it follows `stable`. Set
`YUCODE_CHANNEL=stable` or `YUCODE_CHANNEL=rc` before running the installer to
select another channel, or set `YUCODE_VERSION` to install an exact version.
Repeated installs retain the installed channel. After a release candidate
becomes stable, the `rc` channel advances to that stable version so prerelease
users can graduate by rerunning the installer.

Downgrades are rejected unless `YUCODE_ALLOW_DOWNGRADE=1` is set. Set
`YUCODE_NO_MODIFY_PATH=1` to manage PATH yourself.

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
