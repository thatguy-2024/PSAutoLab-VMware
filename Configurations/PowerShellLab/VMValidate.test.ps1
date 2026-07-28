<#
    Generic PSAutoLabVMware validation test (Pester 5.x).

    This test replaces the original PS-AutoLab-Env VMValidate tests which used
    PowerShell Direct (New-PSSession -VMName), a Hyper-V-only feature. VMware
    Workstation has no equivalent, so this test connects to each lab VM over
    WinRM using the static lab IP addresses defined in VMConfigurationData.psd1.

    It is copied into every configuration folder and is data-driven: it reads
    the VMConfigurationData.psd1 in its own folder and validates every node:

      * WinRM session can be established with the expected credentials
      * Computer name matches the node definition
      * Static IP address matches the node definition
      * DNS server matches the node definition
      * Operating system matches the requested media
      * Domain membership for DC / DomainJoin roles
      * DSC configuration status (when available)

    Run via Validate-Lab (Invoke-ValidateLab) from the configuration folder,
    or directly: Invoke-Pester -Path .\VMValidate.test.ps1
#>
#requires -version 5.1
#requires -Modules @{ModuleName='Pester'; ModuleVersion='5.0.0'}

BeforeDiscovery {
    # Load the configuration data for the lab in this folder
    $dataFile = Join-Path -Path $PSScriptRoot -ChildPath 'VMConfigurationData.psd1'
    $script:LabData = Import-PowerShellDataFile -Path $dataFile

    $allNodes = @($script:LabData.AllNodes)
    $default = $allNodes | Where-Object { $_.NodeName -eq '*' } | Select-Object -First 1
    if (-not $default) { $default = @{} }

    # Build the node list used to generate test containers
    $script:TestNodes = foreach ($node in ($allNodes | Where-Object { $_.NodeName -ne '*' })) {
        $pick = {
            param($key, $fallback)
            if ($node.ContainsKey($key)) { $node[$key] }
            elseif ($default.ContainsKey($key)) { $default[$key] }
            else { $fallback }
        }
        [pscustomobject]@{
            Computername = $node.NodeName
            IPAddress    = & $pick 'IPAddress' $null
            SubnetMask   = & $pick 'SubnetMask' 24
            DnsServer    = & $pick 'DnsServerAddress' (& $pick 'IPAddress' $null)
            Role         = @(& $pick 'Role' @())
            Media        = & $pick 'Lability_Media' '2022_Core'
            DomainName   = & $pick 'DomainName' 'Company.pri'
            Password     = & $pick 'LabPassword' 'P@ssw0rd'
        }
    }
}

Describe 'Lab VM <_.Computername>' -ForEach $script:TestNodes {

    BeforeAll {
        $node = $_
        $secure = ConvertTo-SecureString -String $node.Password -AsPlainText -Force

        # Domain controllers and domain-joined members authenticate with the
        # domain administrator account; everything else uses the local admin.
        $isDC = $node.Role -contains 'DC'
        $isDomainMember = ($node.Role -contains 'DomainJoin') -or ($node.Role -contains 'domainJoin')
        if ($isDC -or $isDomainMember) {
            $netbios = ($node.DomainName -split '\.')[0]
            $userName = "$netbios\Administrator"
        }
        else {
            $userName = "$($node.Computername)\Administrator"
        }
        $cred = [pscredential]::new($userName, $secure)

        # A local-admin fallback credential covers machines that have not yet
        # joined the domain (DSC still converging).
        $localCred = [pscredential]::new(".\Administrator", $secure)

        $script:session = $null
        try {
            $script:session = New-PSSession -ComputerName $node.IPAddress -Credential $cred -Authentication Negotiate -ErrorAction Stop
        }
        catch {
            try {
                $script:session = New-PSSession -ComputerName $node.IPAddress -Credential $localCred -Authentication Negotiate -ErrorAction SilentlyContinue
            }
            catch { }
        }

        # Map media IDs to expected OS caption fragments
        $script:osMatch = switch -Wildcard ($node.Media) {
            '2016*' { 'Server 2016' }
            '2019*' { 'Server 2019' }
            '2022*' { 'Server 2022' }
            'WIN10*' { 'Windows 10' }
            'WIN11*' { 'Windows 11' }
            default { 'Windows' }
        }
    }

    AfterAll {
        if ($script:session) {
            Remove-PSSession -Session $script:session -ErrorAction SilentlyContinue
        }
    }

    It 'Accepts a WinRM connection at <_.IPAddress>' {
        $script:session | Should -Not -BeNullOrEmpty
        $script:session.State | Should -Be 'Opened'
    }

    It 'Has the expected computer name' {
        $name = Invoke-Command -Session $script:session -ScriptBlock { $env:COMPUTERNAME }
        $name | Should -Be $_.Computername
    }

    It 'Has the expected static IP address' {
        $ips = Invoke-Command -Session $script:session -ScriptBlock {
            (Get-NetIPAddress -AddressFamily IPv4).IPAddress
        }
        $ips | Should -Contain $_.IPAddress
    }

    It 'Uses the expected DNS server' {
        $dns = Invoke-Command -Session $script:session -ScriptBlock {
            (Get-DnsClientServerAddress -AddressFamily IPv4 |
                Where-Object { $_.ServerAddresses } |
                Select-Object -First 1).ServerAddresses
        }
        $dns | Should -Contain $_.DnsServer
    }

    It 'Is running the expected operating system' {
        $caption = Invoke-Command -Session $script:session -ScriptBlock {
            (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
        }
        $caption | Should -BeLike "*$script:osMatch*"
    }

    It 'Is joined to the lab domain' -Skip:(-not (($_.Role -contains 'DC') -or ($_.Role -contains 'DomainJoin') -or ($_.Role -contains 'domainJoin'))) {
        $cs = Invoke-Command -Session $script:session -ScriptBlock {
            Get-CimInstance -ClassName Win32_ComputerSystem
        }
        $cs.PartOfDomain | Should -BeTrue
        $cs.Domain | Should -Be $_.DomainName
    }

    It 'Is running Active Directory Web Services' -Skip:(-not ($_.Role -contains 'DC')) {
        $svc = Invoke-Command -Session $script:session -ScriptBlock {
            Get-Service -Name ADWS -ErrorAction SilentlyContinue
        }
        $svc.Status | Should -Be 'Running'
    }

    It 'Has completed the DSC configuration without pending reboots' {
        $lcm = Invoke-Command -Session $script:session -ScriptBlock {
            Get-DscLocalConfigurationManager
        }
        $lcm.LCMState | Should -Not -Be 'PendingReboot'
    }
}
