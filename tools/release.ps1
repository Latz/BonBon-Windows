# release.ps1 -- builds, tests and publishes a GitHub release of BonBon for Windows.
#
# Run it through nimble: `nimble release`, or `nimble dryrelease` to do all of
# it except the publishing. The version is bonbon.nimble's; the release's text
# is that version's section in CHANGELOG.md. The files go up under two names
# each way: bonbon.exe, windows.zip (the permanent addresses,
# releases/latest/download/...) and BonBon-<version>-windows-x64.zip.

param([switch]$DryRun)

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

function Stop-Release($message) { Write-Host "release: $message" -ForegroundColor Red; exit 1 }
function Write-Problem($message) {
	# in a dry run the git checks only warn, so it can be tried on any branch
	if ($DryRun) { Write-Host "release (dry run, would stop here): $message" -ForegroundColor Yellow } else { Stop-Release $message }
}
function Invoke-Step($exe, [string[]]$arguments) {
	Write-Host "release: $exe $($arguments -join ' ')" -ForegroundColor Cyan
	& $exe @arguments
	if ($LASTEXITCODE -ne 0) { Stop-Release "$exe $($arguments -join ' ') failed" }
}
function Get-Sha256($path) { (Get-FileHash $path -Algorithm SHA256).Hash }

# the version, the same in its three places
$version = [regex]::Match((Get-Content bonbon.nimble -Raw), 'version\s*=\s*"([^"]+)"').Groups[1].Value
$versionApp = [regex]::Match((Get-Content src\datafolder.nim -Raw), 'appVersion\*\s*=\s*"([^"]+)"').Groups[1].Value
$versionManifest = [regex]::Match((Get-Content resources\bonbon.manifest -Raw), 'assemblyIdentity version="([^"]+)"').Groups[1].Value
if (-not $version) { Stop-Release "no version in bonbon.nimble" }
if ($versionApp -ne $version -or $versionManifest -ne "$version.0") {
	Stop-Release "the versions differ: bonbon.nimble $version, appVersion $versionApp, bonbon.manifest $versionManifest (it needs $version.0 and then src\bonbon_res.o made again, see README)"
}
$tag = "v$version"

# what's published is exactly what's on GitHub's main
$branch = git branch --show-current
if ($branch -ne 'main') { Write-Problem "this is branch $branch, not main" }
if (git status --porcelain) { Write-Problem "there are changes that aren't committed" }
git fetch origin main --quiet
if ((git rev-parse HEAD) -ne (git rev-parse origin/main)) { Write-Problem "this commit isn't GitHub's main; push first" }
if (git ls-remote --tags origin "refs/tags/$tag") { Write-Problem "the tag $tag exists already; raise the version" }

# the release's text, from CHANGELOG.md
$changelog = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'))
$section = [regex]::Match($changelog, "(?ms)^## $([regex]::Escape($version))[ \t]*\r?\n(.*?)(?=^## |\z)")
if (-not $section.Success -or -not $section.Groups[1].Value.Trim()) { Stop-Release "CHANGELOG.md has no section ## $version" }
$news = $section.Groups[1].Value.Trim()

# the tests, then a build of its own
Invoke-Step nimble @('test')
Invoke-Step nimble @('e2e')
$dist = Join-Path $root 'dist'
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory (Join-Path $dist 'BonBon') | Out-Null
Invoke-Step nim @('c', '--hints:off', "-o:$dist\bonbon.exe", 'src\bonbon.nim')
Copy-Item "$dist\bonbon.exe" "$dist\BonBon\bonbon.exe"
Copy-Item LICENSE "$dist\BonBon\LICENSE"
$zip = "$dist\BonBon-$version-windows-x64.zip"
Compress-Archive -Path "$dist\BonBon" -DestinationPath $zip
Copy-Item $zip "$dist\windows.zip"
$shaExe = Get-Sha256 "$dist\bonbon.exe"
$shaZip = Get-Sha256 $zip

$notes = @"
BonBon for Windows, a browser for a web made of Markdown files: the interface of BonBon 0.6.56 (Dave Winer, MIT) unchanged, in WebView2, with a small native app in Nim instead of Electron.

## What's new in $version

$news

## Installation

1. Download ``bonbon.exe``, put it anywhere and run it. ``windows.zip`` and ``BonBon-$version-windows-x64.zip`` hold the same exe, with the license beside it.
2. On the first start Windows may say "Windows protected your PC" because the app isn't signed: click "More info", then "Run anyway".

The latest version is always at https://github.com/Latz/BonBon-Windows/releases/latest/download/bonbon.exe and https://github.com/Latz/BonBon-Windows/releases/latest/download/windows.zip. Windows 10 and 11 usually come with the WebView2 runtime it needs; if not, it's available from [Microsoft](https://developer.microsoft.com/microsoft-edge/webview2/).

SHA-256:
- ``bonbon.exe``: ``$shaExe``
- ``windows.zip`` / ``BonBon-$version-windows-x64.zip``: ``$shaZip``
"@
$notesFile = "$dist\notes.md"
[IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding $false))

Write-Host ""
Write-Host $notes
Write-Host ""
if ($DryRun) {
	Write-Host "release: dry run done, $dist has the files; nothing was published" -ForegroundColor Green
	exit 0
}
Invoke-Step gh @('release', 'create', $tag, "$dist\bonbon.exe", "$dist\windows.zip", $zip,
	'--target', (git rev-parse HEAD), '--title', "BonBon for Windows $version", '--notes-file', $notesFile, '--latest')
Write-Host "release: $tag is published" -ForegroundColor Green
