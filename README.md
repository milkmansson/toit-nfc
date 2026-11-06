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
| **toit-nfc** (core) | Reader interface (`on`/`off`, poll, select, halt, transceive), capability flags, shared `NfcException`, CRC-A, AN10833 type table, software ISO-DEP layer |
| **toit-mfrc522** | Register/FIFO/IRQ driver implementing the core interface; keeps `crypto1.toit` short-term |
| **toit-pn53x** | Command/transport driver (UART/I2C now, SPI to add) implementing the core interface |
| **toit-mifare-classic** | Sector/block/access-bits logic, Crypto1 (moved from mfrc522), authentication, nested/darkside/mfkey-style recovery against your own cards (v1, can land after basic read/write) |
| **toit-mifare-ultralight** | Page layout, `PWD_AUTH`, counters/signatures |
| **toit-nfc-parser** | Hardware-free: byte dumps → structured data. NDEF/TLV, MAD, card-type identification, Flipper `.nfc` import/export |

## Status

This package now holds: `NfcException`; CRC-A (`crc-a` re-exported from the
SDK's `crypto.crc`, plus a `check-crc-a` helper); the AN10833 card-type
table (`CardType`); and the `Reader`/`Target` interface (plus
`ReaderCapabilities`), implemented by both `toit-mfrc522` and `toit-pn53x`.
Still to come: a software ISO-DEP layer, and any chip-authentication
interface MIFARE Classic needs (deferred until `toit-mifare-classic` is
being built, so it's shaped by real use rather than guessed).

See [CLAUDE.md](CLAUDE.md) for the working notes and progress log on this
effort.
