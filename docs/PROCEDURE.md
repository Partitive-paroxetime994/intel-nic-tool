# Dell/OEM → generic Intel X710 crossflash: procedure & rationale

This is the procedure `crossflash.sh` automates, why each step exists, and the
recovery story. Distilled from the community sources below plus testing on a
Dell-OEM X710-DA2.

## Sources

- mietzen, *How to crossflash intel X710 OEM cards* (the canonical guide):
  https://gist.github.com/mietzen/736583d37a1d370273c0775aaaa57aa5
- Level1Techs, *Crossflashing Intel official firmware on Dell/Lenovo X710-DA2
  (Solved)*:
  https://forum.level1techs.com/t/crossflashing-intel-official-firmware-on-dell-lenovo-pcie-x710-da2-nics-solved/196357
- Intel Ethernet NVM Update Tool — Quick Usage Guide (Linux):
  https://cdrdv2-public.intel.com/332161/

## Why OEM cards are locked

OEM-branded X710s carry vendor data in **VPD** (e.g. Dell shows `MN=1028`,
`PN=Y5M7N`) even when the PCI subsystem id looks generic. On that firmware:

- `bootutil -FD` (disable option-ROM) returns **"Unsupported feature"**, and
- stock `nvmupdate` reports `update="0"` and refuses the card.

So the option-ROM can't be disabled — which hangs UEFI-only boards that dispatch
it at POST and have no per-device option-ROM toggle. Crossflashing to generic
Intel firmware removes the lock.

## The procedure

1. **Identify the card and its etrack id.** `ethtool -i <iface>` →
   `firmware-version: 5.40 0x80002e8d ...` → etrack `80002E8D`.

2. **Confirm SPI flash size.** 700-series cards ship with 4 MB or 8 MB flash.
   **Using an image built for the wrong size is the #1 hard-brick cause.** A full
   NVM dump's byte size is the ground truth (8 MB = 8,388,608 bytes). The tool
   makes this a hard gate: it won't flash unless a backup of the matching size
   exists.

3. **Give bootutil device access (driverless).** `bootutil` normally reaches the
   card through Intel's `iqvlinux` QV kernel module, but that module is dead on
   modern kernels (~6.8 and up, incl. 7.x): it builds and registers `/dev/nal`
   yet its ioctl handshake fails. Use bootutil's **driverless** path instead,
   which maps device memory via `/dev/mem`. That needs `iomem=relaxed` on the
   kernel cmdline (relaxes strict MMIO) and Secure Boot **off** (lockdown blocks
   `/dev/mem`); the base `i40e` driver must stay **bound** (unbinding hides the
   card from bootutil). bootutil prints a `Connection to QV driver failed` notice
   in this mode — that's expected, and the operation still succeeds.

4. **Replace the OEM option-ROM first** — `bootutil64e -NIC=N -up=combo
   -FILE=/path/to/BootIMG.FLB`. The community is consistent that nvmupdate
   "refuses to deal with" the Dell OROM, so it's swapped for Intel's combined
   image (`BootIMG.FLB`) first. Pass `-FILE` explicitly — without it bootutil
   looks for `BootIMG.FLB` in the CWD and dies *"Failed to open BootIMG.FLB"*;
   use the copy bundled with the BootUtil package (matched to that bootutil
   version). With `-QUIET` it skips the "create restore image" prompt.

5. **Inject the etrack into `nvmupdate.cfg`.** nvmupdate decides candidacy by
   matching `REPLACES` etrack + VENDOR + DEVICE. Append the card's etrack to the
   `REPLACES:` line of the block whose `NVM IMAGE` is your target image. Edit the
   shipped cfg in place (a hand-written cfg is often rejected; the modified
   original works). Note the cfg uses **CRLF** line endings — keep them.

6. **Flash the NVM, then reset OEM settings.** Crossflash the one card:
   `nvmupdate64e -u -m <MAC> -b -s` (`-b` keeps a backup, `-m` one card, `-s`
   silent). Then reset its OEM user settings to Intel defaults:
   `nvmupdate64e -u -rd -f -m <MAC> -s`. **The `-rd` reset is not optional on OEM
   cards** — skip it and `bootutil -FD` in step 8 returns *"Unsupported
   feature"* (this was the exact wall hit in testing: a real generic crossflash
   still refused `-FD` until `-rd` ran). `-rd` alone is interactive, so it's
   paired with `-u`; `-f` skips the now-redundant image compare. **Do not
   interrupt or power off during either run.**

7. **Reboot.** A reboot reloads the new NVM — Intel's tool reports
   `PowerCycleRequired=0`, and a warm reboot was sufficient in testing. If
   `ethtool -i` still shows the old version afterward, do a full cold A/C cycle;
   the reboot writes nothing, so a no-op reboot can't hurt.

8. **Verify, then disable the option-ROM on every port** — `ethtool -i` should
   show 9.x. Then run `bootutil64e -NIC=N -FD` for **each port of the card**: a
   dual-port card shares one flash chip, but the BIOS dispatches every port that
   still advertises a boot ROM, so both must end up `FLASH Disabled` or the host
   still hangs. This now succeeds because step 6's `-rd` cleared the OEM lock,
   and it's what stops the UEFI-only board from hanging.

Do **one card at a time**, proving each end-to-end before the next.

## Recovery

Tiered — and the only *unrecoverable* tier is the one the step-2 size gate
prevents:

- **Wrong card options / "kinda bricked"** — `nvmupdate64e -rd` resets the card
  to factory defaults; on its own this has rescued cards after a bad flash. (It's
  why the flash step always passes `-rd`.)
- **Soft fail** (interrupted, recovery mode) — the X710 enters Firmware Recovery
  Mode; re-flash, or restore the saved backup via
  `bootutil -RESTOREIMAGE -FILE=<backup>` (or re-run nvmupdate in EFI), then
  cold-cycle.
- **Hard brick — flash-size mismatch only** — a 4M image on an 8M card (or
  vice-versa) corrupts the chip so it won't enumerate, and **no software path
  recovers it**: you need a hardware SPI flasher (CH341A + SOIC-8 clip) to write
  the backup back. This is the single reported unrecoverable case. Confirming
  flash size up front — and the tool's size gate — is what keeps you out of it.

Keep the pre-flash NVM backup in at least two places.
