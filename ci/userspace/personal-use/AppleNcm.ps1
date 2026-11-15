#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Preflight','Install','Run','Rollback','Diagnostics')][string]$Action = 'Preflight')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Package = $PSScriptRoot
$StateRoot = Join-Path $env:ProgramData 'AppleNCM-Usermode'
$StateFile = Join-Path $StateRoot 'state.json'
$Hardware = 'USB\VID_05AC&PID_1905'
$Probe = Join-Path $Package 'assets\probe\ncm_probe.exe'
$Devcon = Join-Path $Package 'assets\tap\devcon.exe'
$WinInf = Join-Path $Package 'assets\winusb\AppleMacUsbNcm-WinUSB-Interfaces.inf'
$TapInf = Join-Path $Package 'assets\tap\OemVista.inf'
$script:State = $null
function Require-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the matching .cmd launcher and approve its Windows administrator prompt.'
    }
}
function Native([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -notin @(0,3010)) { throw "$Program failed (exit $LASTEXITCODE). See the transcript. No next step was attempted." }
}
function Devcon([string[]]$Arguments) {
    & $Devcon @Arguments | Out-Host
    # DevCon 1 means success requiring a reboot, not an ordinary completed install.
    if ($LASTEXITCODE -eq 1) { throw 'Windows requires a reboot. Reboot, reconnect both cable ends, then run Install.cmd again (or Rollback.cmd).' }
    if ($LASTEXITCODE -ne 0) { throw "DevCon failed (exit $LASTEXITCODE). Changes and backup remain recorded for Rollback.cmd." }
}
function Property([string]$Id, [string]$Key) {
    $p = Get-PnpDeviceProperty -InstanceId $Id -KeyName $Key -ErrorAction SilentlyContinue
    if ($null -ne $p) { return $p.Data }
    return $null
}
function Apple-Devices {
    @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "$Hardware\*" -or $_.InstanceId -like "$Hardware&MI_*" })
}
function Parent-Device {
    $parents = @(Apple-Devices | Where-Object { $_.InstanceId -like "$Hardware\*" })
    if ($parents.Count -ne 1) { throw 'Connect exactly one 05AC:1905 Mac. If missing, disconnect BOTH cable ends for 10-20 seconds and reconnect. No device migration was attempted.' }
    return $parents[0]
}
function Save-State {
    $script:State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}
function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { throw "No migration record at $StateFile. Run Install.cmd first." }
    $script:State = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if ($State.Version -ne 1) { throw 'Unsupported migration record. Keep the backup and request assistance.' }
}
function Assert-Assets {
    $path = Join-Path $Package 'artifact-manifest.json'
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1 -or $manifest.KernelPolicyVerified -ne $true) { throw 'The artifact manifest does not record the required kernel-policy signature check.' }
    $required = @('assets/probe/ncm_probe.exe','assets/winusb/AppleMacUsbNcm-WinUSB-Interfaces.inf','assets/winusb/AppleMacUsbNcm-WinUSB-Interfaces.cat','assets/winusb/AppleNcmWinUsb.cer','assets/tap/OemVista.inf','assets/tap/tap0901.sys','assets/tap/tap0901.cat','assets/tap/devcon.exe')
    foreach ($relative in $required) {
        $entry = @($manifest.Files | Where-Object { $_.Path -eq $relative })
        if ($entry.Count -ne 1 -or $entry[0].SHA256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Missing or ambiguous manifest entry: $relative" }
        $actual = (Get-FileHash -LiteralPath (Join-Path $Package $relative) -Algorithm SHA256).Hash
        if ($actual -ne $entry[0].SHA256) { throw "Artifact hash mismatch: $relative. Extract a fresh complete ZIP." }
    }
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $Package 'assets\winusb\AppleNcmWinUsb.cer'))
    if ($cert.Thumbprint -ne $manifest.WinUsbCertificateThumbprint -or $cert.Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'WinUSB certificate does not match this build manifest.' }
    $cat = Get-AuthenticodeSignature -LiteralPath (Join-Path $Package 'assets\winusb\AppleMacUsbNcm-WinUSB-Interfaces.cat')
    if ($null -eq $cat.SignerCertificate -or $cat.SignerCertificate.Thumbprint -ne $cert.Thumbprint) { throw 'WinUSB catalog signer does not match this build certificate.' }
    foreach ($file in @('assets\tap\tap0901.cat','assets\tap\devcon.exe')) {
        $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $Package $file)
        if ($sig.Status -ne 'Valid') { throw "Signature verification failed: $file ($($sig.Status))." }
    }
    return $manifest
}
function Adapter-ByGuid([string]$Guid) {
    $items = @(Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -eq $Guid })
    if ($items.Count -ne 1) { throw "Recorded TAP adapter $Guid is unavailable; do not substitute an existing VPN adapter." }
    return $items[0]
}
function Require-WinUsb {
    $parent = Parent-Device
    if ($parent.InstanceId -ne $State.ParentId) { throw 'A different Mac is connected. Connect the recorded device before continuing.' }
    if ((Property $parent.InstanceId 'DEVPKEY_Device_Service') -ne 'usbccgp') { throw 'Composite parent is not using Microsoft usbccgp. Run Install.cmd or Rollback.cmd.' }
    foreach ($mi in @('00','01')) {
        $child = @(Apple-Devices | Where-Object { $_.InstanceId -like "$Hardware&MI_$mi\*" })
        if ($child.Count -ne 1) { throw "Expected one MI_$mi interface; reconnect both cable ends and retry." }
        if ((Property $child[0].InstanceId 'DEVPKEY_Device_Service') -ne 'WinUSB' -or $child[0].Status -ne 'OK') { throw "MI_$mi has not started with WinUSB. Run Diagnostics.cmd." }
    }
    foreach ($name in @('WinUSB','usbccgp')) {
        $path = Join-Path $env:SystemRoot "System32\drivers\$name.sys"
        $sig = Get-AuthenticodeSignature -LiteralPath $path
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { throw "Cannot verify Microsoft stock $name.sys." }
    }
}
function Show-State {
    Write-Host 'Apple NCM personal user-mode prototype. This check does not modify drivers or IP settings.'
    Write-Host 'Boot configuration (testsigning Yes means normal-boot acceptance is still outstanding):'
    & bcdedit.exe /enum '{current}' | Out-Host
    Apple-Devices | Format-Table Status,Class,FriendlyName,InstanceId -AutoSize | Out-Host
    foreach ($d in @(Apple-Devices)) {
        [pscustomobject]@{Id=$d.InstanceId;Service=(Property $d.InstanceId 'DEVPKEY_Device_Service');Inf=(Property $d.InstanceId 'DEVPKEY_Device_DriverInfPath');Problem=(Property $d.InstanceId 'DEVPKEY_Device_ProblemCode')} | Format-List | Out-Host
    }
    Get-NetAdapter -IncludeHidden | Format-Table ifIndex,Name,InterfaceDescription,Status,InterfaceGuid -AutoSize | Out-Host
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -like '10.0.0.*' | Format-Table InterfaceAlias,IPAddress,PrefixLength,AddressState | Out-Host
    if (Test-Path -LiteralPath $StateFile) { Write-Host "Migration record: $StateFile" }
}
function Install-Bridge {
    Require-Admin
    $manifest = Assert-Assets
    $existingTap = Join-Path $env:SystemRoot 'System32\drivers\tap0901.sys'
    if ((Test-Path -LiteralPath $existingTap) -and ((Get-FileHash -LiteralPath $existingTap).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Package 'assets\tap\tap0901.sys')).Hash)) { throw 'An existing TAP driver differs from the packaged version. Refusing to update a shared VPN kernel service. Keep the working VPN installation; request a matching package.' }
    $parent = Parent-Device
    if (Test-Path -LiteralPath $StateFile) {
        Load-State
        if ($State.CertificateThumbprint -ne $manifest.WinUsbCertificateThumbprint -or $State.SourceCommit -ne $manifest.SourceCommit) { throw 'This ZIP differs from the saved migration. Use the original package for resume/rollback.' }
        if ($State.Phase -eq 'RolledBack') { throw "Previous migration was rolled back. Archive $StateRoot before a new migration so its original backup is preserved." }
        if ($State.Phase -eq 'CreatingTap') { throw 'Prior TAP creation has no complete identity record. Run Diagnostics.cmd; do not repeat adapter creation or remove existing VPN adapters.' }
        if ($State.ParentId -ne $parent.InstanceId) { throw 'Backup belongs to a different Mac. No changes made.' }
    } else {
        $service = Property $parent.InstanceId 'DEVPKEY_Device_Service'
        if ($service -notin @('UsbNcm','usbccgp')) { throw "Unexpected parent service '$service'. No changes made." }
        New-Item -ItemType Directory -Path (Join-Path $StateRoot 'driver-backup') -Force | Out-Null
        Get-NetIPConfiguration -All | Export-Clixml -LiteralPath (Join-Path $StateRoot 'original-network.xml')
        $devices = @()
        foreach ($d in @(Apple-Devices)) {
            $inf = [string](Property $d.InstanceId 'DEVPKEY_Device_DriverInfPath')
            $devices += [pscustomobject]@{Id=$d.InstanceId;Inf=$inf;InfSHA256=$(if (Test-Path (Join-Path $env:SystemRoot "INF\$inf")) { (Get-FileHash -LiteralPath (Join-Path $env:SystemRoot "INF\$inf")).Hash } else { '' });Service=(Property $d.InstanceId 'DEVPKEY_Device_Service');HardwareId=@(Property $d.InstanceId 'DEVPKEY_Device_HardwareIds')[0]}
            if ($inf -match '^oem\d+\.inf$') { Native 'pnputil.exe' @('/export-driver',$inf,(Join-Path $StateRoot 'driver-backup')) }
        }
        $oldAdapters = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PNPDeviceID -eq $parent.InstanceId })
        $ip = @()
        foreach ($adapter in $oldAdapters) {
            foreach ($addr in @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Manual' })) {
                $persistent = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $addr.IPAddress).Count -gt 0
                $ip += [pscustomobject]@{DeviceId=$adapter.PNPDeviceID;IPAddress=$addr.IPAddress;PrefixLength=$addr.PrefixLength;Persistent=$persistent}
            }
        }
        $script:State = [pscustomobject]@{Version=1;CertificateThumbprint=$manifest.WinUsbCertificateThumbprint;Created=(Get-Date).ToString('o');ParentId=$parent.InstanceId;Devices=$devices;OriginalIP=$ip;TapGuid='';TapDeviceId='';AddedCertificates=@();Phase='BackedUp';SourceCommit=$manifest.SourceCommit}
        Save-State
    }
    foreach ($store in @('Root','TrustedPublisher')) {
        $thumb = $manifest.WinUsbCertificateThumbprint
        if (-not (Test-Path "Cert:\LocalMachine\$store\$thumb")) {
            # Record intention before mutation; rollback only removes this exact build certificate.
            $State.AddedCertificates = @($State.AddedCertificates) + @($store)
            Save-State
            Import-Certificate -FilePath (Join-Path $Package 'assets\winusb\AppleNcmWinUsb.cer') -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
        }
    }
    $cat = Get-AuthenticodeSignature -LiteralPath (Join-Path $Package 'assets\winusb\AppleMacUsbNcm-WinUSB-Interfaces.cat')
    if ($cat.Status -ne 'Valid') { throw "Trusted WinUSB catalog verification failed: $($cat.Status)." }
    Native 'pnputil.exe' @('/add-driver',$WinInf)
    if ($State.Phase -notin @('CreatingTap','Ready')) { $State.Phase = 'Staged'; Save-State }
    if ((Property $parent.InstanceId 'DEVPKEY_Device_Service') -ne 'usbccgp') {
        # Update only the sole connected target HWID. usb.inf must offer a compatible composite driver.
        $target = [string](@(Property $parent.InstanceId 'DEVPKEY_Device_HardwareIds')[0])
        if ($target -notlike "$Hardware*") { throw 'Unexpected parent hardware ID.' }
        try { Devcon @('update',(Join-Path $env:SystemRoot 'INF\usb.inf'),$target) } catch { throw ('Composite migration stopped: ' + $_.Exception.Message + ' If no reboot is requested, in Device Manager select ONLY this Apple 05AC:1905 device: Update driver > Browse my computer > Let me pick > USB Composite Device (Microsoft). Reconnect both cable ends, then rerun Install.cmd. If unavailable, keep the backup and collect diagnostics.') }
        Start-Sleep -Seconds 2
        if ((Property $parent.InstanceId 'DEVPKEY_Device_Service') -ne 'usbccgp') {
            throw 'Automatic composite selection did not succeed. Keep the backup. In Device Manager select only this Apple device: Update driver > Browse > Let me pick > USB Composite Device (Microsoft). Reconnect, then rerun Install.cmd. Do not choose a different device.'
        }
    }
    $State.Phase = 'Composite'; Save-State
    foreach ($mi in @('00','01')) {
        $children = @(Apple-Devices | Where-Object { $_.InstanceId -like "$Hardware&MI_$mi\*" })
        if ($children.Count -ne 1) { throw "Missing MI_$mi. Disconnect BOTH ends for 10-20 seconds, reconnect, then rerun Install.cmd." }
        Devcon @('update',$WinInf,"$Hardware&MI_$mi")
    }
    Require-WinUsb
    $State.Phase = 'WinUSB'; Save-State
    if (-not $State.TapGuid) {
        if ($State.Phase -eq 'CreatingTap') { throw 'An earlier TAP creation did not complete its identity record. Do not create another adapter. Run Diagnostics.cmd and inspect the recorded root tap0901 device first.' }
        $before = @(Get-NetAdapter -IncludeHidden | ForEach-Object { [string]$_.InterfaceGuid })
        $State.Phase = 'CreatingTap'; Save-State
        Devcon @('install',$TapInf,'tap0901')
        Start-Sleep -Seconds 2
        $new = @(Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -notin $before -and $_.InterfaceDescription -match 'TAP-Windows' })
        if ($new.Count -ne 1) { throw 'Could not identify exactly one newly created TAP adapter. Do not repeat installation; inspect Diagnostics.cmd and remove only the new tap0901 root device with assistance.' }
        $State.TapGuid = [string]$new[0].InterfaceGuid
        $State.TapDeviceId = [string]$new[0].PnPDeviceID
        Save-State
    }
    $tap = Adapter-ByGuid $State.TapGuid
    if ($tap.PnPDeviceID -ne $State.TapDeviceId -or $tap.InterfaceDescription -notmatch 'TAP-Windows') { throw 'Recorded TAP identity changed.' }
    # Only the backed-up parent adapter can lose the prior address. Never modify another 10.0.0.2 adapter.
    $conflicts = @(Get-NetIPAddress -IPAddress '10.0.0.2' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object InterfaceIndex -ne $tap.ifIndex)
    foreach ($addr in $conflicts) {
        $a = Get-CimInstance Win32_NetworkAdapter | Where-Object InterfaceIndex -eq $addr.InterfaceIndex
        if ($null -eq $a -or $a.PNPDeviceID -ne $State.ParentId) { throw '10.0.0.2 is assigned to an unrelated adapter. No address was removed. Resolve this conflict before retrying.' }
        foreach ($store in @('PersistentStore','ActiveStore')) { Get-NetIPAddress -InterfaceIndex $addr.InterfaceIndex -IPAddress '10.0.0.2' -PolicyStore $store -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }
    }
    Set-NetIPInterface -InterfaceIndex $tap.ifIndex -AddressFamily IPv4 -Dhcp Disabled
    $address = @(Get-NetIPAddress -InterfaceIndex $tap.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '10.0.0.2' -and $_.PrefixLength -eq 24 })
    if ($address.Count -eq 0) { New-NetIPAddress -InterfaceIndex $tap.ifIndex -IPAddress '10.0.0.2' -PrefixLength 24 | Out-Null }
    $State.Phase = 'Ready'; Save-State
    Write-Host 'Installed. Mac must retain 10.0.0.1/24, Internet Sharing OFF. Run Start-Bridge.cmd and keep its window open. No boot security setting was changed.'
    Write-Host 'Normal-boot compatibility remains UNPROVEN until tested with testsigning OFF. This installer does not change boot settings.'
}
function Run-Bridge {
    Require-Admin
    $manifest = Assert-Assets
    Load-State
    if ($State.CertificateThumbprint -ne $manifest.WinUsbCertificateThumbprint -or $State.SourceCommit -ne $manifest.SourceCommit) { throw 'Use the same build ZIP that created this migration.' }
    if ($State.Phase -ne 'Ready') { throw "Migration phase is $($State.Phase). Complete Install.cmd first." }
    Require-WinUsb
    $tap = Adapter-ByGuid $State.TapGuid
    if ($tap.PnPDeviceID -ne $State.TapDeviceId) { throw 'TAP device identity differs from the saved migration record.' }
    $ip = @(Get-NetIPAddress -InterfaceIndex $tap.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '10.0.0.2' -and $_.PrefixLength -eq 24 })
    if ($ip.Count -eq 0) { throw 'Dedicated TAP address is missing. Run Install.cmd to restore it.' }
    Write-Host 'Keep this window open; Ctrl+C stops the bridge. Test from another window: ping -S 10.0.0.2 10.0.0.1'
    Native $Probe @('--bridge','--tap-guid',$State.TapGuid)
}
function Rollback-Bridge {
    Require-Admin
    $manifest = Assert-Assets
    Load-State
    if ($State.CertificateThumbprint -ne $manifest.WinUsbCertificateThumbprint -or $State.SourceCommit -ne $manifest.SourceCommit) { throw 'Use the same build ZIP that created this migration.' }
    if ($State.Phase -eq 'CreatingTap' -and -not $State.TapGuid) { Write-Warning 'An interrupted TAP creation has no recorded identity. Rollback restores the old binding/IP but leaves any unrecorded TAP untouched; inspect Diagnostics.cmd with assistance afterward.' }
    $parent = Parent-Device
    if ($parent.InstanceId -ne $State.ParentId) { throw 'Connect the same recorded Mac for rollback.' }
    if (@(Get-Process ncm_probe -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Close the bridge window with Ctrl+C, then retry rollback.' }
    foreach ($device in @($State.Devices)) {
        if ($device.Inf -match '^oem\d+\.inf$') {
            # Match the hash captured before migration, independent of later OEM numbering.
            $saved = @(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'driver-backup') -Filter '*.inf' -Recurse | Where-Object { (Get-FileHash -LiteralPath $_.FullName).Hash -eq $device.InfSHA256 })
            if ($saved.Count -lt 1) { throw "Cannot resolve exported $($device.Inf). Keep all backup files; no substitute driver was selected." }
            $restoreInf = $saved[0].FullName
            Native 'pnputil.exe' @('/add-driver',$restoreInf)
        } elseif ($device.Inf -match '^[a-zA-Z0-9_-]+\.inf$') {
            $restoreInf = Join-Path $env:SystemRoot "INF\$($device.Inf)"
            if ((Get-FileHash -LiteralPath $restoreInf).Hash -ne $device.InfSHA256) { throw 'An original inbox INF changed. Request assistance rather than substituting a driver.' }
        } else { continue }
        Devcon @('update',$restoreInf,[string]$device.HardwareId)
    }
    if ($State.TapDeviceId) {
        $tap = Adapter-ByGuid $State.TapGuid
        if ($tap.PnPDeviceID -ne $State.TapDeviceId) { throw 'TAP identity differs. Refusing adapter removal.' }
        Devcon @('remove',('@' + $State.TapDeviceId))
        $State.TapGuid = ''; $State.TapDeviceId = ''; Save-State
    }
    Start-Sleep -Seconds 2
    foreach ($item in @($State.OriginalIP)) {
        $a = @(Get-CimInstance Win32_NetworkAdapter | Where-Object PNPDeviceID -eq $item.DeviceId)
        if ($a.Count -ne 1) { throw 'Old adapter has not returned. Reconnect/reboot into the prior working environment and rerun Rollback.cmd. Original IP remains saved.' }
        $exists = @(Get-NetIPAddress -InterfaceIndex $a[0].InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $item.IPAddress)
        if ($exists.Count -eq 0) {
            if ($item.Persistent) {
                New-NetIPAddress -InterfaceIndex $a[0].InterfaceIndex -IPAddress $item.IPAddress -PrefixLength $item.PrefixLength | Out-Null
            } else {
                New-NetIPAddress -InterfaceIndex $a[0].InterfaceIndex -IPAddress $item.IPAddress -PrefixLength $item.PrefixLength -PolicyStore ActiveStore | Out-Null
            }
        }
    }
    $manifest = Assert-Assets
    foreach ($store in @($State.AddedCertificates | Select-Object -Unique)) {
        Remove-Item -LiteralPath "Cert:\LocalMachine\$store\$($manifest.WinUsbCertificateThumbprint)" -ErrorAction SilentlyContinue
    }
    $State.Phase = 'RolledBack'; Save-State
    Write-Host 'Recorded original binding/IP restored; dedicated TAP removed. Backup retained. Driver-store packages retained to avoid affecting other devices. The old test-signed driver still requires its original working boot configuration; no boot setting was changed.'
}
try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1 on Windows x64.' }
    if ($Action -in @('Preflight','Diagnostics')) {
        Show-State
        $null = Assert-Assets
        Write-Host 'Artifact hashes and packaged signatures checked. No hardware functionality has been proven.'
        if ($Action -eq 'Diagnostics') {
            Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational';StartTime=(Get-Date).AddHours(-2)} -ErrorAction SilentlyContinue | Where-Object Message -match 'WinUSB|tap0901|UsbNcm' | Select-Object -First 12 TimeCreated,Id,Message | Format-List | Out-Host
        }
    } else {
        Require-Admin
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
        Start-Transcript -Path (Join-Path $StateRoot ("{0}-{1}.log" -f $Action,(Get-Date -Format 'yyyyMMdd-HHmmss'))) | Out-Null
        switch ($Action) { 'Install' { Install-Bridge }; 'Run' { Run-Bridge }; 'Rollback' { Rollback-Bridge } }
        Stop-Transcript | Out-Null
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Keep the ZIP and $StateRoot backup. Run Diagnostics.cmd to collect current state."
    if ($Action -in @('Install','Run','Rollback')) { $null = Read-Host 'Press Enter to close this administrator window' }
    exit 1
}
if ($Action -in @('Install','Rollback')) { $null = Read-Host 'Press Enter to close this administrator window' }

