# ISOHelper.ps1
# Builds the small secondary ISO (autounattend.xml + Bootstrap.ps1) attached to
# each VM. Windows Setup automatically searches all removable drives for
# autounattend.xml, so a second CD-ROM is the VMware equivalent of Lability's
# offline unattend injection. Uses oscdimg.exe when available, otherwise the
# built-in IMAPI2 COM interfaces. Not exported.

function New-LabUnattendISO {
    <#
    .SYNOPSIS
        Create the autounattend/bootstrap ISO for a lab node.
    .DESCRIPTION
        Renders the node's autounattend.xml (New-LabUnattendXml) and the
        Bootstrap.ps1 first-logon script (New-LabBootstrapScript) into a staging
        folder, then packs them into an ISO-9660/Joliet image named
        <VMName>-unattend.iso under the UnattendISOs folder.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER Password
        The lab administrator password (LabPassword).
    .EXAMPLE
        PS C:\> New-LabUnattendISO -Node $node -Password 'P@ssw0rd'
    .OUTPUTS
        String. The path of the created ISO.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter(Mandatory)]
        [string]$Password
    )

    $isoDir = $script:AutoLabFolders.UnattendIsoPath
    if (-not (Test-Path $isoDir)) { [void](New-Item -Path $isoDir -ItemType Directory -Force) }
    $isoPath = Join-Path -Path $isoDir -ChildPath "$($Node.VMName)-unattend.iso"

    $staging = Join-Path -Path $env:TEMP -ChildPath "PSAutoLabVMware-$($Node.VMName)"
    if (Test-Path $staging) { Remove-Item -Path $staging -Recurse -Force }
    [void](New-Item -Path $staging -ItemType Directory -Force)

    try {
        [void](New-LabUnattendXml -Node $Node -Password $Password -OutputPath (Join-Path $staging 'autounattend.xml'))
        New-LabBootstrapScript -Node $Node | Set-Content -Path (Join-Path $staging 'Bootstrap.ps1') -Encoding UTF8

        if ($PSCmdlet.ShouldProcess($isoPath, 'Create unattend ISO')) {
            # New-ISOFile also emits the destination path; suppress it so this
            # function returns exactly one string (the ISO path) at the end.
            [void](New-ISOFile -SourcePath $staging -DestinationPath $isoPath -VolumeName 'UNATTEND')
        }
    }
    finally {
        Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $isoPath
}

function New-ISOFile {
    <#
    .SYNOPSIS
        Pack a folder into an ISO-9660/Joliet image.
    .DESCRIPTION
        Prefers oscdimg.exe (Windows ADK) when it is on the PATH or in the ADK
        default location; otherwise uses the IMAPI2FS COM object that ships with
        every Windows version - no external dependencies required.
    .PARAMETER SourcePath
        Folder whose contents become the ISO root.
    .PARAMETER DestinationPath
        Path of the .iso file to create (overwritten if present).
    .PARAMETER VolumeName
        ISO volume label. Default UNATTEND.
    .EXAMPLE
        PS C:\> New-ISOFile -SourcePath C:\staging -DestinationPath C:\out.iso
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$VolumeName = 'UNATTEND'
    )

    if (Test-Path -Path $DestinationPath) {
        Remove-Item -Path $DestinationPath -Force
    }

    # 1) try oscdimg (Windows ADK)
    $oscdimg = Get-Command -Name oscdimg.exe -ErrorAction SilentlyContinue
    if (-not $oscdimg) {
        $adkPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
        if (Test-Path $adkPath) { $oscdimg = Get-Command $adkPath }
    }
    if ($oscdimg) {
        Write-Verbose "Creating ISO with oscdimg: $DestinationPath"
        $null = & $oscdimg.Source -j1 -o -m "-l$VolumeName" $SourcePath $DestinationPath 2>&1
        if (($LASTEXITCODE -eq 0) -and (Test-Path $DestinationPath)) { return $DestinationPath }
        Write-Verbose 'oscdimg failed; falling back to IMAPI2.'
    }

    # 2) IMAPI2FS COM fallback (built in to Windows)
    Write-Verbose "Creating ISO with IMAPI2FS: $DestinationPath"

    # compile a tiny unsafe helper that streams the COM IStream to a file
    if (-not ('PSAutoLabVMware.ISOWriter' -as [type])) {
        $cp = New-Object CodeDom.Compiler.CompilerParameters
        $cp.CompilerOptions = '/unsafe'
        Add-Type -CompilerParameters $cp -TypeDefinition @'
namespace PSAutoLabVMware {
    public class ISOWriter {
        public unsafe static void Create(string path, object stream, int blockSize, int totalBlocks) {
            int bytes = 0;
            byte[] buf = new byte[blockSize];
            var ptr = (System.IntPtr)(&bytes);
            var i = stream as System.Runtime.InteropServices.ComTypes.IStream;
            using (var fs = System.IO.File.OpenWrite(path)) {
                while (totalBlocks-- > 0) {
                    i.Read(buf, blockSize, ptr);
                    fs.Write(buf, 0, bytes);
                }
                fs.Flush();
            }
        }
    }
}
'@
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3      # ISO9660 + Joliet
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTree($SourcePath, $false)

    $image = $fsi.CreateResultImage()
    [PSAutoLabVMware.ISOWriter]::Create($DestinationPath, $image.ImageStream, $image.BlockSize, $image.TotalBlocks)

    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($image)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)

    if (-not (Test-Path -Path $DestinationPath)) {
        throw "Failed to create ISO image at $DestinationPath"
    }
    $DestinationPath
}
