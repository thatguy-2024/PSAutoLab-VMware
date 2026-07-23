# UnattendHelper.ps1
# Generates per-node autounattend.xml files from the module's templates.
# Replaces Lability's offline unattend.xml injection into VHDX files: on VMware
# the unattend file rides in on a secondary ISO and drives Windows Setup.
# Not exported.

function New-LabUnattendXml {
    <#
    .SYNOPSIS
        Generate an autounattend.xml for a lab node from the media's template.
    .DESCRIPTION
        Loads the template mapped to the node's media ID (Templates\*.xml),
        replaces the {{TOKEN}} placeholders with node-specific values
        (computer name, administrator password, static IP configuration,
        DNS, gateway, time zone and Windows image name) and returns the
        rendered XML text. The rendered file configures:
          * fully unattended disk partitioning (EFI/GPT layout)
          * the correct evaluation image (edition) selection
          * ComputerName and local Administrator password (LabPassword)
          * static IPv4 address, prefix, gateway and DNS on the first NIC
          * WinRM/PowerShell remoting enablement at first logon
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER Password
        The lab administrator password in plain text (LabPassword, typically P@ssw0rd).
    .PARAMETER OutputPath
        Optional path to also write the rendered XML to.
    .EXAMPLE
        PS C:\> New-LabUnattendXml -Node $node -Password 'P@ssw0rd' -OutputPath C:\staging\autounattend.xml
    .OUTPUTS
        String. The rendered autounattend.xml content.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter(Mandatory)]
        [string]$Password,

        [string]$OutputPath
    )

    $media = Get-LabMediaInfo -Id $Node.Media
    $templateFile = Join-Path -Path $script:TemplatePath -ChildPath $media.Template
    if (-not (Test-Path -Path $templateFile)) {
        throw "Autounattend template not found: $templateFile"
    }

    $xml = Get-Content -Path $templateFile -Raw

    # netmask may be given as prefix length (24) in the configuration data
    $prefixLength = [int]$Node.SubnetMask

    $tokens = @{
        '{{COMPUTERNAME}}'  = $Node.Computername
        '{{ADMINPASSWORD}}' = $Password
        '{{IPADDRESS}}'     = $Node.IPAddress
        '{{PREFIXLENGTH}}'  = $prefixLength
        '{{GATEWAY}}'       = $Node.DefaultGateway
        '{{DNSSERVER}}'     = $Node.DnsServer
        '{{TIMEZONE}}'      = $Node.TimeZone
        '{{IMAGENAME}}'     = $media.ImageName
        '{{OWNER}}'         = 'AutolabVMware'
        '{{ORGANIZATION}}'  = 'AutolabVMware'
    }

    foreach ($token in $tokens.Keys) {
        $value = [string]$tokens[$token]
        # XML-escape the values that could contain special characters
        $escaped = $value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
        $xml = $xml.Replace($token, $escaped)
    }

    if ($xml -match '\{\{[A-Z]+\}\}') {
        Write-Warning "Unreplaced tokens remain in the rendered autounattend.xml for $($Node.Computername): $($Matches[0])"
    }

    if ($OutputPath) {
        Set-Content -Path $OutputPath -Value $xml -Encoding UTF8 -Force
        Write-Verbose "Wrote autounattend.xml to $OutputPath"
    }
    $xml
}

function New-LabBootstrapScript {
    <#
    .SYNOPSIS
        Generate the in-guest bootstrap script placed on the unattend ISO.
    .DESCRIPTION
        Windows Setup's FirstLogonCommands run this script (Bootstrap.ps1) from
        the unattend ISO. It enables PowerShell remoting over HTTP, opens the
        firewall for WinRM/ICMP/SMB, raises the WinRM MaxEnvelopeSizeKb (the
        original configurations' CustomBootStrap does the same for MOF pushes),
        sets the network profile to Private and disables the setup CD boot on
        subsequent runs. DSC itself is pushed later from the host over WinRM.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .EXAMPLE
        PS C:\> New-LabBootstrapScript -Node $node | Set-Content C:\staging\Bootstrap.ps1
    .OUTPUTS
        String. The bootstrap script content.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node
    )

    @"
# PSAutoLabVMware guest bootstrap for $($Node.Computername)
# Runs once at first logon (from autounattend.xml FirstLogonCommands).
`$ErrorActionPreference = 'SilentlyContinue'
Start-Transcript -Path C:\Bootstrap.log -Force

# Make all connected networks Private so WinRM works
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Enable PowerShell remoting / WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\MaxEnvelopeSizeKb -Value 2000
Set-Item WSMan:\localhost\Service\Auth\Basic -Value `$true
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
winrm quickconfig -quiet

# Open lab firewall rules (ICMP + SMB + WinRM), mirroring FirewallRuleNames
Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In','FPS-ICMP6-ERQ-In','FPS-SMB-In-TCP','WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes

# Allow MOF pushes with plain-text credentials inside the isolated lab network
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord -Force

# Signal completion for the host's Wait-LabVM probe
Set-Content -Path C:\BootstrapComplete.txt -Value (Get-Date -Format o)

Stop-Transcript
"@
}
