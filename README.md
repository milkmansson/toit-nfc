# toit-nfc

Core package for a family of Toit NFC/RFID packages, inspired in part by the
card-support work done in the [Flipper Zero](https://github.com/flipperdevices)
project.

## Architecture

NFC/RFID reader chips (MFRC522, PN532, ...) differ in which bus they use and
how much of the protocol they handle in firmware. Card types (MIFARE Classic,
MIFARE Ultralight/NTAG, ...) differ in their memory layout and authentication
scheme, but not in which reader chip is underneath them.

This package provides the common reader interface (field on/off, poll for a
target, select, halt, transceive) and the pieces that are the same across
chips and cards: exceptions, CRC-A, the AN10833 card-type table, and a
software ISO-DEP layer for chips that need one. Each reader chip gets its own
driver package implementing this interface; each card family gets its own
package built on top of it.

| Package | Contents |
|---|---|
| **toit-nfc** (core) | `Reader`/`Target`/`RawFrameTarget` interfaces, capability flags, shared `NfcException`, `Frame`, CRC-A, AN10833 type table, ISO-DEP (`IsoDepCard`) |
| **toit-mfrc522** | Register/FIFO/IRQ driver implementing the core interface; frame-level, raw-frame-capable |
| **toit-pn53x** | Command/transport driver (UART/I2C now, SPI to add) implementing the core interface; firmware-level, no raw-frame access |
| **toit-mifare-classic** | Sector/block/access-bits logic, Crypto1 (moved from mfrc522), authentication, nested/darkside/mfkey-style recovery against your own cards (v1, can land after basic read/write) |
| **toit-mifare-ultralight** | Page layout, `PWD_AUTH`, counters/signatures |
| **toit-nfc-parser** | Hardware-free: byte dumps → structured data. NDEF/TLV, MAD, card-type identification, Flipper `.nfc` import/export |

## CRC-A is not reimplemented here

`src/crc.toit` re-exports the SDK's own `crypto.crc.crc-a` rather than
hand-rolling the ISO 14443-3 CRC_A polynomial. We checked first: the SDK's
`Crc.little-endian 16 --normal-polynomial=0x1021 --initial-state=0x6363` is
bit-for-bit identical to the CRC_A used throughout this protocol family
(verified against several ISO 14443-3 test vectors, including the
empty-input case), so there was no reason to carry a second copy of that
math. Only a small `check-crc-a` wrapper (CRC check + throwing
`NfcException`) is this package's own code. Flagging this explicitly in
case there's a reason (e.g. an existing Toit convention we're not aware of)
to do it differently.

## MIFARE Classic authentication is software-only, by design

`toit-mifare-classic` does not use any reader chip's own hardware Crypto1
unit (MFRC522's `MFAuthent`, or the PN532 firmware's equivalent). It runs
Crypto1 entirely in software over raw frames (`RawFrameTarget`, above),
because a hardware fast path can't do nested authentication, which
MIFARE Classic key recovery needs — so the software path is required
regardless, and a separate hardware-only path for plain reads would just
be extra surface to maintain for no functional gain. Full reasoning in
[toit-mifare-classic's README](https://github.com/milkmansson/toit-mifare-classic#authentication-is-done-entirely-in-software).

## ISO-DEP (ISO/IEC 14443-4)

`IsoDepCard` (in `src/iso-dep.toit`) is the transport layer any ISO
14443-4 card needs — MIFARE DESFire, NTAG 424 DNA, JavaCards. It does
RATS/ATS and the I-block/R-block/S-block framing (chaining in both
directions, S(WTX) time-extension requests, S(DESELECT)) on top of a
plain `Target`, since none of that needs raw-frame access — it's a
standard framed command/response exchange like any other ISO 14443-3
command, so it works over any reader, the PN532 included.

It lives here rather than in a card-family package for the same reason
`Frame` and CRC-A do: it has no card-specific content, so any future
package built on ISO 14443-4 (a DESFire package, say) can depend on it
directly rather than duplicating it.

Protocol and Parameter Selection (PPS) isn't implemented, deliberately:
it would have nothing to do, since negotiating a faster bit rate is
pointless until the underlying reader driver can actually switch the
PICC's communication speed, and neither `toit-mfrc522` nor `toit-pn53x`
exposes that yet. Worth revisiting once a driver supports changing bit
rate.

A failed exchange (a timeout, or a corrupted/CRC-failing reply) is
retried a few times by resending the exact same block, rather than
throwing immediately. This is a simplification of the standard's own
recovery, which would distinguish "my command never arrived" from "the
reply got corrupted" and use an R-block in the latter case — not
implemented here, since the distinction can't be meaningfully checked
without real hardware noise to provoke it.

The PCB bit layout used here was cross-checked against a real captured
I-block and R-block (found during this work, not from memory alone)
rather than taken purely from recollection, but the class as a whole
hasn't been run against real hardware yet — only against a simulation
of both sides of the protocol (see `tests/iso-dep-test.toit`), which is
the strongest check available without an actual ISO 14443-4 card and
reader on hand.

---

Parts of this repository were developed with the help of [Claude Code](https://claude.com/claude-code).
