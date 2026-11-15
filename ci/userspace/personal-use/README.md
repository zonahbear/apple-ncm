# Apple NCM personal Windows prototype (05AC:1905)

This package runs NCM in a user-mode process. The Mac's composite parent uses Microsoft's `usbccgp`, MI_00/MI_01 use stock Microsoft WinUSB, and a dedicated OpenVPN TAP-Windows6 adapter carries Ethernet packets. It does not install the old custom `UsbNcmSample.sys` or change Windows boot/security settings.

**This is an experimental alternative to the working test-signed kernel driver. Normal-boot compatibility, throughput and reconnection on your hardware are not yet proven.** The upstream prototype reported ping on a different Apple product ID; a successful build is not a hardware test. Software such as anti-cheat can apply its own policies; no compatibility promise is made.

## Use

1. Extract the entire ZIP to a permanent local folder. Keep your existing working-driver ZIP. Leave Mac Internet Sharing OFF and retain its working `10.0.0.1/24` setup, no gateway. Connect just this Mac and PC with the known cable.
2. Double-click **Preflight.cmd**. It only reads device/network/boot state and verifies package files. No driver, IP, certificate, or boot change is made. The existing custom driver will not expose WinUSB interfaces yet; that is expected.
3. Close Deskflow/file transfers over this link. Double-click **Install.cmd**, approve UAC, and let it finish. This interrupts the USB network. It exports the actual old OEM driver package, records bindings and manual IPv4 settings, trusts this build's catalog certificate, stages the WinUSB INF, switches only Apple 05AC:1905 to the stock composite parent and first WinUSB pair, then creates a new dedicated TAP with `10.0.0.2/24` and no gateway. It does not modify your existing VPN adapters. A Windows driver publisher confirmation may still appear.
4. Double-click **Start-Bridge.cmd**, approve UAC, and **leave its administrator window open**. Ctrl+C stops the bridge. There is no background service or automatic startup. In another PowerShell window run:

   ```powershell
   ping -S 10.0.0.2 10.0.0.1
   ```

The remaining USB interface pair is left alone. No Internet Sharing, DHCP, gateway, DNS, bonding, firewall exception or bridge to your Wi-Fi is configured. The PowerShell `-ExecutionPolicy Bypass` argument applies only to these launcher processes; it does not change system policy or kernel signing enforcement.

If the parent cannot automatically select Microsoft's compatible USB Composite Device driver, setup stops and keeps the backup. In Device Manager, select **only** the recorded Apple 05AC:1905 device: Update driver > Browse my computer > Let me pick > USB Composite Device (Microsoft). Do not select another device. Disconnect **both cable ends** for 10–20 seconds, reconnect and run Install.cmd again. If that entry is unavailable, collect diagnostics rather than guessing another driver.

## Validate before relying on it

A trial while `testsigning Yes` still appears is not proof of normal-boot operation. This package never enables/disables test mode or any protection. Preserve the backup and establish the normal Windows boot configuration separately, then verify `bcdedit /enum "{current}"` does not show testsigning enabled and that WinUSB/TAP have no PnP errors. Run the bridge and ping again. Keep the old driver available; it may require its previous test-signing configuration to load on rollback.

With `iperf3 -s` already running on the Mac:

```powershell
iperf3 -c 10.0.0.1 -B 10.0.0.2 -t 30
iperf3 -c 10.0.0.1 -B 10.0.0.2 -t 30 -R
```

Then try a 15-minute mixed traffic session, unplug/replug with both ends fully disconnected, PC reboot, Mac reboot, and sleep/wake. Start the bridge again after a reboot. Recheck ping and inspect diagnostics after each. No throughput equivalence with the kernel driver is assumed. Only consider automatic startup after these checks succeed.

## Recover

Stop the bridge with Ctrl+C, connect the **same Mac**, then double-click **Rollback.cmd** and approve UAC. It reinstalls the recorded original driver from its exported package, removes only the TAP adapter identified in its saved record, restores the old manual IPv4 address and removes only certificate-store entries that this install added. It retains the backup and driver-store packages to avoid affecting other devices. It does not change boot configuration. If Windows requests a reboot or the old adapter is absent, follow the displayed instruction and rerun rollback after reconnecting/rebooting into the old working environment.

State, driver exports and mutation transcripts live at `%ProgramData%\AppleNCM-Usermode`. Keep this folder intact until rollback is no longer wanted. Rerunning Install resumes the saved migration; it refuses a different Mac or an already rolled-back record. If TAP creation was interrupted before a unique adapter was recorded, setup stops for inspection instead of creating duplicates or guessing an existing VPN adapter. Rollback can restore the old binding/IP but leaves an unrecorded TAP untouched for manual inspection. An existing TAP kernel binary that differs from the bundle also stops setup before migration, avoiding an update to a shared VPN driver service. Diagnostics.cmd prints current state without changing it; copy that output plus mutation logs when reporting trouble. Output can include device serials/IPs; review before sharing publicly.

## Signatures and provenance

The local public certificate only trusts the exact INF catalog bundled with this build; it is not a Microsoft kernel signing certificate. The INF references in-box WinUSB rather than shipping a custom kernel binary. TAP-Windows6 and DevCon must be the unmodified signed binaries supplied in this package. CI verifies TAP's catalog membership with `signtool verify /kp /c` and records that check in `artifact-manifest.json`. Setup verifies every required file's SHA-256, the catalog signer against the manifest's exact certificate thumbprint, and the packaged TAP catalog/DevCon signatures. Windows still enforces its own loading policies. Hashes detect mixed/corrupt downloads; an unsigned manifest does not authenticate an untrusted download source.

The source baseline is [HexBen123/apple-ncm-tap-windows](https://github.com/HexBen123/apple-ncm-tap-windows), commit `a3d6f3334aa7a772201177d00ebc127cd29f8f63`; adaptation commit and build provenance are in the manifest. Preserve bundled upstream notices. This is a personal experimental bundle, not a production driver release.

The parent update uses [DevCon Update](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/devcon-update), which targets a hardware ID and selects the most appropriate driver from the specified INF. The TAP creation intentionally uses [DevCon Install](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/devcon-install), which creates a root-enumerated device. These operations are not interchangeable.
