# Cross-platform smoke test for PSAutoLabVMware core adapter logic:
# Import-LabConfiguration -> node mapping -> New-LabVMX -> New-LabUnattendXml
$ErrorActionPreference = 'Stop'
$root = '/home/ubuntu/PSAutoLabVMware'

# Provide module-scope variables normally set by the psm1
$script:AutoLabRoot = '/tmp/autolab-smoke'
$script:AutoLabFolders = @{
    ConfigurationPath = "$script:AutoLabRoot/Configurations"
    VMPath            = "$script:AutoLabRoot/VMs"
    IsoPath           = "$script:AutoLabRoot/ISOs"
    UnattendIsoPath   = "$script:AutoLabRoot/UnattendISOs"
    ResourcePath      = "$script:AutoLabRoot/Resources"
    LogPath           = "$script:AutoLabRoot/Logs"
}
$script:TemplatePath = "$root/Templates"
$script:LabVMnet = 'vmnet2'
$script:LabVMnetSubnet = '192.168.3.0'
$script:LabVMnetMask = '255.255.255.0'
$script:LabVMnetHostIP = '192.168.3.1'
New-Item -ItemType Directory -Path $script:AutoLabFolders.Values -Force | Out-Null

# Dot-source the private helpers needed for this test
. "$root/Private/VMwareHelper.ps1"
. "$root/Private/MediaHelper.ps1"
. "$root/Private/ConfigHelper.ps1"
. "$root/Private/VMXHelper.ps1"
. "$root/Private/UnattendHelper.ps1"

$failures = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Host "PASS: $msg" }
    else { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:failures++ }
}

# --- Test every configuration parses through the adapter ---
foreach ($cfg in Get-ChildItem "$root/Configurations" -Directory) {
    $lab = Import-LabConfiguration -Path $cfg.FullName
    Assert ($lab.Nodes.Count -ge 1) "$($cfg.Name): $($lab.Nodes.Count) node(s) parsed"
    foreach ($n in $lab.Nodes) {
        Assert ($n.Computername -and $n.IPAddress -match '^\d+\.\d+\.\d+\.\d+$') "$($cfg.Name)/$($n.Computername): IP=$($n.IPAddress)"
        $media = Get-LabMediaInfo -Id $n.Media
        Assert (Test-Path "$root/Templates/$($media.Template)") "$($cfg.Name)/$($n.Computername): template $($media.Template) exists"
    }
}

# --- Deep test with MultiRole ---
$lab = Import-LabConfiguration -Path "$root/Configurations/MultiRole"
$dc = $lab.Nodes | Where-Object Computername -eq 'DC1'
Assert ($dc.IPAddress -eq '192.168.3.10') "MultiRole DC1 IP is 192.168.3.10 (got $($dc.IPAddress))"
Assert ($dc.Role -contains 'DC') "MultiRole DC1 has DC role"
Assert ($lab.Password -eq 'P@ssw0rd') "MultiRole lab password"

# VMX generation
$media = Get-LabMediaInfo -Id $dc.Media
$iso = Join-Path $script:AutoLabFolders.IsoPath $media.ISOName
$unattendIso = Join-Path $script:AutoLabFolders.UnattendIsoPath "$($dc.VMName)-unattend.iso"
$vmx = New-LabVMX -Node $dc -InstallISO $iso -UnattendISO $unattendIso
$vmxContent = Get-Content $vmx -Raw
Assert ($vmxContent -match 'firmware = "efi"') 'VMX uses EFI firmware'
Assert ($vmxContent -match 'uefi\.secureBoot\.enabled = "FALSE"') 'VMX disables Secure Boot'
Assert ($vmxContent -match 'virtualHW\.version = "21"') 'VMX hardware version 21'
Assert ($vmxContent -match 'ethernet0\.vnet = "vmnet2"') 'VMX NIC on vmnet2'
Assert ($vmxContent -match 'guestOS = "windows2019srv-64"') "VMX guestOS mapped (2019 Core)"
Assert ($vmxContent -match [regex]::Escape('bios.bootOrder = "cdrom,hdd"')) 'VMX initial boot order cdrom,hdd'

# Boot order flip after install
Set-LabVMXBootOrder -VMXPath $vmx -DisconnectISO
$vmxContent2 = Get-Content $vmx -Raw
Assert ($vmxContent2 -match [regex]::Escape('bios.bootOrder = "hdd,cdrom"')) 'VMX boot order flipped to hdd,cdrom'
Assert ($vmxContent2 -match 'sata0:0\.startConnected = "FALSE"') 'Install ISO disconnected'

# Unattend XML generation
$xmlPath = New-LabUnattendXml -Node $dc -Password $lab.Password -OutputPath /tmp/autolab-smoke/autounattend-dc1.xml
$xml = Get-Content -Path '/tmp/autolab-smoke/autounattend-dc1.xml' -Raw
Assert ($xml -notmatch '\{\{[A-Z]+\}\}') 'All tokens replaced in autounattend.xml'
Assert ($xml -match '<ComputerName>DC1</ComputerName>') 'ComputerName token'
Assert ($xml -match '192\.168\.3\.10/24') 'Static IP with prefix'
try { [xml]$xml | Out-Null; Assert $true 'Generated autounattend.xml is well-formed XML' }
catch { Assert $false "Generated autounattend.xml is well-formed XML: $_" }

# Windows 11 template path
$lab11 = Import-LabConfiguration -Path "$root/Configurations/Windows11"
$n11 = $lab11.Nodes[0]
$null = New-LabUnattendXml -Node $n11 -Password $lab11.Password -OutputPath /tmp/autolab-smoke/autounattend-win11.xml
$xml11 = Get-Content -Path '/tmp/autolab-smoke/autounattend-win11.xml' -Raw
Assert ($xml11 -match 'BypassTPMCheck') 'Windows 11 template includes TPM bypass'

# Bootstrap script generation
$bootstrap = New-LabBootstrapScript -Node $dc
Assert ($bootstrap -match 'Enable-PSRemoting') 'Bootstrap enables PSRemoting'
Assert ($bootstrap -match 'LocalAccountTokenFilterPolicy') 'Bootstrap sets token filter policy'

Write-Host "`n$failures failure(s)."
if ($failures -gt 0) { exit 1 } else { exit 0 }
