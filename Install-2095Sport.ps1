[CmdletBinding()]
param(
    [switch] $Setup,

    [string] $TvIp,

    [string] $DeviceName = 'DadLG',

    [switch] $Force,

    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ExpectedAppId = 'com.streamedsports.webos'
$ExpectedTitle = '2095Sport'
$ExpectedReleaseHost = 'github.com'
$ExpectedReleasePathPrefix = '/mishapavlov1/stunning-rotary-phone/releases/download/'
$ReleaseManifestUrl = 'https://raw.githubusercontent.com/mishapavlov1/stunning-rotary-phone/main/webos-latest.json'
$MaximumPackageSize = 100MB

function ConvertFrom-ReleaseManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json
    )

    try {
        $manifest = $Json | ConvertFrom-Json
    } catch {
        throw 'Release manifest is not valid JSON.'
    }

    if ($manifest.schemaVersion -ne 1) {
        throw 'Release manifest has an unsupported schemaVersion.'
    }
    if ($manifest.appId -ne $ExpectedAppId) {
        throw "Release manifest has an unexpected appId."
    }
    if ($manifest.title -ne $ExpectedTitle) {
        throw 'Release manifest has an unexpected title.'
    }
    if ($manifest.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw 'Release manifest has an invalid version.'
    }
    if ($manifest.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Release manifest has an invalid sha256.'
    }

    $size = 0L
    if (-not [long]::TryParse([string] $manifest.size, [ref] $size) -or
        $size -le 0 -or
        $size -gt $MaximumPackageSize) {
        throw 'Release manifest has an invalid size.'
    }

    $assetUri = $null
    if (-not [Uri]::TryCreate([string] $manifest.assetUrl, [UriKind]::Absolute, [ref] $assetUri) -or
        $assetUri.Scheme -ne 'https' -or
        $assetUri.Host -ne $ExpectedReleaseHost) {
        throw 'Release manifest has an invalid assetUrl.'
    }

    $expectedPath = "$ExpectedReleasePathPrefix" +
        "v$($manifest.version)/2095Sport-webOS-v$($manifest.version).ipk"
    if ($assetUri.AbsolutePath -cne $expectedPath -or $assetUri.Query -or $assetUri.Fragment) {
        throw 'Release manifest assetUrl does not match the expected release asset.'
    }

    [PSCustomObject] @{
        schemaVersion = 1
        appId = $ExpectedAppId
        title = $ExpectedTitle
        version = [string] $manifest.version
        assetUrl = $assetUri.AbsoluteUri
        sha256 = ([string] $manifest.sha256).ToLowerInvariant()
        size = $size
    }
}

function Get-InstalledAppVersion {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [object] $Output
    )

    $text = [string]::Join([Environment]::NewLine, [string[]] $Output)
    $blocks = $text -split '(?m)^\s*--\s*$'
    foreach ($block in $blocks) {
        $idMatch = [regex]::Match($block, '(?m)^\s*id\s*:\s*(?<value>[^\r\n]+?)\s*$')
        if (-not $idMatch.Success -or $idMatch.Groups['value'].Value -cne $ExpectedAppId) {
            continue
        }

        $versionMatch = [regex]::Match(
            $block,
            '(?m)^\s*version\s*:\s*(?<value>[0-9]+\.[0-9]+\.[0-9]+)\s*$'
        )
        if (-not $versionMatch.Success) {
            throw 'The installed app entry does not contain a valid version.'
        }
        return $versionMatch.Groups['value'].Value
    }

    return $null
}

function Get-PackageMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Output
    )

    $text = [string]::Join([Environment]::NewLine, [string[]] $Output)
    $packageMatch = [regex]::Match($text, '(?m)^\s*Package:\s*(?<value>[^\r\n]+?)\s*$')
    $versionMatch = [regex]::Match(
        $text,
        '(?m)^\s*Version:\s*(?<value>[0-9]+\.[0-9]+\.[0-9]+)\s*$'
    )
    if (-not $packageMatch.Success -or -not $versionMatch.Success) {
        throw 'The downloaded IPK does not contain valid package metadata.'
    }

    [PSCustomObject] @{
        appId = $packageMatch.Groups['value'].Value
        version = $versionMatch.Groups['value'].Value
    }
}

function Get-UpdateDecision {
    param(
        [AllowNull()]
        [string] $InstalledVersion,

        [Parameter(Mandatory = $true)]
        [string] $ReleaseVersion,

        [switch] $Force
    )

    $release = [Version] $ReleaseVersion
    if ([string]::IsNullOrWhiteSpace($InstalledVersion)) {
        return 'Install'
    }

    $installed = [Version] $InstalledVersion
    if ($installed -gt $release) {
        return 'RejectDowngrade'
    }
    if ($installed -eq $release) {
        if ($Force) {
            return 'Reinstall'
        }
        return 'Current'
    }
    return 'Install'
}

function Test-PrivateIPv4Address {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Address
    )

    if ($Address -notmatch '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}$') {
        return $false
    }

    $parsedAddress = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref] $parsedAddress) -or
        $parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $octets = $parsedAddress.GetAddressBytes()
    return (
        $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    )
}

function Assert-ReleaseFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [long] $ExpectedSize
    )

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -ne $ExpectedSize) {
        throw "Downloaded package size does not match the release manifest."
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $ExpectedSha256.ToLowerInvariant()) {
        throw 'Downloaded package SHA-256 does not match the release manifest.'
    }
}

function Assert-DeviceName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($Name -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw 'DeviceName may contain only letters, numbers, periods, underscores, and hyphens.'
    }
}

function Assert-RequiredCommands {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Names
    )

    foreach ($name in $Names) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            throw "Required command '$name' was not found. Install Node.js and then run: npm install -g @webos-tools/cli"
        }
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [string[]] $Arguments = @(),

        [switch] $HideOutput
    )

    $command = Get-Command $Name -ErrorAction Stop
    $output = & $command.Source @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = [string]::Join([Environment]::NewLine, [string[]] $output)
        throw "'$Name' failed with exit code $exitCode.`n$details"
    }
    if (-not $HideOutput) {
        return [string[]] $output
    }
}

function Get-ReleaseManifest {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $response = Invoke-WebRequest -Uri $ReleaseManifestUrl -UseBasicParsing
    ConvertFrom-ReleaseManifest -Json ([string] $response.Content)
}

function Initialize-TvConnection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Address
    )

    Assert-DeviceName -Name $Name
    if (-not (Test-PrivateIPv4Address -Address $Address)) {
        throw 'TvIp must be a private IPv4 address on the same home network as this PC.'
    }
    Assert-RequiredCommands -Names @('ares-setup-device', 'ares-novacom', 'ares-device')

    $deviceList = Invoke-ExternalCommand -Name 'ares-setup-device' -Arguments @('-l')
    $escapedName = [regex]::Escape($Name)
    $deviceExists = ([string]::Join([Environment]::NewLine, $deviceList) -match
        "(?m)^\s*$escapedName(?:\s+\(default\))?\s+")

    $mode = if ($deviceExists) { '-m' } else { '-a' }
    Invoke-ExternalCommand -Name 'ares-setup-device' -Arguments @(
        $mode,
        $Name,
        '-i', 'username=prisoner',
        '-i', "host=$Address",
        '-i', 'port=9922'
    ) -HideOutput

    Write-Host 'On the TV, open Developer Mode and note the Key Server passphrase.'
    Write-Host 'Enter that passphrase at the prompt below. It is stored by the webOS CLI, not in this script.'
    $novacom = Get-Command 'ares-novacom' -ErrorAction Stop
    & $novacom.Source '--getkey' '-d' $Name
    if ($LASTEXITCODE -ne 0) {
        throw "'ares-novacom --getkey' could not pair with the TV."
    }

    Invoke-ExternalCommand -Name 'ares-device' -Arguments @('-i', '-d', $Name) -HideOutput
    Write-Host "Setup complete. '$Name' is connected."
}

function Install-LatestRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [switch] $Reinstall,

        [switch] $SkipLaunch
    )

    Assert-DeviceName -Name $Name
    Assert-RequiredCommands -Names @('ares-device', 'ares-install', 'ares-package', 'ares-launch')
    Invoke-ExternalCommand -Name 'ares-device' -Arguments @('-i', '-d', $Name) -HideOutput

    Write-Host 'Checking the signed-off webOS release manifest...'
    $manifest = Get-ReleaseManifest
    $installedApps = Invoke-ExternalCommand -Name 'ares-install' -Arguments @('-F', '-d', $Name)
    $installedVersion = Get-InstalledAppVersion -Output $installedApps
    $decision = Get-UpdateDecision `
        -InstalledVersion $installedVersion `
        -ReleaseVersion $manifest.version `
        -Force:$Reinstall

    if ($decision -eq 'RejectDowngrade') {
        throw "The TV has version $installedVersion, which is newer than published version $($manifest.version). Downgrades are blocked."
    }
    if ($decision -eq 'Current') {
        Write-Host "2095Sport $installedVersion is already current on '$Name'."
        return
    }

    $temporaryPackage = Join-Path (
        [IO.Path]::GetTempPath()
    ) "2095Sport-$($manifest.version)-$([Guid]::NewGuid()).ipk"

    try {
        Write-Host "Downloading verified 2095Sport $($manifest.version)..."
        Invoke-WebRequest -Uri $manifest.assetUrl -OutFile $temporaryPackage -UseBasicParsing
        Assert-ReleaseFile `
            -Path $temporaryPackage `
            -ExpectedSha256 $manifest.sha256 `
            -ExpectedSize $manifest.size

        $packageOutput = Invoke-ExternalCommand -Name 'ares-package' -Arguments @('-i', $temporaryPackage)
        $packageMetadata = Get-PackageMetadata -Output $packageOutput
        if ($packageMetadata.appId -cne $ExpectedAppId -or
            $packageMetadata.version -cne $manifest.version) {
            throw 'Downloaded IPK identity does not match the release manifest.'
        }

        Write-Host "Installing 2095Sport $($manifest.version) on '$Name'..."
        Invoke-ExternalCommand -Name 'ares-install' -Arguments @($temporaryPackage, '-d', $Name) -HideOutput

        $updatedApps = Invoke-ExternalCommand -Name 'ares-install' -Arguments @('-F', '-d', $Name)
        $updatedVersion = Get-InstalledAppVersion -Output $updatedApps
        if ($updatedVersion -cne $manifest.version) {
            throw "Install verification failed: expected $($manifest.version), found '$updatedVersion'."
        }

        if (-not $SkipLaunch) {
            Invoke-ExternalCommand -Name 'ares-launch' -Arguments @($ExpectedAppId, '-d', $Name) -HideOutput
        }
        Write-Host "2095Sport $updatedVersion is installed and verified on '$Name'."
    } finally {
        Remove-Item -LiteralPath $temporaryPackage -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Main {
    if ($Setup) {
        if ([string]::IsNullOrWhiteSpace($TvIp)) {
            throw 'Setup requires -TvIp with the private address shown by the TV Developer Mode app.'
        }
        Initialize-TvConnection -Name $DeviceName -Address $TvIp
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($TvIp)) {
        throw '-TvIp is used only with -Setup.'
    }
    Install-LatestRelease -Name $DeviceName -Reinstall:$Force -SkipLaunch:$NoLaunch
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
