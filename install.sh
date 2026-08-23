#!/bin/sh

set -eu

PRODUCT="Yusys CodeMate"
REPOSITORY="yusys-ai/yucode"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/main"
RELEASE_BASE="https://github.com/${REPOSITORY}/releases/download"
PATH_BEGIN="# >>> yucode installer >>>"
PATH_END="# <<< yucode installer <<<"

fail() {
	printf 'yucode installer: %s\n' "$*" >&2
	exit 1
}

info() {
	printf '%s\n' "$*"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_version() {
	printf '%s\n' "$1" | LC_ALL=C grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$'
}

compare_versions() {
	LC_ALL=C awk -v left="$1" -v right="$2" '
		function decimal_compare(a, b) {
			if (length(a) < length(b)) return -1
			if (length(a) > length(b)) return 1
			if (a == b) return 0
			return ("x" a < "x" b) ? -1 : 1
		}
		function compare_core(a, b, left_core, right_core, left_parts, right_parts, part_index, result) {
			split(a, left_core, "-")
			split(b, right_core, "-")
			split(left_core[1], left_parts, ".")
			split(right_core[1], right_parts, ".")
			for (part_index = 1; part_index <= 3; part_index++) {
				result = decimal_compare(left_parts[part_index], right_parts[part_index])
				if (result != 0) return result
			}
			if (left_core[2] == "" && right_core[2] == "") return 0
			if (left_core[2] == "") return 1
			if (right_core[2] == "") return -1
			return decimal_compare(substr(left_core[2], 3), substr(right_core[2], 3))
		}
		BEGIN { print compare_core(left, right) }
	'
}

download() {
	curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 --output "$2" "$1"
}

read_manifest_version() {
	LC_ALL=C awk -F '"' '
		$2 == "version" { count++; version = $4 }
		END {
			if (count != 1) exit 1
			print version
		}
	' "$1"
}

read_manifest_name() {
	LC_ALL=C awk -F '"' '
		$2 == "name" { count++; name = $4 }
		END {
			if (count != 1) exit 1
			print name
		}
	' "$1"
}

inspect_global_npm_install() {
	NPM_INSTALL_STATUS=absent
	NPM_INSTALL_REASON=
	NPM_COMMAND=
	NPM_PREFIX=
	NPM_ROOT=
	NPM_PACKAGE_DIRECTORY=
	command -v npm >/dev/null 2>&1 || return 0
	NPM_COMMAND="$(command -v npm)"
	if ! NPM_ROOT="$(npm root -g 2>/dev/null)" || ! NPM_PREFIX="$(npm prefix -g 2>/dev/null)"; then
		NPM_INSTALL_STATUS=unsafe
		NPM_INSTALL_REASON="Unable to resolve the active global npm installation"
		return 0
	fi
	case "$NPM_ROOT:$NPM_PREFIX" in
		/*:/*) ;;
		*)
			NPM_INSTALL_STATUS=unsafe
			NPM_INSTALL_REASON="The active global npm paths are not absolute"
			return 0
			;;
	esac
	if printf '%s\n%s\n' "$NPM_ROOT" "$NPM_PREFIX" | LC_ALL=C grep -q '[[:cntrl:]]'; then
		NPM_INSTALL_STATUS=unsafe
		NPM_INSTALL_REASON="The active global npm paths contain unsupported characters"
		return 0
	fi
	NPM_PACKAGE_DIRECTORY="$NPM_ROOT/@yusys-ai/yucode"
	if [ -L "$NPM_ROOT/@yusys-ai" ]; then
		NPM_INSTALL_STATUS=unsafe
		NPM_INSTALL_REASON="The global npm package scope is a symbolic link: $NPM_ROOT/@yusys-ai"
		return 0
	fi
	if [ ! -e "$NPM_PACKAGE_DIRECTORY" ] && [ ! -L "$NPM_PACKAGE_DIRECTORY" ]; then
		return 0
	fi
	manifest="$NPM_PACKAGE_DIRECTORY/package.json"
	if [ ! -d "$NPM_PACKAGE_DIRECTORY" ] || [ -L "$NPM_PACKAGE_DIRECTORY" ] \
		|| [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
		NPM_INSTALL_STATUS=unsafe
		NPM_INSTALL_REASON="The global npm package path is not a regular package directory: $NPM_PACKAGE_DIRECTORY"
		return 0
	fi
	package_name="$(read_manifest_name "$manifest" 2>/dev/null || true)"
	if [ "$package_name" != "@yusys-ai/yucode" ]; then
		NPM_INSTALL_STATUS=unsafe
		NPM_INSTALL_REASON="The global npm package manifest is not @yusys-ai/yucode: $manifest"
		return 0
	fi
	NPM_INSTALL_STATUS=verified
}

user_path_has_no_symlinks() {
	candidate="$1"
	case "$candidate" in
		"$HOME") return 0 ;;
		"$HOME"/*) remainder="${candidate#"$HOME"/}" ;;
		*) return 1 ;;
	esac
	current="$HOME"
	while [ -n "$remainder" ]; do
		case "$remainder" in
			*/*)
				component="${remainder%%/*}"
				remainder="${remainder#*/}"
				;;
			*)
				component="$remainder"
				remainder=
				;;
		esac
		case "$component" in '' | . | ..) return 1 ;; esac
		current="$current/$component"
		[ ! -L "$current" ] || return 1
	done
	return 0
}

validate_install_paths() {
	for managed_path in "$INSTALL_ROOT" "$STATE_DIRECTORY" "$VERSIONS_DIRECTORY" "$BIN_DIRECTORY"; do
		user_path_has_no_symlinks "$managed_path" || fail "Managed path passes through a symbolic link: $managed_path"
	done
}

npm_install_is_user_manageable() {
	NPM_MANAGE_REASON=
	if [ "$(id -u)" -eq 0 ]; then
		NPM_MANAGE_REASON="Migration will not remove a global npm package from a root session"
		return 1
	fi
	npm_scope_directory="$NPM_ROOT/@yusys-ai"
	npm_bin_directory="$NPM_PREFIX/bin"
	for directory in "$NPM_PREFIX" "$NPM_ROOT" "$npm_scope_directory" "$NPM_PACKAGE_DIRECTORY" "$npm_bin_directory"; do
		if ! user_path_has_no_symlinks "$directory"; then
			NPM_MANAGE_REASON="The global npm installation escapes the user home or passes through a symbolic link: $directory"
			return 1
		fi
		if [ ! -d "$directory" ] || [ -L "$directory" ] || [ ! -w "$directory" ]; then
			NPM_MANAGE_REASON="The global npm installation is not user-manageable: $NPM_PACKAGE_DIRECTORY"
			return 1
		fi
	done
	return 0
}

manual_npm_removal() {
	printf '%s\n' "Remove it manually after reviewing its permissions: npm uninstall -g --ignore-scripts @yusys-ai/yucode"
}

verify_checksum() {
	expected_hash="$(LC_ALL=C awk -v filename="$2" '
		NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ { exit 1 }
		$2 == filename { count++; hash = $1 }
		END {
			if (count != 1) exit 1
			print hash
		}
	' "$1")" || fail "Invalid SHA256SUMS"
	if command -v sha256sum >/dev/null 2>&1; then
		actual_hash="$(sha256sum "$3" | awk '{print $1}')"
	else
		require_command shasum
		actual_hash="$(shasum -a 256 "$3" | awk '{print $1}')"
	fi
	[ "$actual_hash" = "$expected_hash" ] || fail "Checksum mismatch for $2"
}

validate_tar_archive() {
	archive="$1"
	listing="$2"
	types="$3"
	tar -tzf "$archive" > "$listing" || fail "Unable to list release archive"
	[ -s "$listing" ] || fail "Release archive is empty"
	while IFS= read -r entry || [ -n "$entry" ]; do
		case "$entry" in
			yucode | yucode/*) ;;
			*) fail "Release archive contains a path outside yucode/: $entry" ;;
		esac
		case "$entry" in
			/* | *\\* | *//* ) fail "Release archive contains an unsafe path: $entry" ;;
		esac
		case "/$entry/" in
			*/./* | */../*) fail "Release archive contains an unsafe path: $entry" ;;
		esac
	done < "$listing"
	tar -tvzf "$archive" > "$types" || fail "Unable to inspect release archive"
	LC_ALL=C awk 'substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { exit 1 }' "$types" \
		|| fail "Release archive contains links or special files"
}

managed_wrapper() {
	expected_version="${1:-}"
	[ -f "$WRAPPER" ] && [ ! -L "$WRAPPER" ] && LC_ALL=C awk -v expected_version="$expected_version" '
		NR == 1 && $0 != "#!/bin/sh" { exit 1 }
		NR == 2 && $0 != "# YUCODE_INSTALLER_MANAGED=1" { exit 1 }
		NR == 3 && $0 != "set -eu" { exit 1 }
		NR == 4 && $0 != ": \"${HOME:?HOME must be set}\"" { exit 1 }
		NR == 5 {
			if ($0 !~ /^version=(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$/) exit 1
			if (expected_version != "" && $0 != "version=" expected_version) exit 1
		}
		NR == 6 && $0 != "exec \"${HOME}/.local/share/yucode/versions/${version}/yucode\" \"$@\"" { exit 1 }
		NR > 6 { exit 1 }
		END { if (NR != 6) exit 1 }
	' "$WRAPPER"
}

managed_profile_block() {
	[ -f "$1" ] && [ ! -L "$1" ] && LC_ALL=C awk -v begin="$PATH_BEGIN" -v end="$PATH_END" \
		-v first='case ":$PATH:" in' \
		-v second='  *":$HOME/.local/bin:"*) ;;' \
		-v third='  *) export PATH="$HOME/.local/bin:$PATH" ;;' '
		$0 == begin {
			if (found || inside) exit 1
			found = 1
			inside = 1
			next
		}
		$0 == end && !inside { exit 1 }
		inside == 1 { if ($0 != first) exit 1; inside = 2; next }
		inside == 2 { if ($0 != second) exit 1; inside = 3; next }
		inside == 3 { if ($0 != third) exit 1; inside = 4; next }
		inside == 4 { if ($0 != "esac") exit 1; inside = 5; next }
		inside == 5 {
			if ($0 != end) exit 1
			inside = 0
			next
		}
		END { if (found != 1 || inside) exit 1 }
	' "$1"
}

managed_fish_file() {
	[ -f "$1" ] && [ ! -L "$1" ] && LC_ALL=C awk '
		NR == 1 && $0 != "# YUCODE_INSTALLER_MANAGED=1" { exit 1 }
		NR == 2 && $0 != "fish_add_path --path \"$HOME/.local/bin\"" { exit 1 }
		NR > 2 { exit 1 }
		END { if (NR != 2) exit 1 }
	' "$1"
}

write_wrapper() {
	version="$1"
	user_path_has_no_symlinks "$BIN_DIRECTORY" || fail "Managed bin path passes through a symbolic link: $BIN_DIRECTORY"
	user_path_has_no_symlinks "$WRAPPER" || fail "Managed command path passes through a symbolic link: $WRAPPER"
	mkdir -p "$BIN_DIRECTORY"
	user_path_has_no_symlinks "$WRAPPER" || fail "Managed command path passes through a symbolic link: $WRAPPER"
	if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
		managed_wrapper || fail "Refusing to replace an unmanaged command: $WRAPPER"
	fi
	wrapper_temp="$(mktemp "${WRAPPER}.tmp.XXXXXX")" || fail "Unable to create command wrapper"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' '# YUCODE_INSTALLER_MANAGED=1'
		printf '%s\n' 'set -eu'
		printf '%s\n' ": \"\${HOME:?HOME must be set}\""
		printf 'version=%s\n' "$version"
		printf '%s\n' "exec \"\${HOME}/.local/share/yucode/versions/\${version}/yucode\" \"\$@\""
	} > "$wrapper_temp"
	chmod 755 "$wrapper_temp"
	mv -f "$wrapper_temp" "$WRAPPER"
}

known_profile() {
	case "$1" in
		"$HOME/.profile" | "$HOME/.bashrc" | "$HOME/.bash_profile" | "$HOME/.zshrc" | "$HOME/.zprofile") return 0 ;;
		*) return 1 ;;
	esac
}

remove_profile_block() {
	profile="$1"
	if [ -L "$profile" ]; then
		info "Warning: symbolic-link shell profile was not modified: $profile"
		info "Remove the yucode installer PATH block from its target manually."
		return 0
	fi
	[ -f "$profile" ] || return 0
	begin_count="$(grep -Fxc "$PATH_BEGIN" "$profile" || true)"
	end_count="$(grep -Fxc "$PATH_END" "$profile" || true)"
	if [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
		return 0
	fi
	[ "$begin_count" -eq 1 ] && [ "$end_count" -eq 1 ] || fail "Managed PATH block was modified: $profile"
	managed_profile_block "$profile" || fail "Managed PATH block was modified: $profile"
	profile_temp="$(mktemp "${profile}.yucode.XXXXXX")"
	LC_ALL=C awk -v begin="$PATH_BEGIN" -v end="$PATH_END" '
		$0 == begin { inside = 1; next }
		$0 == end {
			if (!inside) exit 1
			inside = 0
			next
		}
		!inside { print }
		END { if (inside) exit 1 }
	' "$profile" > "$profile_temp" || {
		rm -f "$profile_temp"
		fail "Managed PATH block was modified: $profile"
	}
	if mode="$(stat -f '%Lp' "$profile" 2>/dev/null)"; then
		chmod "$mode" "$profile_temp"
	elif mode="$(stat -c '%a' "$profile" 2>/dev/null)"; then
		chmod "$mode" "$profile_temp"
	fi
	mv -f "$profile_temp" "$profile"
}

configure_path() {
	user_path_has_no_symlinks "$STATE_DIRECTORY" || fail "Managed state path passes through a symbolic link: $STATE_DIRECTORY"
	mkdir -p "$STATE_DIRECTORY"
	user_path_has_no_symlinks "$STATE_DIRECTORY" || fail "Managed state path passes through a symbolic link: $STATE_DIRECTORY"
	if [ -f "$STATE_DIRECTORY/path-kind" ]; then
		existing_path_kind="$(sed -n '1p' "$STATE_DIRECTORY/path-kind")"
		case "$existing_path_kind" in
			profile)
				[ -f "$STATE_DIRECTORY/path-file" ] || fail "Managed PATH state is incomplete"
				profile="$(sed -n '1p' "$STATE_DIRECTORY/path-file")"
				known_profile "$profile" || fail "Managed PATH state contains an unexpected profile"
				[ ! -L "$profile" ] || fail "Shell profile is a symbolic link and was not modified: $profile. Set YUCODE_NO_MODIFY_PATH=1 and add $BIN_DIRECTORY to PATH manually."
				if ! managed_profile_block "$profile"; then
					fail "Managed PATH block was modified: $profile"
				fi
				return
				;;
			fish)
				[ -f "$STATE_DIRECTORY/path-file" ] || fail "Managed PATH state is incomplete"
				fish_file="$(sed -n '1p' "$STATE_DIRECTORY/path-file")"
				if [ "$fish_file" != "$HOME/.config/fish/conf.d/yucode.fish" ] || ! managed_fish_file "$fish_file"; then
					fail "Managed fish PATH file was modified: $fish_file"
				fi
				return
				;;
		esac
	fi
	case ":${PATH:-}:" in
		*":$BIN_DIRECTORY:"*)
			write_state path-kind none
			return
			;;
	esac
	if [ "${YUCODE_NO_MODIFY_PATH:-0}" = "1" ]; then
		write_state path-kind none
		return
	fi
	shell_name="${SHELL##*/}"
	if [ "$shell_name" = "fish" ]; then
		fish_directory="$HOME/.config/fish/conf.d"
		fish_file="$fish_directory/yucode.fish"
		mkdir -p "$fish_directory"
		if [ -e "$fish_file" ] || [ -L "$fish_file" ]; then
			managed_fish_file "$fish_file" || fail "Refusing to replace an unmanaged file: $fish_file"
		fi
		{
			printf '%s\n' '# YUCODE_INSTALLER_MANAGED=1'
			printf '%s\n' "fish_add_path --path \"\$HOME/.local/bin\""
		} > "$fish_file"
		write_state path-file "$fish_file"
		write_state path-kind fish
		return
	fi
	case "$shell_name" in
		zsh) profile="$HOME/.zshrc" ;;
		bash)
			if [ "$(uname -s)" = "Darwin" ]; then profile="$HOME/.bash_profile"; else profile="$HOME/.bashrc"; fi
			;;
		*) profile="$HOME/.profile" ;;
	esac
	[ ! -L "$profile" ] || fail "Shell profile is a symbolic link and was not modified: $profile. Set YUCODE_NO_MODIFY_PATH=1 and add $BIN_DIRECTORY to PATH manually."
	if [ -e "$profile" ] && [ ! -f "$profile" ]; then
		fail "Shell profile is not a regular file: $profile"
	fi
	if [ -f "$profile" ]; then
		begin_count="$(grep -Fxc "$PATH_BEGIN" "$profile" || true)"
		end_count="$(grep -Fxc "$PATH_END" "$profile" || true)"
		[ "$begin_count" -eq "$end_count" ] || fail "Managed PATH block was modified: $profile"
		[ "$begin_count" -le 1 ] || fail "Managed PATH block is duplicated: $profile"
		if [ "$begin_count" -eq 1 ]; then managed_profile_block "$profile" || fail "Managed PATH block was modified: $profile"; fi
	else
		: > "$profile"
		begin_count=0
	fi
	if [ "$begin_count" -eq 0 ]; then
		{
			printf '\n%s\n' "$PATH_BEGIN"
			printf '%s\n' "case \":\$PATH:\" in"
			printf '%s\n' "  *\":\$HOME/.local/bin:\"*) ;;"
			printf '%s\n' "  *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;;"
			printf '%s\n' 'esac'
			printf '%s\n' "$PATH_END"
		} >> "$profile"
	fi
	write_state path-file "$profile"
	write_state path-kind profile
}

remove_managed_path() {
	[ -f "$STATE_DIRECTORY/path-kind" ] || return 0
	path_kind="$(sed -n '1p' "$STATE_DIRECTORY/path-kind")"
	case "$path_kind" in
		none) return 0 ;;
		profile)
			[ -f "$STATE_DIRECTORY/path-file" ] || fail "Managed PATH state is incomplete"
			profile="$(sed -n '1p' "$STATE_DIRECTORY/path-file")"
			known_profile "$profile" || fail "Managed PATH state contains an unexpected profile"
			remove_profile_block "$profile"
			;;
		fish)
			[ -f "$STATE_DIRECTORY/path-file" ] || fail "Managed PATH state is incomplete"
			fish_file="$(sed -n '1p' "$STATE_DIRECTORY/path-file")"
			[ "$fish_file" = "$HOME/.config/fish/conf.d/yucode.fish" ] || fail "Managed PATH state contains an unexpected fish file"
			if [ -e "$fish_file" ]; then
				if ! managed_fish_file "$fish_file"; then
					fail "Managed fish PATH file was modified: $fish_file"
				fi
				rm -f "$fish_file"
			fi
			;;
		*) fail "Managed PATH state is invalid" ;;
	esac
}

write_state() {
	name="$1"
	value="$2"
	path="$STATE_DIRECTORY/$name"
	user_path_has_no_symlinks "$path" || fail "Managed state path passes through a symbolic link: $path"
	if [ -e "$path" ] || [ -L "$path" ]; then
		[ -f "$path" ] && [ ! -L "$path" ] || fail "Managed state path is not a regular file: $path"
	fi
	temporary="$(mktemp "$STATE_DIRECTORY/.${name}.XXXXXX")" || fail "Unable to create managed state file"
	if ! printf '%s\n' "$value" > "$temporary" || ! mv -f "$temporary" "$path"; then
		rm -f "$temporary"
		fail "Unable to write managed state: $path"
	fi
}

validate_state_files() {
	user_path_has_no_symlinks "$STATE_DIRECTORY" || fail "Managed state path passes through a symbolic link: $STATE_DIRECTORY"
	for name in managed version channel path-kind path-file; do
		path="$STATE_DIRECTORY/$name"
		user_path_has_no_symlinks "$path" || fail "Managed state path passes through a symbolic link: $path"
		if [ -e "$path" ] || [ -L "$path" ]; then
			[ -f "$path" ] && [ ! -L "$path" ] || fail "Managed state path is not a regular file: $path"
		fi
	done
}

cleanup() {
	status=$?
	trap - 0 1 2 15
	if [ -n "${STAGING_DIRECTORY:-}" ] && user_path_has_no_symlinks "$STAGING_DIRECTORY" && [ -d "$STAGING_DIRECTORY" ] && [ ! -L "$STAGING_DIRECTORY" ]; then
		rm -rf "$STAGING_DIRECTORY"
	fi
	if [ "${LOCK_HELD:-0}" = "1" ]; then
		if user_path_has_no_symlinks "$LOCK_DIRECTORY" && [ ! -L "$LOCK_DIRECTORY" ]; then
			rm -f "$LOCK_DIRECTORY/pid"
			rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
		fi
	fi
	exit "$status"
}

acquire_lock() {
	user_path_has_no_symlinks "$LOCK_DIRECTORY" || fail "Installer lock path passes through a symbolic link: $LOCK_DIRECTORY"
	mkdir -p "$LOCK_PARENT"
	user_path_has_no_symlinks "$LOCK_DIRECTORY" || fail "Installer lock path passes through a symbolic link: $LOCK_DIRECTORY"
	if [ -L "$LOCK_DIRECTORY" ]; then
		fail "Installer lock must not be a symlink: $LOCK_DIRECTORY"
	fi
	if ! mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
		lock_pid="$(sed -n '1p' "$LOCK_DIRECTORY/pid" 2>/dev/null || true)"
		case "$lock_pid" in
			'' | *[!0-9]*) fail "Another yucode installer is active" ;;
		esac
		if kill -0 "$lock_pid" 2>/dev/null; then
			fail "Another yucode installer is active (PID $lock_pid)"
		fi
		rm -f "$LOCK_DIRECTORY/pid"
		rmdir "$LOCK_DIRECTORY" 2>/dev/null || fail "Unable to remove a stale installer lock"
		mkdir "$LOCK_DIRECTORY" || fail "Unable to acquire installer lock"
	fi
	user_path_has_no_symlinks "$LOCK_DIRECTORY" || fail "Installer lock path passes through a symbolic link: $LOCK_DIRECTORY"
	printf '%s\n' "$$" > "$LOCK_DIRECTORY/pid"
	LOCK_HELD=1
}

detect_platform() {
	case "$(uname -s)" in
		Darwin) os=darwin ;;
		Linux)
			os=linux
			require_command getconf
			case "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)" in
				glibc\ *) ;;
				*) fail "Linux standalone builds require glibc; musl and Termux are not supported" ;;
			esac
			;;
		*) fail "Unsupported operating system: $(uname -s)" ;;
	esac
	case "$(uname -m)" in
		arm64 | aarch64) architecture=arm64 ;;
		x86_64 | amd64) architecture=x64 ;;
		*) fail "Unsupported architecture: $(uname -m)" ;;
	esac
	PLATFORM="${os}-${architecture}"
}

resolve_version() {
	if [ -n "${YUCODE_VERSION:-}" ]; then
		VERSION="$YUCODE_VERSION"
	else
		channel_file="$STAGING_DIRECTORY/channel"
		download "$RAW_BASE/channels/$CHANNEL" "$channel_file"
		line_count="$(LC_ALL=C awk 'END { print NR }' "$channel_file")"
		[ "$line_count" -eq 1 ] || fail "Channel $CHANNEL is invalid"
		VERSION="$(sed -n '1p' "$channel_file")"
	fi
	validate_version "$VERSION" || fail "Invalid release version: $VERSION"
}

validate_native_payload() {
	require_wrapper="${1:-1}"
	validate_install_paths
	[ -f "$STATE_DIRECTORY/version" ] || fail "Managed installation state is incomplete"
	native_version="$(sed -n '1p' "$STATE_DIRECTORY/version")"
	validate_version "$native_version" || fail "Installed version state is invalid"
	native_directory="$VERSIONS_DIRECTORY/$native_version"
	native_binary="$native_directory/yucode"
	[ -d "$native_directory" ] && [ ! -L "$native_directory" ] && [ -x "$native_binary" ] && [ ! -L "$native_binary" ] \
		|| fail "Native installation is incomplete: $native_version"
	native_manifest="$native_directory/package.json"
	[ -f "$native_manifest" ] && [ ! -L "$native_manifest" ] || fail "Native installation manifest is missing"
	native_name="$(read_manifest_name "$native_manifest")" || fail "Native installation manifest is invalid"
	native_manifest_version="$(read_manifest_version "$native_manifest")" || fail "Native installation manifest is invalid"
	[ "$native_name" = "@yusys-ai/yucode" ] && [ "$native_manifest_version" = "$native_version" ] \
		|| fail "Native installation manifest does not match $native_version"
	if [ "$require_wrapper" = "1" ]; then
		managed_wrapper "$native_version" || fail "Native command wrapper is incomplete: $WRAPPER"
	fi
	reported_version="$("$native_binary" --version)" || fail "Native installation did not start"
	[ "$reported_version" = "$native_version" ] \
		|| fail "Native installation reported $reported_version, expected $native_version"
	"$native_binary" --help >/dev/null || fail "Native installation help smoke failed"
}

migrate_global_npm_install() {
	if [ "${DEFER_WRAPPER:-0}" = "1" ]; then
		validate_native_payload 0
	else
		validate_native_payload 1
	fi
	inspect_global_npm_install
	case "$NPM_INSTALL_STATUS" in
		absent)
			if [ "${DEFER_WRAPPER:-0}" = "1" ]; then
				if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
					fail "Native payload is ready, but no verified global @yusys-ai/yucode installation owns $WRAPPER. Remove it manually, then rerun install."
				fi
				write_wrapper "$VERSION"
				validate_native_payload 1
			fi
			return
			;;
		unsafe)
			if [ "${DEFER_WRAPPER:-0}" = "1" ]; then
				fail "Native payload is ready, but npm migration stopped: $NPM_INSTALL_REASON. $(manual_npm_removal)"
			fi
			info "Warning: $NPM_INSTALL_REASON. It was not changed. $(manual_npm_removal)"
			return
			;;
	esac
	if ! npm_install_is_user_manageable; then
		if [ "${DEFER_WRAPPER:-0}" = "1" ]; then
			fail "Native payload is ready, but npm migration stopped: $NPM_MANAGE_REASON. $(manual_npm_removal)"
		fi
		info "Warning: $NPM_MANAGE_REASON. It was not changed. $(manual_npm_removal)"
		return
	fi
	if ! "$NPM_COMMAND" uninstall -g --ignore-scripts @yusys-ai/yucode; then
		fail "Native installation is ready, but npm uninstall failed. $(manual_npm_removal)"
	fi
	if [ -e "$NPM_PACKAGE_DIRECTORY" ] || [ -L "$NPM_PACKAGE_DIRECTORY" ]; then
		fail "Native installation is ready, but the global npm package remains at $NPM_PACKAGE_DIRECTORY. $(manual_npm_removal)"
	fi
	if [ "${DEFER_WRAPPER:-0}" = "1" ]; then
		if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
			fail "npm uninstall left a conflicting command at $WRAPPER. Remove it manually, then rerun install."
		fi
		write_wrapper "$VERSION"
	fi
	managed_wrapper "$VERSION" || fail "Native command wrapper is incomplete: $WRAPPER"
	validate_native_payload 1
	info "Removed the global npm installation of @yusys-ai/yucode."
}

uninstall() {
	validate_install_paths
	wrapper_version=
	if [ -e "$INSTALL_ROOT" ] || [ -L "$INSTALL_ROOT" ]; then
		[ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] || fail "Refusing to remove an unmanaged path: $INSTALL_ROOT"
		validate_state_files
		[ -f "$STATE_DIRECTORY/managed" ] || fail "Refusing to remove an unmanaged directory: $INSTALL_ROOT"
		[ "$(sed -n '1p' "$STATE_DIRECTORY/managed")" = "1" ] || fail "Managed installation marker is invalid"
		if [ -f "$STATE_DIRECTORY/version" ]; then
			wrapper_version="$(sed -n '1p' "$STATE_DIRECTORY/version")"
			validate_version "$wrapper_version" || fail "Installed version state is invalid"
		fi
	fi
	if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
		managed_wrapper "$wrapper_version" || fail "Refusing to remove an unmanaged command: $WRAPPER"
	fi
	if [ -d "$INSTALL_ROOT" ]; then
		remove_managed_path
	fi
	validate_install_paths
	if [ -e "$WRAPPER" ]; then rm -f "$WRAPPER"; fi
	if [ -d "$INSTALL_ROOT" ]; then rm -rf "$INSTALL_ROOT"; fi
	info "$PRODUCT was uninstalled. User data under $HOME/.yucode was kept."
}

install() {
	DEFER_WRAPPER=0
	validate_install_paths
	if [ -e "$INSTALL_ROOT" ]; then
		[ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] || fail "Install root is not a managed directory: $INSTALL_ROOT"
		if [ ! -f "$STATE_DIRECTORY/managed" ]; then
			[ -z "$(find "$INSTALL_ROOT" -mindepth 1 -print -quit)" ] || fail "Refusing to use a non-empty unmanaged directory: $INSTALL_ROOT"
		fi
	fi
	if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
		if ! managed_wrapper; then
			inspect_global_npm_install
			if [ -n "$NPM_PREFIX" ] && [ "$WRAPPER" = "$NPM_PREFIX/bin/yucode" ] \
				&& { [ "$NPM_INSTALL_STATUS" = "verified" ] || [ "$NPM_INSTALL_STATUS" = "unsafe" ]; }; then
				DEFER_WRAPPER=1
			else
				fail "Refusing to replace an unmanaged command: $WRAPPER"
			fi
		fi
	fi
	mkdir -p "$STATE_DIRECTORY" "$VERSIONS_DIRECTORY"
	validate_install_paths
	validate_state_files
	write_state managed 1
	if [ -z "${YUCODE_CHANNEL:-}" ] && [ -f "$STATE_DIRECTORY/channel" ]; then
		CHANNEL="$(sed -n '1p' "$STATE_DIRECTORY/channel")"
	fi
	case "$CHANNEL" in default | stable | rc) ;; *) fail "Invalid channel: $CHANNEL" ;; esac
	validate_install_paths
	STAGING_DIRECTORY="$(mktemp -d "$INSTALL_ROOT/.staging.XXXXXX")"
	user_path_has_no_symlinks "$STAGING_DIRECTORY" || fail "Staging path passes through a symbolic link: $STAGING_DIRECTORY"
	resolve_version
	if [ -f "$STATE_DIRECTORY/version" ]; then
		current_version="$(sed -n '1p' "$STATE_DIRECTORY/version")"
		validate_version "$current_version" || fail "Installed version state is invalid"
		comparison="$(compare_versions "$VERSION" "$current_version")"
		if [ "$comparison" -lt 0 ] && [ "${YUCODE_ALLOW_DOWNGRADE:-0}" != "1" ]; then
			fail "Refusing to downgrade from $current_version to $VERSION; set YUCODE_ALLOW_DOWNGRADE=1 to override"
		fi
	fi
	version_directory="$VERSIONS_DIRECTORY/$VERSION"
	if [ -e "$version_directory" ]; then
		[ -d "$version_directory" ] && [ ! -L "$version_directory" ] || fail "Version path is not a managed directory: $version_directory"
		[ -x "$version_directory/yucode" ] && [ ! -L "$version_directory/yucode" ] \
			|| fail "Installed version is incomplete: $VERSION"
		[ -f "$version_directory/package.json" ] && [ ! -L "$version_directory/package.json" ] \
			|| fail "Installed version manifest is invalid: $VERSION"
		installed_manifest_name="$(read_manifest_name "$version_directory/package.json")" \
			|| fail "Installed version manifest is invalid: $VERSION"
		installed_manifest_version="$(read_manifest_version "$version_directory/package.json")" \
			|| fail "Installed version manifest is invalid: $VERSION"
		[ "$installed_manifest_name" = "@yusys-ai/yucode" ] && [ "$installed_manifest_version" = "$VERSION" ] \
			|| fail "Installed version manifest does not match $VERSION"
	else
		detect_platform
		asset="yucode-${PLATFORM}.tar.gz"
		archive="$STAGING_DIRECTORY/$asset"
		checksums="$STAGING_DIRECTORY/SHA256SUMS"
		download "$RELEASE_BASE/v$VERSION/$asset" "$archive"
		download "$RELEASE_BASE/v$VERSION/SHA256SUMS" "$checksums"
		verify_checksum "$checksums" "$asset" "$archive"
		validate_tar_archive "$archive" "$STAGING_DIRECTORY/archive.list" "$STAGING_DIRECTORY/archive.types"
		extract_directory="$STAGING_DIRECTORY/extract"
		mkdir "$extract_directory"
		tar -xzf "$archive" -C "$extract_directory"
		[ -z "$(find "$extract_directory/yucode" -type l -print -quit)" ] || fail "Release archive contains a symbolic link"
		for required in yucode package.json README.md LICENSE THIRD_PARTY_NOTICES.md; do
			[ -e "$extract_directory/yucode/$required" ] || fail "Release archive is missing yucode/$required"
		done
		[ -d "$extract_directory/yucode/LICENSES" ] || fail "Release archive is missing yucode/LICENSES"
		manifest_name="$(read_manifest_name "$extract_directory/yucode/package.json")" \
			|| fail "Release package manifest is invalid"
		manifest_version="$(read_manifest_version "$extract_directory/yucode/package.json")" \
			|| fail "Release package manifest is invalid"
		[ "$manifest_name" = "@yusys-ai/yucode" ] && [ "$manifest_version" = "$VERSION" ] \
			|| fail "Release package manifest does not match $VERSION"
		chmod 755 "$extract_directory/yucode/yucode"
		if [ "$(uname -s)" = "Linux" ]; then
			reported_version="$("$extract_directory/yucode/yucode" --version)" || fail "Release binary did not start"
			[ "$reported_version" = "$VERSION" ] || fail "Release binary reported $reported_version, expected $VERSION"
			"$extract_directory/yucode/yucode" --help >/dev/null || fail "Release binary help smoke failed"
		fi
		user_path_has_no_symlinks "$version_directory" || fail "Version path passes through a symbolic link: $version_directory"
		mv "$extract_directory/yucode" "$version_directory"
	fi
	configure_path
	write_state version "$VERSION"
	write_state channel "$CHANNEL"
	if [ "$DEFER_WRAPPER" = "0" ]; then write_wrapper "$VERSION"; fi
}

umask 077
: "${HOME:?HOME must be set}"
require_command grep
require_command id
[ "$(id -u)" -ne 0 ] || fail "Run the installer as your normal user, without sudo"
case "$HOME" in
	/*) ;;
	*) fail "HOME must be an absolute path" ;;
esac
if printf '%s' "$HOME" | LC_ALL=C grep -q '[[:cntrl:]]'; then fail "HOME contains unsupported characters"; fi
[ -d "$HOME" ] && [ ! -L "$HOME" ] || fail "HOME must be a directory and must not be a symbolic link"

ACTION="${YUCODE_ACTION:-install}"
if [ "$#" -gt 1 ]; then fail "Usage: install.sh [install|uninstall]"; fi
if [ "$#" -eq 1 ]; then ACTION="$1"; fi
case "$ACTION" in install | uninstall) ;; *) fail "Invalid action: $ACTION" ;; esac
case "${YUCODE_NO_MODIFY_PATH:-0}" in 0 | 1) ;; *) fail "YUCODE_NO_MODIFY_PATH must be 0 or 1" ;; esac
case "${YUCODE_ALLOW_DOWNGRADE:-0}" in 0 | 1) ;; *) fail "YUCODE_ALLOW_DOWNGRADE must be 0 or 1" ;; esac

INSTALL_ROOT="$HOME/.local/share/yucode"
STATE_DIRECTORY="$INSTALL_ROOT/state"
VERSIONS_DIRECTORY="$INSTALL_ROOT/versions"
BIN_DIRECTORY="$HOME/.local/bin"
WRAPPER="$BIN_DIRECTORY/yucode"
LOCK_PARENT="$HOME/.local/share"
LOCK_DIRECTORY="$LOCK_PARENT/.yucode-install-lock"
LOCK_HELD=0
STAGING_DIRECTORY=
CHANNEL="${YUCODE_CHANNEL:-default}"

validate_install_paths
user_path_has_no_symlinks "$LOCK_DIRECTORY" || fail "Installer lock path passes through a symbolic link: $LOCK_DIRECTORY"

require_command awk
require_command mkdir
require_command mktemp
require_command sed
require_command stat
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15
acquire_lock

if [ "$ACTION" = "uninstall" ]; then
	uninstall
else
	require_command curl
	require_command find
	require_command tar
	install
	migrate_global_npm_install
	info "$PRODUCT $VERSION is installed."
	resolved_command="$(command -v yucode 2>/dev/null || true)"
	if [ -n "$resolved_command" ] && [ "$resolved_command" != "$WRAPPER" ]; then
		info "Warning: the current shell resolves yucode to $resolved_command instead of $WRAPPER."
	fi
	case ":${PATH:-}:" in
		*":$BIN_DIRECTORY:"*) info "Run: yucode" ;;
		*) info "Open a new terminal, then run: yucode" ;;
	esac
	if [ "$(uname -s)" = "Darwin" ]; then
		info "If macOS blocks the first launch, use System Settings > Privacy & Security > Open Anyway."
	fi
fi
