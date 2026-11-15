$ErrorActionPreference = 'Stop'
$root = $env:GITHUB_WORKSPACE
$out = Join-Path $root 'package'
$verify = Join-Path $root 'verification'
New-Item -ItemType Directory -Force $out,$verify | Out-Null
$bundle = Join-Path $out 'Apple-NCM-Usermode-Windows'
Copy-Item -Recurse (Join-Path $root 'automation/ci/userspace/personal-use') $bundle
foreach ($dir in @('assets/probe','assets/winusb','assets/tap')) {
    New-Item -ItemType Directory -Force (Join-Path $bundle $dir) | Out-Null
}
Copy-Item "$root/bridge/usermode-probe/out/x64/ncm_probe.exe" "$bundle/assets/probe/"
Copy-Item "$root/bridge/package-interfaces/AppleMacUsbNcm-WinUSB-Interfaces.inf" "$bundle/assets/winusb/"
function Download-Verified([string]$Url,[string]$Path,[string]$Hash) {
    Invoke-WebRequest -UseBasicParsing $Url -OutFile $Path
    if ((Get-FileHash $Path -Algorithm SHA256).Hash -ne $Hash) { throw "Download hash mismatch: $Url" }
}
$tapZip = Join-Path $root 'tap.zip'
Download-Verified 'https://github.com/OpenVPN/tap-windows6/releases/download/9.27.0/dist.win10.zip' $tapZip '36e2609b7ceefedcb978ce5c48caf9e0e5af83423717c4e2e3c1d7ebca8f62a5'
Expand-Archive $tapZip "$root/tap"
foreach ($file in @('OemVista.inf','tap0901.sys','tap0901.cat','devcon.exe')) {
    Copy-Item "$root/tap/dist.win10/amd64/$file" "$bundle/assets/tap/"
}
$wdkZip = Join-Path $root 'wdk.zip'
Download-Verified 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/10.0.26100.6584/microsoft.windows.wdk.x64.10.0.26100.6584.nupkg' $wdkZip 'c393d03dfb640b5c92f546b32f6770ef68cd3aaf691956e7d66d8e2c28a1b55e'
Expand-Archive $wdkZip "$root/wdk"
$inf2cat = "$root/wdk/c/bin/10.0.26100.0/x86/Inf2Cat.exe"
$signTool = Get-ChildItem "${env:ProgramFiles(x86)}/Windows Kits/10/bin/*/x64/signtool.exe" | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $signTool) { throw 'Windows SDK SignTool missing' }
& $signTool verify /kp /v /c "$bundle/assets/tap/tap0901.cat" "$bundle/assets/tap/tap0901.sys" 2>&1 | Tee-Object "$verify/tap-kernel-policy.txt"
if ($LASTEXITCODE) { throw 'Official TAP kernel policy signature verification failed' }
& $signTool verify /pa /v "$bundle/assets/tap/devcon.exe" 2>&1 | Tee-Object "$verify/devcon-signature.txt"
if ($LASTEXITCODE) { throw 'Official DevCon signature verification failed' }
& $inf2cat "/driver:$bundle/assets/winusb" /os:10_GE_X64 /uselocaltime 2>&1 | Tee-Object "$verify/inf2cat.txt"
if ($LASTEXITCODE) { throw 'WinUSB INF catalog creation failed' }
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Apple NCM Personal WinUSB Package' -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(2) -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256
$cer = "$bundle/assets/winusb/AppleNcmWinUsb.cer"
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
& $signTool sign /v /fd SHA256 /sm /s My /sha1 $cert.Thumbprint "$bundle/assets/winusb/AppleMacUsbNcm-WinUSB-Interfaces.cat" 2>&1 | Tee-Object "$verify/winusb-catalog-sign.txt"
if ($LASTEXITCODE) { throw 'WinUSB package catalog signing failed' }
& $signTool verify /pa /v /c "$bundle/assets/winusb/AppleMacUsbNcm-WinUSB-Interfaces.cat" "$bundle/assets/winusb/AppleMacUsbNcm-WinUSB-Interfaces.inf" 2>&1 | Tee-Object "$verify/winusb-catalog-verify.txt"
if ($LASTEXITCODE) { throw 'WinUSB INF catalog membership verification failed' }
# Every shipped PowerShell script must parse under Windows PowerShell 5.1.
foreach ($file in Get-ChildItem $bundle -Recurse -Filter *.ps1) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { $errors | Format-List | Out-String | Write-Host; throw "PowerShell parse failed: $($file.FullName)" }
}
$files = @(Get-ChildItem $bundle -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{ Path=$_.FullName.Substring($bundle.Length+1).Replace('\','/'); SHA256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash }
})
[ordered]@{
    SchemaVersion=1
    SourceCommit=$env:GITHUB_SHA
    BaseSourceCommit='a3d6f3334aa7a772201177d00ebc127cd29f8f63'
    WinUsbCertificateThumbprint=$cert.Thumbprint
    KernelPolicyVerified=$true
    Files=$files
} | ConvertTo-Json -Depth 8 | Set-Content "$bundle/artifact-manifest.json" -Encoding UTF8
@'
Experimental personal-use build based on:
https://github.com/HexBen123/apple-ncm-tap-windows
Base source commit: a3d6f3334aa7a772201177d00ebc127cd29f8f63
PID1905 modifications and build workflow: https://github.com/zonahbear/apple-ncm
TAP driver: unmodified OpenVPN tap-windows6 release9.27.0, official dist.win10.zip.
WinUSB and usbccgp: Microsoft inbox Windows drivers, not replaced by this package.
The locally issued certificate signs an INF-only catalog; it is not a Microsoft kernel signature.
No hardware validation or anti-cheat compatibility is asserted by the CI build.
The upstream user-mode prototype does not contain an explicit repository LICENSE.
Source and modification patch are included for provenance; no new license is asserted.
'@ | Set-Content "$bundle/UPSTREAM.txt" -Encoding UTF8
Copy-Item "$root/automation/ci/userspace/1905.patch" "$bundle/1905.patch"
Push-Location "$root/bridge"
git archive --format=zip --output="$bundle/upstream-source.zip" a3d6f3334aa7a772201177d00ebc127cd29f8f63
if ($LASTEXITCODE) { throw 'Source archive failed' }
Pop-Location
Get-ChildItem $bundle -File -Recurse | Sort-Object FullName | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash,$_.FullName.Substring($bundle.Length+1).Replace('\','/')
} | Set-Content "$bundle/SHA256SUMS.txt" -Encoding ASCII
Compress-Archive "$bundle/*" "$out/Apple-NCM-Usermode-Windows-x64.zip"
Remove-Item $bundle -Recurse -Force
