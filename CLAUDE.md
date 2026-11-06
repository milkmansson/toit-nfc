# CLAUDE.md — toit-nfc family working notes

This file tracks decisions, learnings and progress across the whole NFC/RFID
package family, not just this repo. Copy stays authoritative here; other
repos may link back to it.

## Repos

| Repo | Role | Status |
|---|---|---|
| `toit-nfc` | Core reader interface + shared pieces | Just started; extracting from `toit-mfrc522` |
| `toit-mfrc522` | MFRC522 driver (SPI, register-level, ISO 14443 Type A only) | Working driver exists; has Crypto1, needs refactor onto core interface |
| `toit-pn53x` | PN532 driver (UART/I2C now, SPI TODO; command-level, firmware does anticollision) | Early scaffolding; `MifareCard` is a throwaway class in `src/main.toit`, needs proper implementation |
| `toit-mifare-classic` | MIFARE Classic: sectors, access bits, Crypto1, key recovery | Not started; code to move out of `toit-mfrc522` |
| `toit-mifare-ultralight` | MIFARE Ultralight/NTAG: pages, `PWD_AUTH`, counters | Not started |
| `toit-nfc-parser` | Hardware-free parsing: NDEF, MAD, card ID, Flipper `.nfc` format | Not started |

Ian's hardware: MFRC522 and PN532 sample boards, MIFARE 1K cards, NTAG cards,
plus some unidentified cards to be identified as this is built out.

## Why this split

- Card logic (access bits, Crypto1, NDEF, page layout) doesn't depend on
  which reader chip is underneath, so it belongs in its own packages, not
  duplicated in each driver.
- Encryption schemes are NOT shared across card families: Classic uses
  Crypto1, Ultralight C uses 3DES, DESFire uses AES/3DES over ISO 14443-4.
  Each card package owns its own crypto.
- MFRC522 is frame-level (anticollision, CRC, raw parity bits done by the
  driver); PN532 is command-level (firmware does anticollision and ISO-DEP
  chaining, has hardware Crypto1 behind `InDataExchange`). The core interface
  has to sit above both: "find a target, select it, exchange bytes" — not
  "send raw bits".
- `toit-mfrc522` already drives through Toit's generic `serial.Device` /
  `serial.Registers`, which is bus-agnostic (SPI or I2C). `toit-pn53x` is not
  there yet (hardcodes I2C/UART transports, no SPI stub implemented) — this
  needs fixing so both drivers accept whatever bus the chip actually
  supports.

## Known gaps / limitations to design around

- Darkside, nested and mfkey-style key recovery attacks need raw frame and
  parity control. Native on MFRC522; awkward on PN532 (libnfc does it with
  register hacks). Treat as a capability-gated extra on top of the core
  interface, not part of it.
- Only PN532 can emulate a tag — PN532-specific feature, not in the core
  interface.
- Neither chip reads 125 kHz (LF) tags, unlike Flipper Zero's RFID support.
- `toit-mfrc522` has duplicate WIP `authenticate_`/`is_authenticated_`
  definitions (`src/mfrc522.toit` ~lines 600-704) left over from in-progress
  work; nested authentication doesn't work yet; the "crypto-writer" needs to
  be brought back (see that repo's TODO.md).
- `toit-pn53x` README/structure is still mostly the package template;
  `src/main.toit` should not contain a real `MifareCard` implementation
  long-term — that belongs in `toit-mifare-classic`.

## Progress log

- **2026-11-06:** Step 1 slice done. Extracted `NfcException`, CRC-A and the
  AN10833 `CardType` table out of `toit-mfrc522` into `toit-nfc/src/`, with
  no behaviour change (`crypto1_test` output is byte-identical before and
  after; verified by diff). `toit-mfrc522` now depends on `toit-nfc` as a
  local path package (prefix `nfc`).
  - Learning: Toit's SDK already ships the exact ISO 14443-3 CRC_A algorithm
    as `crypto.crc.crc-a` (`Crc.little-endian 16 --normal-polynomial=0x1021
    --initial-state=0x6363`) — verified bit-for-bit identical to the
    hand-rolled version across several samples including the empty-input
    case. `toit-nfc/src/crc.toit` now re-exports it instead of
    reimplementing the polynomial, and only adds the `check-crc-a` wrapper
    (CRC check + throwing `NfcException.crc`/`.protocol`) on top.
  - Learning: `jag toit pkg install --local <path>` (SDK v2.0.0 / jag
    v1.73.0) sometimes writes a `package.lock` where the `packages:` key has
    a `-2`-suffixed name (e.g. `toit-nfc-2`) that doesn't match the name the
    `prefixes:` section points at, breaking resolution. Fix by hand-editing
    the lock file to make the key match the prefix target. Also: installing
    a local package in a package's own `package.yaml` does NOT propagate to
    that package's `tests/`/`examples/` sub-projects automatically — run
    `jag toit pkg install --recompute` in each sub-project too after a
    parent's dependencies change.
  - The `Reader`/`Target` core interface was deliberately NOT drafted yet —
    deferred to step 2, once `toit-pn53x` needs one too, so it's shaped by
    two real implementations instead of guessed from one.
  - `toit-mfrc522/src/nfc_exception.toit` deleted (fully replaced).
    `compute-crc_`/`check-crc_` and the `Card.TYPE-*`/`sak-to-type_`/
    `type-to-str_` members removed from `mfrc522.toit`, replaced with calls
    into `toit-nfc`.

## Plan / order of work

1. Extract the core interface from `toit-mfrc522` with no behaviour change
   (its `crypto1_test` should keep passing throughout).
2. Clean up `toit-pn53x` scaffolding (naming, README, SPI stub) and implement
   the core interface on top of it.
3. Build `toit-mifare-classic` on the core interface; run the same
   example against both boards as the acceptance test.
4. Add `toit-mifare-ultralight` for NTAG support.
5. Build `toit-nfc-parser` for NDEF/MAD/card-ID/Flipper-format, independent
   of any hardware.
6. Later: ISO-DEP + DESFire, nested authentication, key-recovery attacks
   against owned cards (planned as a v1 feature of
   `toit-mifare-classic`, not required for first read/write release).

## Upstream

Ian's repos are forks-of-intent, not forks-of-code, pointed at
`milkmansson/*` on `origin` with `toitware/*` as `upstream` (fetch-only —
no push access there). Once this is further along, next step is to talk to
floitsch about whether/how this lands upstream (likely squash-merged into
new toitware repos or PRs), rather than publishing these as permanent
forks.

## Next hardware

Chips worth sourcing as logical next additions to the collection, once the
MFRC522/PN532 pair is solid:
- A chip/module covering LF (125 kHz) to close the gap with Flipper's RFID
  support.
- A chip with native SPI+I2C+UART flexibility beyond what these two offer,
  if one is found, to stress-test how general the core interface really is.
