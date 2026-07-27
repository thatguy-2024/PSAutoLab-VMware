# PSAutoLabVMware

A PowerShell module for building Windows lab environments on **VMware Workstation Pro**, ported from the excellent [PS-AutoLab-Env](https://github.com/pluralsight/PS-AutoLab-Env) project (which targets Hyper-V + Lability).

PSAutoLabVMware keeps the same workflow, the same commands, and the **same, unmodified DSC configurations** as the original project — but provisions the virtual machines with VMware Workstation tooling (`vmrun`, `vmware-vdiskmanager`, `vnetlib64`) instead of Hyper-V/Lability.

> ⚠️ This module is a community port and is not affiliated with Pluralsight or the PS-AutoLab-Env maintainers.

---

## How it works

| Stage | Hyper-V original (Lability) | This module (VMware) |
|---|---|---|
| VM creation | Lability + Hyper-V cmdlets | Generated `.vmx` files (EFI firmware, Secure Boot off, hardware v21) |
| Disks | Differencing VHDX from a master image | Per-VM growable `.vmdk` created with `vmware-vdiskmanager` |
| OS install | Image injected into VHDX (fast) | Unattended install from the evaluation ISO + a generated `autounattend.xml` ISO attached as a second CD-ROM (~20-40 min on first boot) |
| Networking | Internal Hyper-V switch `LabNet` | Host-only network **vmnet2** (`192.168.3.0/24`, host = `192.168.3.1`) |
| Internet access | Hyper-V NAT | Windows **WinNAT** (`New-NetNat`) on the host |
| Guest management | PowerShell Direct | **WinRM** (PSRemoting) over the lab network |
| DSC | Lability injects MOFs | MOFs compiled locally from the original `VMConfiguration.ps1` and pushed over WinRM (`Start-DscConfiguration`) |
| Snapshots | Hyper-V checkpoints | VMware snapshots (`vmrun snapshot` / `revertToSnapshot`) |

The DSC configuration files (`VMConfiguration.ps1`) and data files (`VMConfigurationData.psd1`) in each configuration folder are the **original, unmodified** files from PS-AutoLab-Env. A compatibility layer inside the module translates the Lability-oriented settings (media IDs, switch names, memory/CPU, boot order…) into VMware equivalents.

## Requirements

* **Windows 10/11 host** (Pro or better recommended)
* **VMware Workstation Pro 17.x** (or later) installed to the default location
  * `vmrun.exe`, `vmware-vdiskmanager.exe` and `vnetlib64.exe` must be present (default install includes them)
* **Windows PowerShell 5.1** — run everything from an **elevated** Windows PowerShell console (not PowerShell 7)
* **Pester 5.5+** (installed automatically by `Setup-Host`)
* Hardware: **16 GB RAM minimum** (32 GB recommended for multi-VM labs), **100 GB+ free disk**, virtualization enabled in BIOS/UEFI
* Internet access to download evaluation ISOs and DSC resources on first use

Hyper-V is **not** required and should ideally be disabled (VMware and Hyper-V can conflict unless Workstation's Hyper-V compatibility mode is used).

## Installation

```powershell
# Clone or copy the module, then place it on your module path, e.g.:
Copy-Item -Path .\PSAutoLabVMware -Destination "$env:ProgramFiles\WindowsPowerShell\Modules\PSAutoLabVMware" -Recurse

# Verify
Import-Module PSAutoLabVMware
Get-Command -Module PSAutoLabVMware
```

## Quick start

```powershell
# 1. One-time host setup (elevated Windows PowerShell 5.1)
Setup-Host

# 2. Pick a configuration
cd C:\AutolabVMware\Configurations\SingleServer
Get-Content .\Instructions.md   # if present

# 3. Provision (creates VMX/VMDK/unattend ISO, compiles DSC MOFs)
Setup-Lab

# 4. Boot the VMs; Windows installs unattended, then DSC is pushed over WinRM
Run-Lab

# 5. (Optional) give the lab internet access via WinNAT
Enable-Internet

# 6. Validate — loops Pester tests until the lab converges
Validate-Lab

# ...or do 3-6 in one shot:
Unattend-Lab

# When you're done for the day
Shutdown-Lab

# Save / restore a known-good state
Snapshot-Lab
Refresh-Lab

# Tear everything down
Wipe-Lab
```

> **First boot is slow by design.** Unlike the Hyper-V original (which injects the OS into a differencing disk), each VMware VM performs a full unattended Windows installation on first boot. Expect 20–40 minutes per VM before WinRM comes up, then additional time for DSC to converge (domain controllers take the longest).

## Command reference

| Command (alias) | Function | Description |
|---|---|---|
| `Setup-Host` | `Invoke-SetupHost` | One-time host prep: verifies VMware Workstation, enables PSRemoting, sets TrustedHosts for `192.168.3.*`, installs Pester, creates `C:\AutolabVMware` folders, configures the **vmnet2** host-only network, copies configurations. |
| `Setup-Lab` | `Invoke-SetupLab` | Run from a configuration folder. Downloads the evaluation ISO(s), builds the `autounattend.xml` ISO, VMDK and VMX for every node, installs DSC resources and compiles the MOFs from the original `VMConfiguration.ps1`. Supports `-UseLocalTimeZone`, `-Force`. |
| `Run-Lab` | `Invoke-RunLab` | Powers on VMs in boot order. On first run, waits for the unattended install + WinRM, disconnects the install media, then pushes the DSC configuration to each VM. Supports `-SkipDSC`, `-TimeoutMinutes`. |
| `Enable-Internet` | `Enable-Internet` | Creates a WinNAT (`New-NetNat`) on the host so lab VMs (gateway `192.168.3.1`) can reach the internet. |
| `Validate-Lab` | `Invoke-ValidateLab` | Repeatedly runs the folder's `VMValidate.test.ps1` Pester tests (over WinRM) until everything passes or 65 minutes elapse. |
| `Shutdown-Lab` | `Invoke-ShutdownLab` | Graceful guest shutdown in reverse boot order (hard stop as fallback). |
| `Snapshot-Lab` | `Invoke-SnapshotLab` | Shuts the lab down and takes a VMware snapshot of every VM (default name `LabConfigured`). |
| `Refresh-Lab` | `Invoke-RefreshLab` | Reverts every VM to a snapshot (default `LabConfigured`). VMs are left powered off. |
| `Wipe-Lab` | `Invoke-WipeLab` | Stops and deletes all lab VMs, unattend ISOs and MOFs. `-RemoveSwitch` also removes the WinNAT. Downloaded ISOs are kept. |
| `Get-LabStatus` | — | Per-VM state, snapshots and (with `-IncludeDSC`) live DSC status over WinRM. |
| `Get-LabSummary` | — | Summarizes the nodes defined in a configuration (name, IP, media, memory, CPU, roles). |
| `Run-Pester` | `Invoke-PesterTest` | Runs the configuration's validation tests once with full output. |
| `Test-LabDSCResource` | — | Shows the DSC resources required by a configuration and whether they are installed locally. |

Every function has full comment-based help: `Get-Help Setup-Lab -Full`.

## Included configurations

All 12 configurations from PS-AutoLab-Env are included, unchanged. Default password for every lab: `P@ssw0rd` (domain `Company.pri` where applicable).

| Configuration | VMs (IP = 192.168.3.x) | OS | Notes |
|---|---|---|---|
| `SingleServer` | S1 (.19) | Server 2019 Core | Simplest lab — start here |
| `SingleServer-2022` | SERVER1 (.22) | Server 2022 Core | 2 GB RAM |
| `SingleServer-GUI-2016` | S1 (.75) | Server 2016 GUI | 4 GB RAM |
| `SingleServer-GUI-2019` | S1 (.19) | Server 2019 GUI | 4 GB RAM, 2 vCPU |
| `Windows10` | Win10Ent (.101) | Windows 10 Ent | Standalone client |
| `Windows11` | Win11Lab (.111) | Windows 11 Ent | TPM/Secure Boot checks bypassed via autounattend |
| `MultiRole` | DC1 (.10), S1 (.50), Cli1 (.100) | Server 2019 Core + Win10 | Domain: DC, member server, client |
| `MultiRole-GUI` | DC1 (.10), S1 (.50), Cli1 (.100) | Server 2019 GUI + Win10 | GUI variant of MultiRole |
| `MultiRole-Server-2016` | DC1 (.10), S1 (.50), Cli1 (.100) | Server 2016 Core + Win10 | 2016 variant |
| `PowerShellLab` | DOM1 (.10), SRV1 (.50), SRV2 (.51), SRV3 (.60), WIN10 (.100) | 2019 Core / 2022 Core / Win10 | The big one — DC, members, web server, client with RSAT |
| `Implement-Windows-Server-DHCP-2016` | DC1 (.10), S1 (.50), Cli1 (.100), Cli2 (.101) | Server 2016 Core + Win10 | DHCP course lab |
| `microsoft-powershell-implementing-jea` | DC1 (.10), S1 (.50), Cli1 (.100) | Server 2016 Core + Win10 | JEA course lab (DC/DHCP/ADCS) |

Each folder contains the original `VMConfiguration.ps1` / `VMConfigurationData.psd1`, a VMware-aware `VMValidate.test.ps1` (WinRM-based), and the original Hyper-V test preserved as `VMValidate.test.ps1.hyperv` for reference.

## Networking

* `Setup-Host` configures **vmnet2** as a host-only network: subnet `192.168.3.0/24`, no VMware DHCP, host adapter (`VMware Network Adapter VMnet2`) = `192.168.3.1`.
* Every lab VM gets a **static IP** via `autounattend.xml`, exactly matching the addresses in `VMConfigurationData.psd1`, with gateway/DNS pointing into the lab.
* `Enable-Internet` creates a **WinNAT** (`New-NetNat -InternalIPInterfaceAddressPrefix 192.168.3.0/24`) so VMs can reach the internet through the host. Remove it with `Wipe-Lab -RemoveSwitch` or `Remove-NetNat`.
* WinRM: `Setup-Host` adds `192.168.3.*` to the host's TrustedHosts so credentials can be sent to the workgroup/domain VMs by IP.

If the automated vmnet configuration fails (vnetlib quirks vary between Workstation builds), open **Edit ▸ Virtual Network Editor** in VMware Workstation and create/verify **VMnet2**: *Host-only*, subnet `192.168.3.0`, mask `255.255.255.0`, DHCP **disabled**, "Connect a host virtual adapter" **enabled**; then set the host adapter to `192.168.3.1`.

## ISOs and media

`Setup-Lab` downloads Microsoft **evaluation** ISOs to `C:\AutolabVMware\ISOs` on first use. Microsoft occasionally retires Eval Center links; if a download fails:

1. Download the evaluation ISO manually from the [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter/).
2. Save it to `C:\AutolabVMware\ISOs` using the exact filename shown in the error message (e.g. `WindowsServer2022Eval.iso`).
3. Re-run `Setup-Lab`.

Evaluation media run for 180 days (servers) / 90 days (clients) — plenty for lab work.

`Setup-Lab` also rebuilds each install ISO once into a `*_noprompt.iso` (using `efisys_noprompt.bin` from the ISO itself). This removes the UEFI **"Press any key to boot from CD or DVD"** prompt so the unattended install starts hands-free. The rebuild takes a few minutes and needs roughly the size of the ISO in extra disk space; the VMs are attached to the `_noprompt` copy. If the rebuild fails, the original ISO is used and you must click into the VM console and press a key at the boot prompt right after `Run-Lab`.

## Folder layout

```
C:\AutolabVMware\
├── Configurations\    # lab configuration folders (work from here)
├── VMs\               # one folder per VM: .vmx, .vmdk, DSC marker
├── ISOs\              # downloaded evaluation ISOs
├── UnattendISOs\      # generated per-VM autounattend ISOs
├── Resources\         # downloaded DSC resource modules
└── Logs\
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `vmrun.exe not found` | Install VMware Workstation Pro; if installed to a custom path, add its folder to `PATH`. |
| ISO download fails | Download manually from the Eval Center to `C:\AutolabVMware\ISOs` with the expected filename (see error message). |
| VM boots to Windows Setup GUI instead of installing | The unattend ISO isn't attached or the template tokens weren't replaced — re-run `Setup-Lab -Force` and check `C:\AutolabVMware\UnattendISOs`. |
| Windows 11 refuses to install | The template already bypasses TPM/Secure Boot/RAM/CPU checks. Ensure you're using the generated VMX (EFI firmware). |
| `Run-Lab` times out waiting for VMs | First install can take 40+ minutes. Watch the VM console in Workstation; re-run `Run-Lab` when the VM shows a logon screen — it will resume where it left off. |
| WinRM/credential errors | Confirm host TrustedHosts includes `192.168.3.*` (`Get-Item WSMan:\localhost\Client\TrustedHosts`), that the host vmnet2 adapter is `192.168.3.1`, and that its network profile is Private. |
| No internet in VMs | Run `Enable-Internet` (elevated). Check `Get-NetNat`. Only one WinNAT can exist per host — remove conflicting NATs. |
| DSC never converges | `Get-LabStatus -IncludeDSC` shows live LCM state. DCs need a reboot cycle; `Validate-Lab` handles the wait/retry loop. |
| Hyper-V conflicts | Disable Hyper-V/WSL2/Memory Integrity, or enable Workstation's ULM/Hyper-V mode (slower). |

## Differences from PS-AutoLab-Env

* **No PowerShell Direct** — all guest communication is WinRM over the lab network; validation tests were rewritten accordingly.
* **No differencing disks** — every VM performs a full unattended install on first boot (slower first `Run-Lab`, but no master-image maintenance).
* **Secure Boot is disabled** in the generated VMX files (EFI is used, but eval + DSC labs don't need Secure Boot and Windows 11 checks are bypassed).
* **`Update-Lab` is not ported** — run Windows Update inside the VMs, or rebuild with fresh media.
* Snapshots use VMware snapshots instead of Hyper-V checkpoints.
* Everything lives under `C:\AutolabVMware` instead of `C:\Autolab`.

## Credits

* [PS-AutoLab-Env](https://github.com/pluralsight/PS-AutoLab-Env) — original project, configurations and DSC designs (MIT license).
* This port: PSAutoLabVMware contributors.
