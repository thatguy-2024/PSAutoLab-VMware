function Invoke-SetupLab {
    <#
    .SYNOPSIS
        Build the lab environment defined in the current configuration folder.
    .DESCRIPTION
        The VMware equivalent of the original Setup-Lab. Reads the folder's
        VMConfigurationData.psd1 (unchanged from PS-AutoLab-Env) and:

          * Installs the DSC resource modules the lab requires on the host
          * Compiles the DSC configuration (VMConfiguration.ps1) into per-node
            MOF files
          * Downloads the Windows evaluation ISO for each media ID (once)
          * Generates a per-node autounattend.xml + Bootstrap.ps1 ISO
            (unattended install: computer name, LabPassword administrator
            password, static IP, WinRM enablement)
          * Creates a VMDK system disk per VM with vmware-vdiskmanager
          * Generates a VMX file per VM (EFI, Secure Boot off, correct guestOS,
            CPU/memory from the configuration, host-only lab vmnet)

        Nothing is powered on; run Run-Lab afterwards to start the unattended
        Windows installation and apply the DSC configurations.
    .PARAMETER Path
        The path to the configuration folder. Normally you run all commands
        from within the configuration folder. Default is the current location.
    .PARAMETER UseLocalTimeZone
        Override any configuration-specified time zone with this computer's.
    .PARAMETER Force
        Recreate VMDK disks and VMX files if they already exist. Destroys any
        existing VM data for this lab.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Setup-Lab
        Builds the MultiRole lab VMs.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\SingleServer> Setup-Lab -UseLocalTimeZone -Force
        Rebuilds the lab from scratch using the host's time zone.
    .LINK
        Invoke-RunLab
    .LINK
        Invoke-UnattendLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Setup-Lab')]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [Parameter(HelpMessage = 'Override any configuration specified time zone and use the local time zone on this computer.')]
        [switch]$UseLocalTimeZone,

        [switch]$Force,

        [Parameter(HelpMessage = 'Run the command but suppress all status messages.')]
        [Alias('Quiet')]
        [switch]$NoMessages
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"

    $lab = Import-LabConfiguration -Path $Path

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    This is the Setup-Lab command (VMware backend). It will:

    * Install required DSC resource modules and compile the .mof files
    * Download Windows evaluation ISOs if needed (4-5GB each, first time only)
    * Create VMDK disks, autounattend ISOs and VMX files for:
      $(($lab.Nodes.Computername) -join ', ')

    You will be able to wipe and rebuild this lab without repeating the
    downloads.
"@
    }

    # optional local time zone override
    if ($UseLocalTimeZone) {
        $localTz = (Get-TimeZone).Id
        Write-LabMessage -Message "Overriding configured time zones to use $localTz" -Color Yellow -Quiet:$NoMessages
        foreach ($node in $lab.Nodes) {
            $node.TimeZone = $localTz
        }
    }

    # 1) DSC resource modules on the host
    Write-LabMessage -Message 'Installing required DSC resource modules from PSGallery' -Quiet:$NoMessages
    Install-LabDSCResource -Lab $lab -Quiet:$NoMessages

    # 2) compile MOFs with the original VMConfiguration.ps1
    Write-LabMessage -Message 'Building the .mof files from the configuration' -Quiet:$NoMessages
    if ($PSCmdlet.ShouldProcess((Join-Path $lab.Path 'VMConfiguration.ps1'), 'Compile DSC configuration')) {
        Invoke-LabDSCCompile -Path $lab.Path
    }

    # 3) stop any lab VMs that are still running. VMware locks the VMDK and
    # the attached ISOs while a VM is powered on (or suspended), which makes
    # the rebuild below fail with 'file is being used by another process' /
    # 'The file already exists'.
    foreach ($node in $lab.Nodes) {
        if ((Get-LabVMState -Node $node) -eq 'Running') {
            Write-LabMessage -Message "Powering off $($node.VMName) before rebuilding its files" -Color Yellow -Quiet:$NoMessages
            if ($PSCmdlet.ShouldProcess($node.VMName, 'vmrun stop hard')) {
                [void](Invoke-VMRun -Command stop -Arguments (Get-LabVMXPath -Node $node), 'hard' -IgnoreErrors)
                # give VMware a moment to release its file locks
                Start-Sleep -Seconds 3
            }
        }
    }

    # 4) per-node provisioning
    foreach ($node in $lab.Nodes) {
        Write-LabMessage -Message "Provisioning $($node.VMName) [$($node.Description)]" -Color Green -Quiet:$NoMessages

        # install ISO (download once per media)
        $installIso = Get-LabISO -Id $node.Media

        # rebuild without the UEFI 'Press any key to boot from CD or DVD'
        # prompt (once per media) so the install is fully hands-free
        $installIso = ConvertTo-LabNoPromptISO -Path $installIso

        # unattend ISO
        Write-Verbose "Creating autounattend ISO for $($node.Computername)"
        $unattendIso = New-LabUnattendISO -Node $node -Password $lab.Password

        # VMDK
        Write-Verbose "Creating VMDK for $($node.Computername)"
        [void](New-LabVMDK -Node $node -Force:$Force)

        # VMX
        Write-Verbose "Creating VMX for $($node.Computername)"
        $vmx = Get-LabVMXPath -Node $node
        if ((Test-Path $vmx) -and -not $Force) {
            Write-LabMessage -Message "VMX already exists for $($node.VMName); skipping (use -Force to recreate)" -Color Yellow -Quiet:$NoMessages
        }
        else {
            [void](New-LabVMX -Node $node -InstallISO $installIso -UnattendISO $unattendIso)
        }
    }

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    Next Steps:

    When this task is complete, run:
    Run-Lab
    (this powers on the VMs, performs the unattended Windows installation
    and pushes the DSC configurations over WinRM)

    To enable Internet access for the VMs, run:
    Enable-Internet

    Run the following to validate when configurations have converged:
    Validate-Lab

    To stop the lab VMs:
    Shutdown-Lab

    When the configurations have finished, you can snapshot the VMs with:
    Snapshot-Lab

    To quickly rebuild the labs from the snapshot, run:
    Refresh-Lab

    To destroy the lab to build again:
    Wipe-Lab

"@
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
