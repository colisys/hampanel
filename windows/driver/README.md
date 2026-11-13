# Windows Driver Companion

Hampanel on Windows is split into two components:

1. **`hampaneld.exe`** — user-mode service that owns the mTLS listener, the API,
   file/terminal/service management, and the enrollment bundle.
2. **`hampanel.sys`** — an optional kernel-mode companion driver.

## Why the API stays in user mode

TLS termination, HTTP parsing, filesystem access and process creation belong in
user mode. Hosting them inside a kernel driver would require re-implementing
large parts of the networking stack and would expose the kernel to memory-safety
bugs. The driver therefore provides a small, auditable kernel presence:

- control device `\Device\Hampanel` (`\\.\Hampanel`)
- `IOCTL_HAMPANEL_PING` — liveness
- `IOCTL_HAMPANEL_GET_VERSION` — driver/protocol version

Future revisions can add tamper-detection and integrity hooks through the same
control device without moving the management API into the kernel.

## Build requirements

- Windows 10/11 or Windows Server 2019+
- Visual Studio 2022 with the "Desktop development with C++" workload
- Windows Driver Kit (WDK) 10.0.22621 or newer
- Administrator PowerShell

## Build

```powershell
cd windows\driver
.\build.ps1
```

The script invokes MSBuild on `hampanel_driver.vcxproj` and copies the signed
output to `out\`.

## Test signing (development only)

```powershell
bcdedit /set testsigning on
# reboot, then, in an elevated prompt:
sc.exe create HampanelDriver type= kernel start= demand binPath= "C:\Program Files\Hampanel\hampanel.sys"
sc.exe start HampanelDriver
```

Production deployment requires an EV certificate or Microsoft attestation
signing; unsigned drivers do not load on stock Windows.

## Uninstall

```powershell
sc.exe stop HampanelDriver
sc.exe delete HampanelDriver
```

See `deploy\windows\install.ps1` for the complete service + driver installer.
