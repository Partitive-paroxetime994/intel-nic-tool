# intel-nic-crossflash

Safely crossflash OEM-branded Intel NICs (Dell / Lenovo / HP) to **generic Intel
firmware**, so they stop being feature-locked and stop hanging UEFI-only boards
whose option-ROM can't be disabled on the OEM firmware.

The community procedure for this is a set of manual steps (see
[docs/PROCEDURE.md](docs/PROCEDURE.md)) with real brick risk. This wraps it in
one script with the safety steps enforced instead of remembered:

- **Backup before write** — `flash` refuses to run without a fresh NVM backup.
- **Brick guard** — the backup's byte size must equal the profile's expected
  flash size before any write. Wrong flash-size image (4M vs 8M) is the #1 cause
  of a *hard* brick, so it's a hard stop, not a footnote.
- **No mutating default** — nothing happens without an explicit action.
- **One card at a time**, targeted by MAC.

> Firmware flashing can soft- or hard-brick a card and may void warranty. A hard
> brick needs a hardware SPI flasher (CH341A) to recover. Understand the
> procedure before using this.

## Scope

v1 ships one profile, **X710-DA2** (`profiles/x710-da2.conf`) — the only card
tested. The flow is card-agnostic; other Intel NICs are added as profiles, not
code (see [Adding a card](#adding-a-card)).

## Requirements

- Linux, root, `ethtool`, `lspci`, kernel headers + `build-essential`
- Intel **NVM Update Package** for the card family (provides `nvmupdate64e`,
  `nvmupdate.cfg`, and the target `*.bin` images)
- Intel **Preboot/BootUtil** package (provides `bootutil64e` and the `iqvlinux`
  QV-driver source)
- Secure Boot **off** (the `iqvlinux` module is unsigned)

## Usage

```sh
# point at the unpacked Intel tools
export NVM_DIR=/path/to/700Series/Linux_x64
export BOOTUTIL_DIR=/path/to/Preboot/APPS/BootUtil/Linux_x64
export IQV_DIR=$BOOTUTIL_DIR/DRIVER/iqvbuild
export WORK_DIR=$HOME/crossflash-work        # backups + logs

sudo -E ./crossflash.sh inventory                       # identify cards + etrack
sudo -E ./crossflash.sh setup                           # build + load QV driver
sudo -E ./crossflash.sh backup  F8F21E01DDE0 x710-da2   # size-verified backup
sudo -E ./crossflash.sh flash   F8F21E01DDE0 x710-da2   # crossflash (gated)
#   --> cold power-cycle (full A/C off) <--
sudo -E ./crossflash.sh verify       F8F21E01DDE0 x710-da2
sudo -E ./crossflash.sh disable-orom F8F21E01DDE0       # stop UEFI POST hang

# recovery, if needed
sudo -E ./crossflash.sh restore F8F21E01DDE0 $WORK_DIR/F8F21E01DDE0_<ts>.nvm
```

MAC may be given with or without separators.

## Adding a card

Copy `profiles/x710-da2.conf` and set `DEVICE_ID`, `EXPECTED_FLASH_BYTES`,
`NVM_IMAGE`, `OROM_IMAGE` for the new card. `EXPECTED_FLASH_BYTES` must be the
card's true SPI flash size — confirm it from a full NVM dump before trusting it.

## How it works / safety

See [docs/PROCEDURE.md](docs/PROCEDURE.md) for the full procedure, the sources it
came from, and the recovery story.
