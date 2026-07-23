# MediaHelper.ps1
# Maps Lability media IDs to VMware guestOS types, autounattend templates,
# Windows image names and evaluation ISO download locations. Not exported.

# Master media table. Keys are the Lability media IDs used by the original
# PS-AutoLab-Env configurations. GuestOS values target VMware Workstation Pro 17+.
$script:LabMediaMap = @{
    '2016_x64_Standard_Core_EN_Eval'  = @{
        Description = 'Windows Server 2016 Standard 64bit English Evaluation (Core)'
        GuestOS     = 'windows9srv-64'
        Template    = 'Server2016Core.xml'
        ImageName   = 'Windows Server 2016 SERVERSTANDARDCORE'
        ISOName     = '14393.0.161119-1705.RS1_REFRESH_SERVER_EVAL_X64FRE_EN-US.ISO'
        URI         = 'https://download.microsoft.com/download/1/4/9/149D5452-9B29-4274-B6B3-5361DBDA30BC/14393.0.161119-1705.RS1_REFRESH_SERVER_EVAL_X64FRE_EN-US.ISO'
        OSMatch     = '*2016*'
        InstallType = 'Server Core'
    }
    '2016_x64_Standard_EN_Eval'       = @{
        Description = 'Windows Server 2016 Standard 64bit English Evaluation (Desktop Experience)'
        GuestOS     = 'windows9srv-64'
        Template    = 'Server2016GUI.xml'
        ImageName   = 'Windows Server 2016 SERVERSTANDARD'
        ISOName     = '14393.0.161119-1705.RS1_REFRESH_SERVER_EVAL_X64FRE_EN-US.ISO'
        URI         = 'https://download.microsoft.com/download/1/4/9/149D5452-9B29-4274-B6B3-5361DBDA30BC/14393.0.161119-1705.RS1_REFRESH_SERVER_EVAL_X64FRE_EN-US.ISO'
        OSMatch     = '*2016*'
        InstallType = 'Server'
    }
    '2019_x64_Standard_EN_Core_Eval'  = @{
        Description = 'Windows Server 2019 Standard 64bit English Evaluation (Core)'
        GuestOS     = 'windows2019srv-64'
        Template    = 'Server2019Core.xml'
        ImageName   = 'Windows Server 2019 Standard Evaluation'
        ISOName     = '17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us_1.iso'
        URI         = 'https://software-download.microsoft.com/download/pr/17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us_1.iso'
        OSMatch     = '*2019*'
        InstallType = 'Server Core'
    }
    '2019_x64_Standard_EN_Eval'       = @{
        Description = 'Windows Server 2019 Standard 64bit English Evaluation (Desktop Experience)'
        GuestOS     = 'windows2019srv-64'
        Template    = 'Server2019GUI.xml'
        ImageName   = 'Windows Server 2019 Standard Evaluation (Desktop Experience)'
        ISOName     = '17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us_1.iso'
        URI         = 'https://software-download.microsoft.com/download/pr/17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us_1.iso'
        OSMatch     = '*2019*'
        InstallType = 'Server'
    }
    '2022_x64_Standard_EN_Core_Eval'  = @{
        Description = 'Windows Server 2022 Standard 64bit English Evaluation (Core)'
        GuestOS     = 'windows2019srvnext-64'
        Template    = 'Server2022Core.xml'
        ImageName   = 'Windows Server 2022 Standard Evaluation'
        ISOName     = 'SERVER_EVAL_x64FRE_en-us.iso'
        URI         = 'https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso'
        OSMatch     = '*2022*'
        InstallType = 'Server Core'
    }
    '2022_x64_Standard_EN_Eval'       = @{
        Description = 'Windows Server 2022 Standard 64bit English Evaluation (Desktop Experience)'
        GuestOS     = 'windows2019srvnext-64'
        Template    = 'Server2022GUI.xml'
        ImageName   = 'Windows Server 2022 Standard Evaluation (Desktop Experience)'
        ISOName     = 'SERVER_EVAL_x64FRE_en-us.iso'
        URI         = 'https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso'
        OSMatch     = '*2022*'
        InstallType = 'Server'
    }
    'WIN10_x64_Enterprise_22H2_EN_Eval' = @{
        Description = 'Windows 10 Enterprise 22H2 64bit English Evaluation'
        GuestOS     = 'windows9-64'
        Template    = 'Windows10.xml'
        ImageName   = 'Windows 10 Enterprise Evaluation'
        ISOName     = '19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'
        URI         = 'https://software-download.microsoft.com/download/sg/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'
        OSMatch     = '*Windows 10*'
        InstallType = 'Client'
    }
    'WIN11_x64_Enterprise_23H2_EN_Eval' = @{
        Description = 'Windows 11 Enterprise 23H2 64bit English Evaluation'
        GuestOS     = 'windows11-64'
        Template    = 'Windows11.xml'
        ImageName   = 'Windows 11 Enterprise Evaluation'
        ISOName     = '22631.2428.231001-0608.23H2_ni_release_svc_refresh_CLIENT_ENTERPRISES_OEM_x64FRE_en-us.iso'
        URI         = 'https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/22631.2428.231001-0608.23H2_ni_release_svc_refresh_CLIENT_ENTERPRISES_OEM_x64FRE_en-us.iso'
        OSMatch     = '*Windows 11*'
        InstallType = 'Client'
    }
}

function Get-LabMediaInfo {
    <#
    .SYNOPSIS
        Resolve a Lability media ID to its VMware media definition.
    .DESCRIPTION
        Looks up the media ID in the module's media map and returns a
        PSCustomObject with GuestOS (VMware guestOS value), autounattend
        template file, image name, ISO file name and download URI.
        Unknown IDs fall back to a Server 2022 Core definition with a warning.
    .PARAMETER Id
        The Lability media ID, e.g. 2019_x64_Standard_EN_Core_Eval.
    .EXAMPLE
        PS C:\> Get-LabMediaInfo -Id 2022_x64_Standard_EN_Core_Eval
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    $entry = $script:LabMediaMap[$Id]
    if (-not $entry) {
        Write-Warning "Unknown media ID '$Id'. Falling back to 2022_x64_Standard_EN_Core_Eval settings. Add a definition to MediaHelper.ps1 if needed."
        $entry = $script:LabMediaMap['2022_x64_Standard_EN_Core_Eval']
    }

    [PSCustomObject]([ordered]@{ PSTypeName = 'PSAutoLabVMware.LabMedia'; Id = $Id } + $entry)
}

function Get-LabISO {
    <#
    .SYNOPSIS
        Ensure the installation ISO for a media ID exists locally, downloading it if needed.
    .DESCRIPTION
        Looks for <IsoPath>\<ISOName>. If missing, downloads the Microsoft
        evaluation ISO from the media map URI using BITS (falling back to
        Invoke-WebRequest) and writes an MD5 .checksum sidecar file, matching the
        original module's Test-ISOImage behavior. Returns the local ISO path.

        If Microsoft has retired a download URL, place the ISO in the ISOs folder
        manually using the expected file name and re-run the command.
    .PARAMETER Id
        The Lability media ID.
    .EXAMPLE
        PS C:\> Get-LabISO -Id WIN10_x64_Enterprise_22H2_EN_Eval
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    $media = Get-LabMediaInfo -Id $Id
    $isoDir = $script:AutoLabFolders.IsoPath
    if (-not (Test-Path $isoDir)) { [void](New-Item -Path $isoDir -ItemType Directory -Force) }
    $isoPath = Join-Path -Path $isoDir -ChildPath $media.ISOName

    if (Test-Path -Path $isoPath) {
        Write-Verbose "ISO already present: $isoPath"
        return $isoPath
    }

    Write-LabMessage -Message "Downloading $($media.Description) ISO. This is a 4-5GB download and only happens once per media." -Color Yellow
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $media.URI -Destination $isoPath -DisplayName $media.Id -ErrorAction Stop
        }
        else {
            Invoke-WebRequest -Uri $media.URI -OutFile $isoPath -UseBasicParsing -ErrorAction Stop
        }
    }
    catch {
        if (Test-Path $isoPath) { Remove-Item $isoPath -Force }
        throw "Failed to download ISO for media '$Id' from $($media.URI). Microsoft may have retired this URL. Download the evaluation ISO manually from https://www.microsoft.com/evalcenter and save it as $isoPath. Error: $($_.Exception.Message)"
    }

    # write MD5 checksum sidecar (same convention as Lability/Test-ISOImage)
    try {
        $hash = (Get-FileHash -Path $isoPath -Algorithm MD5).Hash
        Set-Content -Path "$isoPath.checksum" -Value $hash -Encoding Ascii
    }
    catch {
        Write-Warning "Could not write checksum file for $isoPath : $($_.Exception.Message)"
    }

    $isoPath
}
