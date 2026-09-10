$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  # PowerShell 7 may not expose the Windows PowerShell TLS setting.
}

$githubRepo = $env:ATLAS_GITHUB_REPO
if ([string]::IsNullOrWhiteSpace($githubRepo)) {
  $githubRepo = "nim-lang/atlas"
}

$repoUrl = $env:ATLAS_REPO_URL
if ([string]::IsNullOrWhiteSpace($repoUrl)) {
  $repoUrl = "https://github.com/$githubRepo.git"
}

$installDir = $env:ATLAS_INSTALL_DIR
if ([string]::IsNullOrWhiteSpace($installDir)) {
  $installDir = Join-Path $env:USERPROFILE ".nimble\bin"
}

$atlasRef = $env:ATLAS_REF
if ($null -eq $atlasRef) {
  $atlasRef = ""
}

$tmpRoot = $env:ATLAS_TMP_ROOT
if ([string]::IsNullOrWhiteSpace($tmpRoot)) {
  $tmpRoot = [IO.Path]::GetTempPath()
}

$tmpDir = Join-Path $tmpRoot ("atlas-install-" + [Guid]::NewGuid().ToString("N"))

function Get-ReleaseArchive {
  $architecture = $env:PROCESSOR_ARCHITEW6432
  if ([string]::IsNullOrWhiteSpace($architecture)) {
    $architecture = $env:PROCESSOR_ARCHITECTURE
  }
  if ([string]::IsNullOrWhiteSpace($architecture)) {
    throw "unable to determine the Windows processor architecture"
  }

  switch ($architecture.ToUpperInvariant()) {
    "AMD64" { return "atlas-windows-amd64.zip" }
    "X86" { return "atlas-windows-i386.zip" }
    default {
      throw "no prebuilt Atlas release is available for Windows architecture $architecture"
    }
  }
}

function Get-ReleaseBaseUrl([string]$url) {
  $repo = $url.TrimEnd("/")
  if ($repo.StartsWith("git@github.com:")) {
    $repo = "https://github.com/" + $repo.Substring("git@github.com:".Length)
  }
  if (-not $repo.StartsWith("https://github.com/")) {
    return $null
  }
  if ($repo.EndsWith(".git")) {
    $repo = $repo.Substring(0, $repo.Length - 4)
  }
  return "$repo/releases/latest/download"
}

function Install-Binaries([string]$atlasSource, [string]$atlasRunSource) {
  $null = New-Item -ItemType Directory -Force -Path $installDir
  $installedAtlas = Join-Path $installDir "atlas.exe"
  $installedAtlasRun = Join-Path $installDir "atlas-run.exe"

  foreach ($path in @(
      (Join-Path $installDir "atlas"),
      $installedAtlas,
      (Join-Path $installDir "atlas-run"),
      $installedAtlasRun
    )) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -Force -LiteralPath $path
    }
  }

  Copy-Item -Force -LiteralPath $atlasSource -Destination $installedAtlas
  Copy-Item -Force -LiteralPath $atlasRunSource -Destination $installedAtlasRun

  Write-Host "install.ps1: installed atlas to $installedAtlas"
  Write-Host "install.ps1: installed atlas-run to $installedAtlasRun"
  $atlasVersion = & $installedAtlas --version
  if ($LASTEXITCODE -ne 0) {
    throw "atlas --version failed"
  }
  $atlasRunVersion = & $installedAtlasRun --version
  if ($LASTEXITCODE -ne 0) {
    throw "atlas-run --version failed"
  }
  Write-Host $atlasVersion
  Write-Host $atlasRunVersion

  $pathContainsInstallDir = $false
  if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
    $normalizedInstallDir = [IO.Path]::GetFullPath($installDir).TrimEnd("\")
    foreach ($entry in ($env:Path -split ";")) {
      if ($entry.TrimEnd("\") -ieq $normalizedInstallDir) {
        $pathContainsInstallDir = $true
        break
      }
    }
  }
  if (-not $pathContainsInstallDir) {
    Write-Warning "add $installDir to your user PATH to run atlas directly"
  }
}

function Try-InstallRelease {
  if (-not [string]::IsNullOrWhiteSpace($atlasRef)) {
    return $false
  }

  try {
    $archive = Get-ReleaseArchive
    $releaseBaseUrl = Get-ReleaseBaseUrl $repoUrl
    if ([string]::IsNullOrWhiteSpace($releaseBaseUrl)) {
      return $false
    }

    $archivePath = Join-Path $tmpDir $archive
    $extractDir = Join-Path $tmpDir "release"
    $null = New-Item -ItemType Directory -Force -Path $extractDir
    Write-Host "install.ps1: downloading latest Atlas release asset $archive"
    Invoke-WebRequest -UseBasicParsing `
      -Uri "$releaseBaseUrl/$archive" -OutFile $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force

    $atlasBins = @(
      Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -ieq "atlas.exe" } |
        Select-Object -First 1
    )
    if ($atlasBins.Count -eq 0) {
      throw "release asset did not contain atlas.exe"
    }

    $atlasRunBins = @(
      Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -ieq "atlas-run.exe" } |
        Select-Object -First 1
    )
    if ($atlasRunBins.Count -eq 0) {
      throw "release asset did not contain atlas-run.exe"
    }

    Install-Binaries -atlasSource ($atlasBins[0].FullName) `
      -atlasRunSource ($atlasRunBins[0].FullName)
    return $true
  } catch {
    Write-Warning "release asset installation failed; falling back to building from source: $($_.Exception.Message)"
    return $false
  }
}

function Install-FromSource {
  if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "missing required command: git"
  }
  if ($null -eq (Get-Command nim -ErrorAction SilentlyContinue)) {
    throw "missing required command: nim"
  }

  $sourceDir = Join-Path $tmpDir "source"
  Write-Host "install.ps1: cloning Atlas into $sourceDir from $repoUrl"
  if ([string]::IsNullOrWhiteSpace($atlasRef)) {
    & git clone --depth 1 $repoUrl $sourceDir
  } else {
    & git clone $repoUrl $sourceDir
  }
  if ($LASTEXITCODE -ne 0) {
    throw "git clone failed"
  }

  Push-Location $sourceDir
  try {
    if (-not [string]::IsNullOrWhiteSpace($atlasRef)) {
      & git checkout $atlasRef
      if ($LASTEXITCODE -ne 0) {
        throw "git checkout failed"
      }
    }

    Write-Host "install.ps1: building Atlas"
    & nim buildRelease
    if ($LASTEXITCODE -ne 0) {
      throw "nim buildRelease failed"
    }

    $atlasSource = Join-Path $sourceDir "bin\atlas.exe"
    $atlasRunSource = Join-Path $sourceDir "bin\atlas-run.exe"
    if (-not (Test-Path -LiteralPath $atlasSource)) {
      $atlasSource = Join-Path $sourceDir "bin\atlas"
    }
    if (-not (Test-Path -LiteralPath $atlasRunSource)) {
      $atlasRunSource = Join-Path $sourceDir "bin\atlas-run"
    }
    if (-not (Test-Path -LiteralPath $atlasSource) -or
        -not (Test-Path -LiteralPath $atlasRunSource)) {
      throw "build did not produce atlas and atlas-run"
    }

    Install-Binaries $atlasSource $atlasRunSource
  } finally {
    Pop-Location
  }
}

try {
  $null = New-Item -ItemType Directory -Force -Path $tmpDir
  if (-not (Try-InstallRelease)) {
    Install-FromSource
  }
} finally {
  if (Test-Path -LiteralPath $tmpDir) {
    Remove-Item -Force -Recurse -LiteralPath $tmpDir -ErrorAction SilentlyContinue
  }
}
