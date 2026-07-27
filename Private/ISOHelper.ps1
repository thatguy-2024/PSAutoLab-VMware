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
    Initialize-ISOWriterType

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

function Initialize-ISOWriterType {
    <#
    .SYNOPSIS
        Compile the tiny unsafe helper that streams an IMAPI2 IStream to a file.
    .DESCRIPTION
        Shared by New-ISOFile and ConvertTo-LabNoPromptISO. Compiling is a
        no-op if the type already exists in the session.
    #>
    [CmdletBinding()]
    param()

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
}

function ConvertTo-LabNoPromptISO {
    <#
    .SYNOPSIS
        Rebuild a Windows install ISO so it boots without the 'Press any key'
        prompt on UEFI firmware.
    .DESCRIPTION
        Windows installation ISOs boot UEFI systems through efisys.bin, which
        always displays 'Press any key to boot from CD or DVD...' and, when no
        key is pressed, times out and lets the firmware fall through to the
        next boot device. That breaks a hands-free lab build.

        Every Microsoft ISO also ships efi\microsoft\boot\efisys_noprompt.bin,
        a loader without the prompt. This function mounts the source ISO and
        repacks its contents into <name>_noprompt.iso with efisys_noprompt.bin
        as the El Torito EFI boot image. The rebuild happens once per media;
        subsequent calls return the cached _noprompt.iso immediately.

        Prefers oscdimg.exe (Windows ADK) when available; otherwise uses the
        built-in IMAPI2FS COM interfaces (UDF, EFI boot entry) - no external
        dependencies required.
    .PARAMETER Path
        Path of the original install ISO.
    .EXAMPLE
        PS C:\> ConvertTo-LabNoPromptISO -Path C:\AutolabVMware\ISOs\Server2019.iso
    .OUTPUTS
        String. The path of the no-prompt ISO (or the original path if the
        conversion is not possible; a warning explains the manual keypress).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path
    )

    $noPromptPath = Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath ("{0}_noprompt.iso" -f [IO.Path]::GetFileNameWithoutExtension($Path))
    if (Test-Path -Path $noPromptPath) {
        Write-Verbose "No-prompt ISO already present: $noPromptPath"
        return $noPromptPath
    }

    if (-not $PSCmdlet.ShouldProcess($noPromptPath, 'Create no-prompt boot ISO')) {
        return $Path
    }

    Write-LabMessage -Message "Rebuilding $(Split-Path $Path -Leaf) without the 'Press any key' boot prompt (one time per media, takes a few minutes and ~5GB of disk)" -Color Yellow

    $mounted = $false
    try {
        # mount the source ISO to read its contents
        $img = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop
        $mounted = $true
        $drive = ($img | Get-Volume).DriveLetter
        if (-not $drive) { throw "Mounted $Path but no drive letter was assigned." }
        $root = "${drive}:\"

        $bootFile = Join-Path -Path $root -ChildPath 'efi\microsoft\boot\efisys_noprompt.bin'
        if (-not (Test-Path -Path $bootFile)) {
            Write-Warning "No efisys_noprompt.bin on $Path - cannot remove the boot prompt. You will need to click into the VM console and press a key at the 'Press any key to boot from CD or DVD' prompt."
            return $Path
        }

        $volumeName = 'NOPROMPT'
        try {
            $vol = ($img | Get-Volume).FileSystemLabel
            if ($vol) { $volumeName = $vol }
        }
        catch { Write-Verbose 'Could not read source volume label; using NOPROMPT.' }

        # 1) try oscdimg (Windows ADK) - fastest and produces dual BIOS/UEFI boot
        $oscdimg = Get-Command -Name oscdimg.exe -ErrorAction SilentlyContinue
        if (-not $oscdimg) {
            $adkPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
            if (Test-Path $adkPath) { $oscdimg = Get-Command $adkPath }
        }
        if ($oscdimg) {
            Write-Verbose "Rebuilding ISO with oscdimg: $noPromptPath"
            $etfsboot = Join-Path -Path $root -ChildPath 'boot\etfsboot.com'
            if (Test-Path $etfsboot) {
                $bootData = "2#p0,e,b$etfsboot#pEF,e,b$bootFile"
            }
            else {
                $bootData = "1#pEF,e,b$bootFile"
            }
            $null = & $oscdimg.Source -m -o -u2 -udfver102 "-bootdata:$bootData" $root $noPromptPath 2>&1
            if (($LASTEXITCODE -eq 0) -and (Test-Path $noPromptPath)) { return $noPromptPath }
            Write-Verbose 'oscdimg failed; falling back to IMAPI2.'
        }

        # 2) IMAPI2FS COM fallback (built in to Windows). UDF handles the >4GB
        # install.wim; the lab VMs are EFI-only so a single EFI boot entry from
        # efisys_noprompt.bin is sufficient.
        Write-Verbose "Rebuilding ISO with IMAPI2FS: $noPromptPath"
        Initialize-ISOWriterType

        $bootStream = New-Object -ComObject ADODB.Stream
        $bootStream.Open()
        $bootStream.Type = 1              # binary
        $bootStream.LoadFromFile($bootFile)

        $bootOptions = New-Object -ComObject IMAPI2FS.BootOptions
        $bootOptions.PlatformId = 0xEF    # EFI
        $bootOptions.Emulation = 0        # no emulation
        $bootOptions.Manufacturer = 'Microsoft'
        $bootOptions.AssignBootImage($bootStream)

        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 4      # UDF (supports files > 4GB)
        $fsi.UDFRevision = 0x102
        $fsi.VolumeName = $volumeName
        $fsi.FreeMediaBlocks = 0          # no size limit
        $fsi.BootImageOptions = $bootOptions
        $fsi.Root.AddTree($root, $false)

        $image = $fsi.CreateResultImage()
        [PSAutoLabVMware.ISOWriter]::Create($noPromptPath, $image.ImageStream, $image.BlockSize, $image.TotalBlocks)

        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($image)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($bootOptions)
        $bootStream.Close()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($bootStream)

        if (-not (Test-Path -Path $noPromptPath)) {
            throw "Failed to create no-prompt ISO at $noPromptPath"
        }
        return $noPromptPath
    }
    catch {
        if (Test-Path -Path $noPromptPath) { Remove-Item -Path $noPromptPath -Force -ErrorAction SilentlyContinue }
        Write-Warning "Could not rebuild $Path without the boot prompt: $($_.Exception.Message)"
        Write-Warning "Falling back to the original ISO. You will need to click into the VM console and press a key at the 'Press any key to boot from CD or DVD' prompt right after Run-Lab powers the VM on."
        return $Path
    }
    finally {
        if ($mounted) {
            try { [void](Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue) } catch { Write-Verbose 'Dismount failed (non-fatal).' }
        }
    }
}
