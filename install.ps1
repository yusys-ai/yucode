$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version 2.0

$Product = "Yusys CodeMate"
$Repository = "yusys-ai/yucode"
$RawBase = "https://raw.githubusercontent.com/$Repository/main"
$ReleaseBase = "https://github.com/$Repository/releases/download"
$VersionExpression = '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?'
$VersionPattern = "^$VersionExpression`$"

function Fail {
	param([string]$Message)
	throw "yucode installer: $Message"
}

function Test-Version {
	param([string]$Version)
	return ($Version -cmatch $script:VersionPattern)
}

function Compare-Decimal {
	param([string]$Left, [string]$Right)
	if ($Left.Length -lt $Right.Length) { return -1 }
	if ($Left.Length -gt $Right.Length) { return 1 }
	return [Math]::Sign([StringComparer]::Ordinal.Compare($Left, $Right))
}

function Compare-Version {
	param([string]$Left, [string]$Right)
	$leftParts = $Left.Split('-', 2)
	$rightParts = $Right.Split('-', 2)
	$leftCore = $leftParts[0].Split('.')
	$rightCore = $rightParts[0].Split('.')
	for ($index = 0; $index -lt 3; $index++) {
		$result = Compare-Decimal $leftCore[$index] $rightCore[$index]
		if ($result -ne 0) { return $result }
	}
	if ($leftParts.Count -eq 1 -and $rightParts.Count -eq 1) { return 0 }
	if ($leftParts.Count -eq 1) { return 1 }
	if ($rightParts.Count -eq 1) { return -1 }
	return (Compare-Decimal $leftParts[1].Substring(2) $rightParts[1].Substring(2))
}

function Invoke-Download {
	param([string]$Uri, [string]$OutputPath)
	Add-Type -AssemblyName System.Net.Http
	$handler = [Net.Http.HttpClientHandler]::new()
	$handler.AllowAutoRedirect = $false
	$client = [Net.Http.HttpClient]::new($handler)
	$client.DefaultRequestHeaders.UserAgent.ParseAdd('Yusys-CodeMate-Installer')
	try {
		$current = [Uri]::new($Uri)
		for ($redirects = 0; $redirects -le 10; $redirects++) {
			if ($current.Scheme -ne [Uri]::UriSchemeHttps) { Fail "Refusing non-HTTPS download: $current" }
			$response = $client.GetAsync($current, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
			try {
				$status = [int]$response.StatusCode
				if ($status -ge 300 -and $status -lt 400) {
					$location = $response.Headers.Location
					if ($null -eq $location) { Fail "Download redirect is missing a location: $current" }
					$current = if ($location.IsAbsoluteUri) { $location } else { [Uri]::new($current, $location) }
					continue
				}
				$response.EnsureSuccessStatusCode() | Out-Null
				$inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
				$outputStream = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
				try {
					$inputStream.CopyTo($outputStream)
				} finally {
					$outputStream.Dispose()
					$inputStream.Dispose()
				}
				return
			} finally {
				$response.Dispose()
			}
		}
		Fail "Download exceeded the redirect limit: $Uri"
	} finally {
		$client.Dispose()
		$handler.Dispose()
	}
}

function Write-AtomicText {
	param([string]$Path, [string]$Content)
	$temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
	$backup = $null
	try {
		[IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
		$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
		if ($null -ne $item) {
			if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
				Fail "Managed state path is not a regular file: $Path"
			}
			$backup = "$Path.backup.$([Guid]::NewGuid().ToString('N'))"
			[IO.File]::Replace($temporary, $Path, $backup, $true)
			[IO.File]::Delete($backup)
		} else {
			[IO.File]::Move($temporary, $Path)
		}
	} finally {
		if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
		if ($null -ne $backup -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
	}
}

function Remove-SafeTree {
	param([string]$Path)
	$root = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if ($null -eq $root) { return }
	if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		Fail "Refusing to remove an unmanaged path: $Path"
	}
	$pending = [System.Collections.Generic.Stack[string]]::new()
	$directories = [System.Collections.Generic.List[string]]::new()
	$files = [System.Collections.Generic.List[string]]::new()
	$pending.Push($root.FullName)
	while ($pending.Count -gt 0) {
		$directory = $pending.Pop()
		$attributes = [IO.File]::GetAttributes($directory)
		if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
			Fail "Refusing to remove a tree containing a reparse point: $directory"
		}
		$directories.Add($directory)
		foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
			$attributes = [IO.File]::GetAttributes($entry)
			if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
				Fail "Refusing to remove a tree containing a reparse point: $entry"
			}
			if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
				$pending.Push($entry)
			} else {
				$files.Add($entry)
			}
		}
	}
	foreach ($file in $files) {
		$attributes = [IO.File]::GetAttributes($file)
		if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
			Fail "Managed file changed during removal: $file"
		}
		[IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
		[IO.File]::Delete($file)
	}
	for ($index = $directories.Count - 1; $index -ge 0; $index--) {
		$directory = $directories[$index]
		$attributes = [IO.File]::GetAttributes($directory)
		if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
			Fail "Managed directory changed during removal: $directory"
		}
		[IO.Directory]::Delete($directory, $false)
	}
}

function Get-ChannelVersion {
	param([string]$Channel, [string]$StagingDirectory)
	$channelFile = Join-Path $StagingDirectory "channel"
	Invoke-Download "$script:RawBase/channels/$Channel" $channelFile
	$content = [IO.File]::ReadAllText($channelFile, [Text.Encoding]::UTF8)
	$match = [Text.RegularExpressions.Regex]::Match($content, "\A$script:VersionExpression`n\z")
	if (-not $match.Success) { Fail "Channel $Channel is invalid" }
	return $content.Substring(0, $content.Length - 1)
}

function Get-ExpectedChecksum {
	param([string]$ChecksumPath, [string]$AssetName)
	$expected = $null
	$count = 0
	foreach ($line in [IO.File]::ReadAllLines($ChecksumPath, [Text.Encoding]::UTF8)) {
		$match = [Text.RegularExpressions.Regex]::Match($line, '^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$')
		if (-not $match.Success) { Fail "Invalid SHA256SUMS" }
		if ($match.Groups[2].Value -eq $AssetName) {
			$count++
			$expected = $match.Groups[1].Value
		}
	}
	if ($count -ne 1) { Fail "SHA256SUMS must contain exactly one entry for $AssetName" }
	return $expected
}

function Test-ZipArchive {
	param([string]$ArchivePath, [string]$ExtractionRoot)
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
	try {
		$seen = @{}
		$totalSize = [Int64]0
		$entryCount = 0
		$rootPrefix = [IO.Path]::GetFullPath($ExtractionRoot).TrimEnd('\') + '\'
		foreach ($entry in $archive.Entries) {
			$entryCount++
			if ($entryCount -gt 10000) { Fail "Release archive contains too many entries" }
			$name = $entry.FullName.Replace('\', '/')
			if ([String]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains('//') -or $name.Contains(':') -or $name -match '[\x00-\x1f]') {
				Fail "Release archive contains an unsafe path: $name"
			}
			$trimmed = $name.TrimEnd('/')
			foreach ($component in $trimmed.Split('/')) {
				if ($component.Length -eq 0 -or $component -eq '.' -or $component -eq '..') {
					Fail "Release archive contains an unsafe path: $name"
				}
			}
			if ($seen.ContainsKey($trimmed)) { Fail "Release archive contains a duplicate path: $name" }
			$seen[$trimmed] = $true
			$type = (($entry.ExternalAttributes -shr 16) -band 0xF000)
			if ($type -ne 0 -and $type -ne 0x4000 -and $type -ne 0x8000) {
				Fail "Release archive contains a link or special file: $name"
			}
			$totalSize += $entry.Length
			if ($totalSize -gt 2147483648) { Fail "Release archive is too large" }
			$destination = [IO.Path]::GetFullPath((Join-Path $ExtractionRoot $name.Replace('/', '\')))
			if (-not $destination.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
				Fail "Release archive contains an unsafe path: $name"
			}
		}
	} finally {
		$archive.Dispose()
	}
}

function Test-ManagedWrapper {
	param([string]$Path, [string]$Version)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
	$item = Get-Item -LiteralPath $Path -Force
	if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
	$versionPattern = if ([String]::IsNullOrEmpty($Version)) { $script:VersionExpression } else { [Text.RegularExpressions.Regex]::Escape($Version) }
	$pattern = '\A@echo off\r?\nrem YUCODE_INSTALLER_MANAGED=1\r?\n"%~dp0\.\.\\versions\\' + $versionPattern + '\\yucode\.exe" %\*\r?\n\z'
	return [Text.RegularExpressions.Regex]::IsMatch([IO.File]::ReadAllText($Path), $pattern)
}

function Write-Wrapper {
	param([string]$Path, [string]$Version)
	if (Test-Path -LiteralPath $Path) {
		if (-not (Test-ManagedWrapper $Path)) { Fail "Refusing to replace an unmanaged command: $Path" }
	}
	$content = @(
		'@echo off',
		'rem YUCODE_INSTALLER_MANAGED=1',
		"`"%~dp0..\versions\$Version\yucode.exe`" %*"
	) -join "`r`n"
	$content += "`r`n"
	$temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
	try {
		[IO.File]::WriteAllText($temporary, $content, [Text.ASCIIEncoding]::new())
		if (Test-Path -LiteralPath $Path) {
			$backup = "$Path.backup.$([Guid]::NewGuid().ToString('N'))"
			[IO.File]::Replace($temporary, $Path, $backup, $true)
			Remove-Item -LiteralPath $backup -Force
		} else {
			[IO.File]::Move($temporary, $Path)
		}
	} finally {
		if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
	}
}

function Get-UserPathEntries {
	param([AllowEmptyString()][string]$PathValue)
	if ([String]::IsNullOrEmpty($PathValue)) { return @() }
	return @($PathValue.Split(';'))
}

function Test-PathEntry {
	param([string[]]$Entries, [string]$Expected)
	$normalizedExpected = $Expected.TrimEnd('\')
	foreach ($entry in $Entries) {
		if ([String]::IsNullOrWhiteSpace($entry)) { continue }
		if ([StringComparer]::OrdinalIgnoreCase.Equals($entry.Trim().TrimEnd('\'), $normalizedExpected)) { return $true }
	}
	return $false
}

function Set-UserPath {
	param([string[]]$Entries)
	$value = $Entries -join ';'
	[Environment]::SetEnvironmentVariable('Path', $value, [EnvironmentVariableTarget]::User)
}

function Ensure-UserPath {
	param([string]$BinDirectory, [bool]$PreviouslyAdded, [bool]$NoModify)
	$userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
	$entries = @(Get-UserPathEntries $userPath)
	$present = Test-PathEntry $entries $BinDirectory
	if ($NoModify) { return $PreviouslyAdded -and $present }
	if ($PreviouslyAdded) {
		if (-not $present) {
			$entries += $BinDirectory
			Set-UserPath $entries
		}
		return $true
	}
	if ($present -or $NoModify) { return $false }
	$entries += $BinDirectory
	Set-UserPath $entries
	return $true
}

function Remove-UserPath {
	param([string]$BinDirectory)
	$userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
	$entries = @(Get-UserPathEntries $userPath)
	$remaining = @($entries | Where-Object { -not [StringComparer]::OrdinalIgnoreCase.Equals($_.Trim().TrimEnd('\'), $BinDirectory.TrimEnd('\')) })
	if ($remaining.Count -ne $entries.Count) { Set-UserPath $remaining }
}

function Test-PathWithin {
	param([string]$Path, [string]$Root)
	if ([String]::IsNullOrWhiteSpace($Root)) { return $false }
	$fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
	$fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
	return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathWithinWithoutReparse {
	param(
		[string]$Path,
		[string]$Root,
		[bool]$AllowMissing = $false,
		[bool]$AllowRootReparse = $false
	)
	if (-not (Test-PathWithin $Path $Root)) { return $false }
	$fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
	$fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
	$rootItem = Get-Item -LiteralPath $fullRoot -Force -ErrorAction SilentlyContinue
	if ($null -eq $rootItem -or -not $rootItem.PSIsContainer -or (-not $AllowRootReparse -and ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
	if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
	$current = $fullRoot
	$relative = $fullPath.Substring($fullRoot.Length).TrimStart('\')
	foreach ($component in $relative.Split('\')) {
		if ([String]::IsNullOrEmpty($component) -or $component -eq '.' -or $component -eq '..') { return $false }
		$current = Join-Path $current $component
		$item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
		if ($null -eq $item) {
			if ($AllowMissing) { continue }
			return $false
		}
		if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
	}
	return $true
}

function Assert-ManagedPath {
	param([string]$Path, [string]$LocalAppDataRoot, [bool]$AllowMissing)
	if (-not (Test-PathWithinWithoutReparse -Path $Path -Root $LocalAppDataRoot -AllowMissing $AllowMissing)) {
		Fail "Managed path escapes LOCALAPPDATA or passes through a reparse point: $Path"
	}
}

function Get-GlobalNpmInstallation {
	$npmCommand = Get-Command npm.cmd -All -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($null -eq $npmCommand) {
		$npmCommand = Get-Command npm -All -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
	}
	if ($null -eq $npmCommand) {
		$npmCommand = Get-Command npm -All -CommandType ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
	}
	if ($null -eq $npmCommand) { return [pscustomobject]@{ Status = 'absent' } }
	$npmPath = if ([String]::IsNullOrWhiteSpace($npmCommand.Path)) { $npmCommand.Source } else { $npmCommand.Path }
	try {
		$rootOutput = @(& $npmPath root -g 2>$null)
		$rootExitCode = $LASTEXITCODE
		$prefixOutput = @(& $npmPath prefix -g 2>$null)
		$prefixExitCode = $LASTEXITCODE
	} catch {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = 'Unable to execute the active global npm installation' }
	}
	if ($rootExitCode -ne 0 -or $prefixExitCode -ne 0 -or $rootOutput.Count -ne 1 -or $prefixOutput.Count -ne 1) {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = 'Unable to resolve the active global npm installation' }
	}
	try {
		$root = [IO.Path]::GetFullPath(([string]$rootOutput[0]).Trim())
		$prefix = [IO.Path]::GetFullPath(([string]$prefixOutput[0]).Trim())
	} catch {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = 'The active global npm paths are invalid' }
	}
	$packageDirectory = Join-Path $root '@yusys-ai\yucode'
	if (-not (Test-Path -LiteralPath $packageDirectory)) { return [pscustomobject]@{ Status = 'absent' } }
	$item = Get-Item -LiteralPath $packageDirectory -Force
	$manifestPath = Join-Path $packageDirectory 'package.json'
	if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = "The global npm package path is not a regular package directory: $packageDirectory" }
	}
	$manifestItem = Get-Item -LiteralPath $manifestPath -Force
	if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = "The global npm package manifest is not a regular file: $manifestPath" }
	}
	try {
		$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
	} catch {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = "The global npm package manifest is invalid: $manifestPath" }
	}
	if ([string]$manifest.name -ne '@yusys-ai/yucode') {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = "The global npm package manifest is not @yusys-ai/yucode: $manifestPath" }
	}
	$version = [string]$manifest.version
	if (-not (Test-Version $version)) {
		return [pscustomobject]@{ Status = 'unsafe'; Reason = "The global npm package manifest has an invalid version: $manifestPath" }
	}
	return [pscustomobject]@{
		Status = 'verified'
		NpmPath = $npmPath
		Prefix = $prefix
		Root = $root
		PackageDirectory = $packageDirectory
		Version = $version
	}
}

function Test-DirectoryWritable {
	param([string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
	$item = Get-Item -LiteralPath $Path -Force
	if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
	$probe = Join-Path $Path ".yucode-write-probe-$([Guid]::NewGuid().ToString('N'))"
	try {
		[IO.File]::WriteAllText($probe, '')
		return $true
	} catch {
		return $false
	} finally {
		if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
	}
}

function Test-GlobalNpmUserManageable {
	param($Installation)
	$userRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
	if ([String]::IsNullOrWhiteSpace($userRoot) -or -not (Test-PathWithinWithoutReparse -Path $Installation.Prefix -Root $userRoot -AllowRootReparse $true) -or -not (Test-PathWithinWithoutReparse -Path $Installation.Root -Root $userRoot -AllowRootReparse $true)) { return $false }
	$systemRoots = @(
		[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
		[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
		$env:windir,
		[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
	) | Where-Object { -not [String]::IsNullOrWhiteSpace($_) }
	foreach ($root in $systemRoots) {
		if ((Test-PathWithin $Installation.Prefix $root) -or (Test-PathWithin $Installation.Root $root)) { return $false }
	}
	$scopeDirectory = Split-Path -Parent $Installation.PackageDirectory
	return (Test-DirectoryWritable $Installation.Prefix) -and (Test-DirectoryWritable $Installation.Root) -and (Test-DirectoryWritable $scopeDirectory) -and (Test-DirectoryWritable $Installation.PackageDirectory)
}

function Get-YucodeShadowCommands {
	param([string]$Wrapper)
	$commands = @(Get-Command yucode -All -ErrorAction SilentlyContinue)
	$result = @()
	foreach ($command in $commands) {
		$pathProperty = $command.PSObject.Properties['Path']
		$sourceProperty = $command.PSObject.Properties['Source']
		$path = if ($null -ne $pathProperty -and -not [String]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
			[string]$pathProperty.Value
		} elseif ($null -ne $sourceProperty -and -not [String]::IsNullOrWhiteSpace([string]$sourceProperty.Value)) {
			[string]$sourceProperty.Value
		} else {
			[string]$command.Name
		}
		if (-not [StringComparer]::OrdinalIgnoreCase.Equals($path, $Wrapper)) { $result += $path }
	}
	return @($result | Select-Object -Unique)
}

function Read-State {
	param([string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
	$item = Get-Item -LiteralPath $Path -Force
	if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'Managed installation state is invalid' }
	try {
		$state = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
	} catch {
		Fail "Managed installation state is invalid"
	}
	$propertyNames = @($state.PSObject.Properties.Name)
	if (@('schemaVersion', 'version', 'channel', 'pathAdded') | Where-Object { $propertyNames -notcontains $_ }) {
		Fail "Managed installation state is invalid"
	}
	if ($state.schemaVersion -ne 1 -or -not (Test-Version ([string]$state.version)) -or @('default', 'stable', 'rc') -notcontains [string]$state.channel -or $state.pathAdded -isnot [bool]) {
		Fail "Managed installation state is invalid"
	}
	return $state
}

function Test-NativeInstallation {
	param([string]$StatePath, [string]$VersionsDirectory, [string]$Wrapper)
	$state = Read-State $StatePath
	if ($null -eq $state) { Fail 'Managed installation state is incomplete' }
	$version = [string]$state.version
	$versionDirectory = Join-Path $VersionsDirectory $version
	$binaryPath = Join-Path $versionDirectory 'yucode.exe'
	$manifestPath = Join-Path $versionDirectory 'package.json'
	$versionItem = Get-Item -LiteralPath $versionDirectory -Force -ErrorAction SilentlyContinue
	if ($null -eq $versionItem -or -not $versionItem.PSIsContainer -or ($versionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Test-Path -LiteralPath $binaryPath -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
		Fail "Native installation is incomplete: $version"
	}
	foreach ($path in @($binaryPath, $manifestPath)) {
		if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "Native installation contains a reparse point: $path" }
	}
	try {
		$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
	} catch {
		Fail 'Native installation manifest is invalid'
	}
	if ([string]$manifest.name -ne '@yusys-ai/yucode' -or [string]$manifest.version -ne $version) {
		Fail "Native installation manifest does not match $version"
	}
	if (-not (Test-ManagedWrapper $Wrapper $version)) { Fail "Native command wrapper is incomplete: $Wrapper" }
	$reportedVersion = (& $binaryPath --version | Out-String).Trim()
	if ($LASTEXITCODE -ne 0 -or $reportedVersion -ne $version) { Fail "Native installation reported $reportedVersion, expected $version" }
	& $binaryPath --help | Out-Null
	if ($LASTEXITCODE -ne 0) { Fail 'Native installation help smoke failed' }
	return $state
}

function Write-ManualNpmRemoval {
	return 'Remove it manually after reviewing its permissions: npm uninstall -g --ignore-scripts @yusys-ai/yucode'
}

function Invoke-InstallNpmMigration {
	param(
		[string]$LocalAppDataRoot,
		[string]$InstallRoot,
		[string]$StatePath,
		[string]$VersionsDirectory,
		[string]$BinDirectory,
		[string]$Wrapper
	)
	foreach ($path in @($InstallRoot, $StatePath, $VersionsDirectory, $BinDirectory, $Wrapper)) {
		Assert-ManagedPath $path $LocalAppDataRoot $false
	}
	Test-NativeInstallation $StatePath $VersionsDirectory $Wrapper | Out-Null
	$installation = Get-GlobalNpmInstallation
	switch ($installation.Status) {
		'absent' { return }
		'unsafe' {
			Write-Warning "$($installation.Reason). It was not changed. $(Write-ManualNpmRemoval)"
			return
		}
	}
	if (-not (Test-GlobalNpmUserManageable $installation)) {
		Write-Warning "The global npm installation is system-level or not user-manageable: $($installation.PackageDirectory). It was not changed. $(Write-ManualNpmRemoval)"
		return
	}
	& $installation.NpmPath uninstall -g --ignore-scripts '@yusys-ai/yucode'
	if ($LASTEXITCODE -ne 0) { Fail "Native installation is ready, but npm uninstall failed. $(Write-ManualNpmRemoval)" }
	if (Test-Path -LiteralPath $installation.PackageDirectory) {
		Fail "Native installation is ready, but the global npm package remains at $($installation.PackageDirectory). $(Write-ManualNpmRemoval)"
	}
	foreach ($path in @($InstallRoot, $StatePath, $VersionsDirectory, $BinDirectory, $Wrapper)) {
		Assert-ManagedPath $path $LocalAppDataRoot $false
	}
	Test-NativeInstallation $StatePath $VersionsDirectory $Wrapper | Out-Null
	Write-Output 'Removed the global npm installation of @yusys-ai/yucode.'
}

function Get-Platform {
	$architecture = $env:PROCESSOR_ARCHITEW6432
	if ([String]::IsNullOrEmpty($architecture)) { $architecture = $env:PROCESSOR_ARCHITECTURE }
	if ([String]::IsNullOrEmpty($architecture)) { Fail "Unable to detect Windows architecture" }
	switch ($architecture.ToUpperInvariant()) {
		'ARM64' { return 'windows-arm64' }
		'AMD64' { return 'windows-x64' }
		default { Fail "Unsupported Windows architecture: $architecture" }
	}
}

function Assert-ManagedVersionDirectory {
	param([string]$Path, [string]$Version)
	if (-not (Test-Version $Version)) { Fail "Managed version directory has an invalid name: $Path" }
	$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if ($null -eq $item -or -not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		Fail "Managed version path is not a regular directory: $Path"
	}
	$binaryPath = Join-Path $Path 'yucode.exe'
	$manifestPath = Join-Path $Path 'package.json'
	foreach ($requiredPath in @($binaryPath, $manifestPath)) {
		$requiredItem = Get-Item -LiteralPath $requiredPath -Force -ErrorAction SilentlyContinue
		if ($null -eq $requiredItem -or $requiredItem.PSIsContainer -or ($requiredItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			Fail "Managed version directory is incomplete: $Path"
		}
	}
	try {
		$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
	} catch {
		Fail "Managed version manifest is invalid: $manifestPath"
	}
	if ([string]$manifest.name -ne '@yusys-ai/yucode' -or [string]$manifest.version -cne $Version) {
		Fail "Managed version manifest does not match $Version"
	}
}

function Assert-PartialManagedInstallation {
	param(
		[string]$InstallRoot,
		[string]$StatePath,
		[string]$VersionsDirectory,
		[string]$BinDirectory,
		[string]$Wrapper
	)
	foreach ($entry in (Get-ChildItem -LiteralPath $InstallRoot -Force)) {
		if (@('state', 'versions', 'bin') -notcontains $entry.Name -or -not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			Fail "Refusing to remove an incomplete installation containing an unmanaged path: $($entry.FullName)"
		}
	}
	$stateDirectory = Split-Path -Parent $StatePath
	foreach ($entry in (Get-ChildItem -LiteralPath $stateDirectory -Force)) {
		if ($entry.Name -cne 'managed' -or $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			Fail "Refusing to remove an incomplete installation containing unmanaged state: $($entry.FullName)"
		}
	}
	if (Test-Path -LiteralPath $BinDirectory -PathType Container) {
		foreach ($entry in (Get-ChildItem -LiteralPath $BinDirectory -Force)) {
			if (-not [StringComparer]::OrdinalIgnoreCase.Equals($entry.FullName, $Wrapper) -or $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
				Fail "Refusing to remove an incomplete installation containing an unmanaged command: $($entry.FullName)"
			}
		}
	}
	if (Test-Path -LiteralPath $VersionsDirectory -PathType Container) {
		foreach ($entry in (Get-ChildItem -LiteralPath $VersionsDirectory -Force)) {
			Assert-ManagedVersionDirectory $entry.FullName $entry.Name
		}
	}
}

function Remove-OldManagedVersions {
	param(
		[string]$VersionsDirectory,
		[string]$CurrentVersion,
		[string]$LocalAppDataRoot
	)
	if (Get-Process -Name 'yucode' -ErrorAction SilentlyContinue) { return }
	Assert-ManagedPath $VersionsDirectory $LocalAppDataRoot $false
	$oldDirectories = [System.Collections.Generic.List[string]]::new()
	foreach ($entry in (Get-ChildItem -LiteralPath $VersionsDirectory -Force)) {
		Assert-ManagedVersionDirectory $entry.FullName $entry.Name
		if ($entry.Name -cne $CurrentVersion) { $oldDirectories.Add($entry.FullName) }
	}
	foreach ($directory in $oldDirectories) {
		Assert-ManagedPath $directory $LocalAppDataRoot $false
		Remove-SafeTree $directory
	}
}

function Uninstall-Yucode {
	param(
		[string]$LocalAppDataRoot,
		[string]$InstallRoot,
		[string]$VersionsDirectory,
		[string]$Wrapper,
		[string]$StatePath,
		[string]$BinDirectory,
		[string]$UserDataDirectory,
		[bool]$Purge
	)
	foreach ($path in @($InstallRoot, $StatePath, $BinDirectory, $Wrapper)) {
		Assert-ManagedPath $path $LocalAppDataRoot $true
	}
	$state = Read-State $StatePath
	if (Test-Path -LiteralPath $Wrapper) {
		$wrapperVersion = if ($null -eq $state) { '' } else { [string]$state.version }
		if (-not (Test-ManagedWrapper $Wrapper $wrapperVersion)) { Fail "Refusing to remove an unmanaged command: $Wrapper" }
	}
	if (Test-Path -LiteralPath $InstallRoot) {
		foreach ($path in @($InstallRoot, $StatePath, $BinDirectory, $Wrapper)) {
			Assert-ManagedPath $path $LocalAppDataRoot $true
		}
		$item = Get-Item -LiteralPath $InstallRoot -Force
		if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			Fail "Refusing to remove an unmanaged path: $InstallRoot"
		}
		$marker = Join-Path $InstallRoot 'state\managed'
		$markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
		if ($null -eq $markerItem -or $markerItem.PSIsContainer -or ($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [IO.File]::ReadAllText($marker).Trim() -ne '1') {
			Fail "Refusing to remove an unmanaged directory: $InstallRoot"
		}
		if ($null -eq $state) {
			Assert-PartialManagedInstallation $InstallRoot $StatePath $VersionsDirectory $BinDirectory $Wrapper
		}
		if (Get-Process -Name 'yucode' -ErrorAction SilentlyContinue) { Fail "Close all running yucode processes before uninstalling" }
		Assert-ManagedPath $InstallRoot $LocalAppDataRoot $false
		Assert-ManagedPath $StatePath $LocalAppDataRoot ($null -eq $state)
		Assert-ManagedPath $BinDirectory $LocalAppDataRoot $true
		Assert-ManagedPath $Wrapper $LocalAppDataRoot $true
		Remove-SafeTree $InstallRoot
	}
	if ($null -ne $state -and [bool]$state.pathAdded) { Remove-UserPath $BinDirectory }
	if ($Purge) {
		if (Get-Process -Name 'yucode' -ErrorAction SilentlyContinue) { Fail "Close all running yucode processes before purging user data" }
		Remove-SafeTree $UserDataDirectory
		Write-Output "$script:Product was uninstalled. User data under $UserDataDirectory was removed."
	} else {
		Write-Output "$script:Product was uninstalled. User data under $UserDataDirectory was kept."
	}
}

function Install-Yucode {
	param(
		[string]$LocalAppDataRoot,
		[string]$InstallRoot,
		[string]$VersionsDirectory,
		[string]$StateDirectory,
		[string]$StatePath,
		[string]$BinDirectory,
		[string]$Wrapper,
		[string]$Channel,
		[string]$VersionOverride,
		[bool]$NoModifyPath
	)
	foreach ($path in @($InstallRoot, $VersionsDirectory, $StateDirectory, $StatePath, $BinDirectory, $Wrapper)) {
		Assert-ManagedPath $path $LocalAppDataRoot $true
	}
	$existingState = Read-State $StatePath
	if (Test-Path -LiteralPath $InstallRoot) {
		$item = Get-Item -LiteralPath $InstallRoot -Force
		if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			Fail "Install root is not a managed directory: $InstallRoot"
		}
		if ($null -eq $existingState -and (Get-ChildItem -LiteralPath $InstallRoot -Force | Select-Object -First 1)) {
			$marker = Join-Path $InstallRoot 'state\managed'
			$markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
			if ($null -eq $markerItem -or $markerItem.PSIsContainer -or ($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [IO.File]::ReadAllText($marker).Trim() -ne '1') {
				Fail "Refusing to use a non-empty unmanaged directory: $InstallRoot"
			}
		}
	}
	if ((Test-Path -LiteralPath $Wrapper) -and -not (Test-ManagedWrapper $Wrapper)) {
		Fail "Refusing to replace an unmanaged command: $Wrapper"
	}
	foreach ($path in @($InstallRoot, $VersionsDirectory, $StateDirectory, $BinDirectory, $Wrapper)) {
		Assert-ManagedPath $path $LocalAppDataRoot $true
	}
	New-Item -ItemType Directory -Force -Path $StateDirectory, $VersionsDirectory, $BinDirectory | Out-Null
	foreach ($path in @($InstallRoot, $StateDirectory, $VersionsDirectory, $BinDirectory)) {
		Assert-ManagedPath $path $LocalAppDataRoot $false
	}
	Assert-ManagedPath $Wrapper $LocalAppDataRoot $true
	$markerPath = Join-Path $StateDirectory 'managed'
	Assert-ManagedPath $markerPath $LocalAppDataRoot $true
	Write-AtomicText $markerPath "1`n"
	if (@('default', 'rc') -notcontains $Channel) { Fail "Invalid release selection: $Channel" }
	$stagingDirectory = Join-Path $InstallRoot ".staging.$([Guid]::NewGuid().ToString('N'))"
	Assert-ManagedPath $stagingDirectory $LocalAppDataRoot $true
	New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
	Assert-ManagedPath $stagingDirectory $LocalAppDataRoot $false
	try {
		if (-not [String]::IsNullOrEmpty($VersionOverride)) {
			$version = $VersionOverride
		} else {
			$version = Get-ChannelVersion $Channel $stagingDirectory
		}
		if (-not (Test-Version $version)) { Fail "Invalid release version: $version" }
		if ($null -ne $existingState -and (Compare-Version $version ([string]$existingState.version)) -lt 0) {
			Fail "Refusing to downgrade from $($existingState.version) to $version; downgrades are not supported"
		}
		$npmInstallation = Get-GlobalNpmInstallation
		if ($npmInstallation.Status -eq 'verified' -and (Compare-Version $version ([string]$npmInstallation.Version)) -lt 0) {
			Fail "Refusing to downgrade from $($npmInstallation.Version) to $version; downgrades are not supported"
		}
		$versionDirectory = Join-Path $VersionsDirectory $version
		Assert-ManagedPath $versionDirectory $LocalAppDataRoot $true
		if (Test-Path -LiteralPath $versionDirectory) {
			$item = Get-Item -LiteralPath $versionDirectory -Force
			if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "Version path is not a managed directory: $versionDirectory" }
			$manifestPath = Join-Path $versionDirectory 'package.json'
			$binaryPath = Join-Path $versionDirectory 'yucode.exe'
			if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
				Fail "Installed version is incomplete: $version"
			}
			foreach ($path in @($manifestPath, $binaryPath)) {
				if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "Installed version contains a reparse point: $path" }
			}
			$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
			if ([string]$manifest.name -ne '@yusys-ai/yucode' -or [string]$manifest.version -ne $version) {
				Fail "Installed version manifest does not match $version"
			}
		} else {
			$platform = Get-Platform
			$asset = "yucode-$platform.zip"
			$archivePath = Join-Path $stagingDirectory $asset
			$checksumPath = Join-Path $stagingDirectory 'SHA256SUMS'
			Invoke-Download "$script:ReleaseBase/v$version/$asset" $archivePath | Out-Null
			Invoke-Download "$script:ReleaseBase/v$version/SHA256SUMS" $checksumPath | Out-Null
			$expectedHash = Get-ExpectedChecksum $checksumPath $asset
			$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
			if ($actualHash -ne $expectedHash) { Fail "Checksum mismatch for $asset" }
			$extractionRoot = Join-Path $stagingDirectory 'extract'
			New-Item -ItemType Directory -Path $extractionRoot | Out-Null
			Test-ZipArchive $archivePath $extractionRoot
			[IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractionRoot)
			foreach ($item in (Get-ChildItem -LiteralPath $extractionRoot -Force -Recurse)) {
				if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "Release archive contains a reparse point: $($item.FullName)" }
			}
			foreach ($required in @('yucode.exe', 'package.json', 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md')) {
				if (-not (Test-Path -LiteralPath (Join-Path $extractionRoot $required))) { Fail "Release archive is missing $required" }
			}
			if (-not (Test-Path -LiteralPath (Join-Path $extractionRoot 'LICENSES') -PathType Container)) { Fail "Release archive is missing LICENSES" }
			$manifest = [IO.File]::ReadAllText((Join-Path $extractionRoot 'package.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
			if ([string]$manifest.name -ne '@yusys-ai/yucode' -or [string]$manifest.version -ne $version) {
				Fail "Release package manifest does not match $version"
			}
			$binaryPath = Join-Path $extractionRoot 'yucode.exe'
			$reportedVersion = (& $binaryPath --version | Out-String).Trim()
			if ($LASTEXITCODE -ne 0 -or $reportedVersion -ne $version) { Fail "Release binary reported $reportedVersion, expected $version" }
			& $binaryPath --help | Out-Null
			if ($LASTEXITCODE -ne 0) { Fail "Release binary help smoke failed" }
			Assert-ManagedPath $versionDirectory $LocalAppDataRoot $true
			[IO.Directory]::Move($extractionRoot, $versionDirectory)
			Assert-ManagedPath $versionDirectory $LocalAppDataRoot $false
		}
		$previouslyAdded = $null -ne $existingState -and [bool]$existingState.pathAdded
		$pathAdded = Ensure-UserPath $BinDirectory $previouslyAdded $NoModifyPath
		$state = [ordered]@{
			schemaVersion = 1
			version = $version
			channel = $Channel
			pathAdded = $pathAdded
		}
		Assert-ManagedPath $StatePath $LocalAppDataRoot $true
		Write-AtomicText $StatePath (($state | ConvertTo-Json) + "`n")
		Assert-ManagedPath $StatePath $LocalAppDataRoot $false
		Assert-ManagedPath $Wrapper $LocalAppDataRoot $true
		Write-Wrapper $Wrapper $version
		Assert-ManagedPath $Wrapper $LocalAppDataRoot $false
	} finally {
		Assert-ManagedPath $stagingDirectory $LocalAppDataRoot $true
		Remove-SafeTree $stagingDirectory
	}
}

if ($PSVersionTable.PSVersion.Major -lt 5) { Fail "PowerShell 5.1 or later is required" }
$tls12 = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$action = 'install'
$channel = 'default'
$versionOverride = $null
$noModifyPath = $false
$purge = $false
$selection = 'default'
for ($argumentIndex = 0; $argumentIndex -lt $args.Count; $argumentIndex++) {
	$argument = [string]$args[$argumentIndex]
	switch ($argument) {
		'--preview' {
			if ($selection -ne 'default') { Fail '--preview cannot be combined with another release selection' }
			$selection = 'preview'
			$channel = 'rc'
		}
		'--version' {
			if ($selection -ne 'default') { Fail '--version cannot be combined with another release selection' }
			if ($argumentIndex + 1 -ge $args.Count) { Fail '--version requires a value' }
			$argumentIndex++
			$versionOverride = [string]$args[$argumentIndex]
			if ($versionOverride.StartsWith('--', [StringComparison]::Ordinal)) { Fail '--version requires a value' }
			$selection = 'exact'
		}
		'--uninstall' { $action = 'uninstall' }
		'--purge' { $purge = $true }
		'--no-modify-path' { $noModifyPath = $true }
		default { Fail "Unknown argument: $argument" }
	}
}
if ($selection -eq 'exact' -and -not (Test-Version $versionOverride)) { Fail "Invalid release version: $versionOverride" }
if ($action -eq 'uninstall') {
	if ($selection -ne 'default') { Fail '--uninstall cannot be combined with --preview or --version' }
	if ($noModifyPath) { Fail '--no-modify-path is only valid when installing' }
} elseif ($purge) {
	Fail '--purge requires --uninstall'
}
if ([String]::IsNullOrEmpty($env:LOCALAPPDATA)) { Fail "LOCALAPPDATA is not set" }

try {
	$localAppDataRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
} catch {
	Fail "LOCALAPPDATA is invalid"
}
if ([String]::IsNullOrWhiteSpace($localAppDataRoot) -or -not (Test-PathWithinWithoutReparse $localAppDataRoot $localAppDataRoot)) {
	Fail "LOCALAPPDATA must be a regular local directory"
}
$userDataDirectory = Join-Path $HOME '.yucode'
if ($purge) {
	$userProfileValue = $env:USERPROFILE
	if ([String]::IsNullOrWhiteSpace($userProfileValue)) {
		$userProfileValue = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
	}
	if ([String]::IsNullOrWhiteSpace($userProfileValue)) {
		Fail "Unable to resolve an absolute user profile for purge"
	}
	$isDriveAbsolute = $userProfileValue -match '^[A-Za-z]:[\\/]'
	$isUncAbsolute = $userProfileValue -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+'
	if (-not $isDriveAbsolute -and -not $isUncAbsolute) {
		Fail "Unable to resolve an absolute user profile for purge"
	}
	try {
		$fullUserProfile = [IO.Path]::GetFullPath($userProfileValue)
		$volumeRoot = [IO.Path]::GetPathRoot($fullUserProfile)
	} catch {
		Fail "USERPROFILE is invalid"
	}
	if ([String]::IsNullOrWhiteSpace($volumeRoot) -or [StringComparer]::OrdinalIgnoreCase.Equals($fullUserProfile.TrimEnd('\'), $volumeRoot.TrimEnd('\'))) {
		Fail "Refusing to purge user data from a volume root"
	}
	$userProfileRoot = $fullUserProfile.TrimEnd('\')
	$userDataDirectory = Join-Path $userProfileRoot '.yucode'
	if (-not (Test-PathWithinWithoutReparse -Path $userDataDirectory -Root $userProfileRoot -AllowMissing $true)) {
		Fail "User data path escapes USERPROFILE or passes through a reparse point: $userDataDirectory"
	}
}
$installRoot = Join-Path $localAppDataRoot 'Yusys\CodeMate'
$versionsDirectory = Join-Path $installRoot 'versions'
$stateDirectory = Join-Path $installRoot 'state'
$statePath = Join-Path $stateDirectory 'install.json'
$binDirectory = Join-Path $installRoot 'bin'
$wrapper = Join-Path $binDirectory 'yucode.cmd'
$mutexName = "Global\YusysCodeMateInstaller-$($identity.User.Value)"
try {
	$mutex = [Threading.Mutex]::new($false, $mutexName)
} catch {
	Fail 'Unable to create the cross-session installer lock'
}
$lockAcquired = $false
try {
	try {
		$lockAcquired = $mutex.WaitOne(10000)
	} catch [Threading.AbandonedMutexException] {
		$lockAcquired = $true
	}
	if (-not $lockAcquired) { Fail "Another yucode installer is active" }
	if ($action -eq 'uninstall') {
		Uninstall-Yucode -LocalAppDataRoot $localAppDataRoot -InstallRoot $installRoot -VersionsDirectory $versionsDirectory -Wrapper $wrapper -StatePath $statePath -BinDirectory $binDirectory -UserDataDirectory $userDataDirectory -Purge $purge
	} else {
		Install-Yucode -LocalAppDataRoot $localAppDataRoot -InstallRoot $installRoot -VersionsDirectory $versionsDirectory -StateDirectory $stateDirectory -StatePath $statePath -BinDirectory $binDirectory -Wrapper $wrapper -Channel $channel -VersionOverride $versionOverride -NoModifyPath $noModifyPath
		Invoke-InstallNpmMigration $localAppDataRoot $installRoot $statePath $versionsDirectory $binDirectory $wrapper
		Assert-ManagedPath $StatePath $localAppDataRoot $false
		$installedState = Read-State $statePath
		Test-NativeInstallation $statePath $versionsDirectory $wrapper | Out-Null
		Remove-OldManagedVersions $versionsDirectory ([string]$installedState.version) $localAppDataRoot
		Write-Output "$Product $($installedState.version) is installed. Open a new terminal, then run: yucode"
		foreach ($path in @(Get-YucodeShadowCommands $wrapper)) {
			Write-Warning "The current session resolves yucode to $path instead of $wrapper."
		}
	}
} finally {
	if ($lockAcquired) { $mutex.ReleaseMutex() }
	$mutex.Dispose()
}
