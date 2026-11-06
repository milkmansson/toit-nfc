# CLAUDE.md — toit-nfc family working notes

This file tracks decisions, learnings and progress across the whole NFC/RFID
package family, not just this repo. Copy stays authoritative here; other
repos may link back to it.

## Repos

| Repo | Role | Status |
|---|---|---|
| `toit-nfc` | Core reader interface + shared pieces | `Reader`/`Target`/`RawFrameTarget` interfaces, `NfcException`, `Frame`, CRC-A, `CardType` all in place |
| `toit-mfrc522` | MFRC522 driver (SPI, register-level, ISO 14443 Type A only) | Implements `Reader`/`Target`/`RawFrameTarget`; no MIFARE-specific code left in it at all |
| `toit-pn53x` | PN532 driver (UART/I2C now, SPI TODO; command-level, firmware does anticollision) | Implements `Reader`/`Target` (not `RawFrameTarget` — no raw-frame access); kebab-cased |
| `toit-mifare-classic` | MIFARE Classic: sectors, access bits, Crypto1, key recovery | `ClassicCard`/`AccessBits`/`MifareException`/`crypto1.toit` moved in from `toit-mfrc522`, built on `Reader`/`RawFrameTarget`; key recovery still not implemented |
| `toit-mifare-ultralight` | MIFARE Ultralight/NTAG: pages, `PWD_AUTH`, counters, Ultralight C 3DES auth | `UltralightCard`/`UltralightVersion` built on `Target` (no raw-frame access needed, unlike Classic); Ultralight C auth added via `toit-des`; model-specific config pages still out of scope |
| `toit-nfc-parser` | Hardware-free parsing: NDEF, TLV, MAD, Flipper `.nfc` format | `ndef`/`tlv`/`mad`/`flipper` modules done (MAD1 only, not MAD2); no dedicated card-ID module beyond `CardType` |
| `toit-des` | DES/3DES (software), not NFC-specific | `Des`/`TripleDes`/`cbc-encrypt`/`cbc-decrypt` done; used by `toit-mifare-ultralight`, planned for a future DESFire package |

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
  `serial.Registers`, which is bus-agnostic (SPI or I2C). `toit-pn53x`
  supports UART, I2C, and (as of 2026-11-06) SPI, via `Pn53x.uart`,
  `Pn53x.i2c`, `Pn53x.spi` — see progress log.

## Known gaps / limitations to design around

- Darkside, nested and mfkey-style key recovery attacks need raw frame and
  parity control. Native on MFRC522; awkward on PN532 (libnfc does it with
  register hacks). Treat as a capability-gated extra on top of the core
  interface, not part of it.
- Only PN532 can emulate a tag — PN532-specific feature, not in the core
  interface.
- Neither chip reads 125 kHz (LF) tags, unlike Flipper Zero's RFID support.
- `toit-mfrc522` still has a dead, commented-out hardware-path
  `authenticate_`/`is_authenticated_` (`src/mfrc522.toit` ~lines 600-704,
  wrapped in `/* */`) alongside the live software-Crypto1 one — left as-is
  deliberately, see "Hardware vs. software crypto" below. Nested
  authentication doesn't work yet; the "crypto-writer" needs to be brought
  back (see that repo's TODO.md).
- `toit-pn53x`'s `src/main.toit` throwaway `MifareCard` is gone (moved to
  a `Reader`/`poll`-based example); real MIFARE Classic support still
  belongs in `toit-mifare-classic`, not here.

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

- **2026-11-06 (same day, step 2):** Drafted `Reader`/`Target` interfaces
  in `toit-nfc/src/reader.toit` (plus `ReaderCapabilities`), now that both
  chip packages need one. Implemented them in both drivers:
  - `toit-mfrc522`: `Mfrc522 implements Reader`, `Card implements Target`.
    Added `poll --new/bool=false -> Target?` (wraps the existing
    `wake-up-cards_`/`select_` pair) and `off` (wraps `antenna-off`). No
    change to the existing `do --new [block]`/`with-picc` helpers — they
    stay as the richer, mfrc522-specific API; `poll` is the new
    interface-level primitive alongside them.
  - `toit-pn53x`: full kebab-case pass (was still snake_case throughout);
    `Pn53x implements Reader`, new `Pn53xTarget implements Target`. Added
    real parsing of `InListPassiveTarget`'s response in
    `Initiator.list-passive-targets` (target number, ATQA, SAK, UID — ATS
    deliberately not parsed yet, that's ISO-DEP territory later). Dropped
    the dead unused `frame_size_` method. Switched `UartCommunication_`
    off the deprecated `reader`/`writer` libs onto `io.Reader`/`port.in`.
    Moved the throwaway `MifareCard` example out of `src/main.toit`
    entirely — it belonged in `toit-mifare-classic`, not here — and
    replaced the example with one built on `pn53x.poll`.
  - **This slice's PN532 response-parsing code has not been run against
    real hardware yet** (no PN532 board in this environment). Ian: please
    smoke-test `examples/main.toit` against your board before relying on
    `list-passive-targets`/`poll` for anything real.
  - Deliberately did NOT touch `toit-mfrc522`'s commented-out hardware-path
    `authenticate_`/`is_authenticated_` (lines ~600-704, wrapped in `/* */`)
    or write a `MifareClassicAuthenticator`-style interface yet — see
    "Hardware vs. software crypto" below; that decision is better made
    once `toit-mifare-classic` exists and both chips' auth paths are used
    for real.

## Hardware vs. software crypto (MIFARE Classic / Crypto1) — DECIDED

Both reader chips can do MIFARE Classic authentication in hardware:
- MFRC522 has a `MFAuthent` command that runs Crypto1 on-chip.
- PN532 firmware runs Crypto1 on-chip behind `InDataExchange` with
  `0x60`/`0x61` (what `toit-pn53x`'s old throwaway example already used).

Earlier notes here floated a hybrid (hardware fast path for plain
authenticate/read/write, software Crypto1 kept only for nested/recovery
attacks). **Decision: no hybrid — software-only, for everything, on any
reader that can do raw frames.** The `MFAuthent`-style hardware command
can't do nested authentication regardless (you can't get at the raw nonce
exchange once the chip's own crypto unit is engaged), and nested
authentication is required for key-recovery attacks — one of Ian's v1
goals for `toit-mifare-classic`. Since the software path is needed anyway,
a separate hardware-only fast path for plain reads is pure added
complexity (two code paths to maintain and debug) for a speed difference
that doesn't matter at MIFARE Classic's data rates, and it doesn't
generalize to chips without a MIFARE-shaped hardware command anyway. Full
writeup and reasoning: [toit-mifare-classic/README.md](https://github.com/milkmansson/toit-mifare-classic#authentication-is-done-entirely-in-software).

Consequence for `toit-mfrc522`: the chip's hardware `MFAuthent` path
(`COMMAND-MF-AUTHENT_` and the dead commented-out `authenticate_`) was
deleted outright, not just left commented — this driver has no MIFARE
Classic knowledge at all now. `crypto1.toit` (the Crypto1 engine) and the
authentication orchestration (`MifareCard`/`ClassicCard`) both moved to
`toit-mifare-classic`, built on a new `RawFrameTarget` capability
(`transceive-raw frame/Frame -> Frame?`) added to `toit-nfc`, which
`Frame` also moved into (it was already chip-agnostic ISO 14443-3 framing,
and `toit-mifare-classic`'s Crypto1 engine needs the exact same `Frame`
type the driver produces). `toit-pn53x` does not implement
`RawFrameTarget` — the PN532 has no raw-frame access — so
`toit-mifare-classic.ClassicCard.authenticate` throws a clear capability
error on a PN532 `Target`, rather than silently falling back to a hardware
path. Plain reads of unencrypted blocks (eg. block 0) still work on either
chip, since those go through the ordinary `Target.transceive`.

## Crypto building blocks already in the Toit SDK

Checked `crypto.*` in the SDK (v2.0.0) for what we can reuse instead of
hand-rolling, since the CRC-A case showed this is worth checking every
time:
- **CRC-A**: `crypto.crc.crc-a` — exact ISO 14443-3 algorithm, confirmed
  bit-identical (see above). `toit-nfc/src/crc.toit` re-exports it.
- **AES**: `crypto.aes` is present — relevant once `toit-mifare-classic`
  or a future DESFire/NTAG 424 package needs AES (DESFire EV1+ and
  NTAG 424 DNA use AES, not Crypto1).
- **3DES**: NOT in the SDK's `crypto` library. MIFARE Ultralight C uses
  3DES for its authentication — `toit-mifare-ultralight` will need to
  bring its own (or find a package that has it) when it gets there.
- **Crypto1**: obviously not in the SDK (it's MIFARE-proprietary and
  broken); `crypto1.toit` is now in `toit-mifare-classic` (moved from
  `toit-mfrc522` in step 3, see the progress log).

## Progress log (continued)

- **2026-11-06 (step 3):** Built `toit-mifare-classic`. `AccessBits` and
  `MifareException` moved over unchanged (no coupling to any driver).
  `crypto1.toit` moved over with no logic changes — only its imports
  (`nfc.frame` instead of a local `.frame`) and swapping the deprecated
  `binary show LITTLE-ENDIAN BIG-ENDIAN` for `io show LITTLE-ENDIAN`
  (`BIG-ENDIAN` was imported but never used). `MifareCard` became
  `ClassicCard`, rebuilt on `Target`/`RawFrameTarget` instead of being a
  `Card` subclass tied to `Mfrc522`; the authentication handshake
  orchestration (nonce exchange, challenge/response) that used to live in
  `Mfrc522.authenticate_` moved here too, now driving `RawFrameTarget`
  directly instead of a private driver method.
  - Fixed two bugs while porting (both pre-existing in the original
    `Mfrc522.authenticate_`/`MifareCard`, not introduced by the move):
    (1) `MifareCryptoReader` requires a 4-byte UID, but the original code
    passed a 7/10-byte UID straight through without slicing to its last 4
    bytes, which would have thrown `INVALID_UID` for any card with a
    longer UID; `ClassicCard.authenticate` now slices it first. (2)
    `read`/`write`'s block-range check was `0 <= block <= total-block-count`
    (off-by-one — blocks are 0-indexed, so the valid range's upper bound
    should be exclusive); now `0 <= block < total-block-count`.
  - `write-to-stdout`'s auth-failure recovery no longer attempts the raw
    `wake-up-cards_`/`select_` reconnect the original mfrc522-specific code
    did — `ClassicCard` only holds a `Target`, not a `Reader`, so it can't
    re-poll. It now just prints "encrypted" and skips to the next sector,
    same as before minus the reconnect attempt.
  - `toit-mfrc522` lost `COMMAND-MF-AUTHENT_`, the `--command` parameter on
    the low-level `transceive_` (it only ever had one caller once MFAuthent
    was gone), the `crypto_` field, and all Mifare-specific classes. Added
    a public `transceive-raw` on `Card` (thin wrapper over the existing
    private `transceive_`) implementing `RawFrameTarget`.
  - `toit-mfrc522/examples/main.toit` updated to use
    `mifare-classic.ClassicCard` instead of the deleted `MifareCard`; card
    detection now checks `it.type` against `CardType` MIFARE constants
    (used to be automatic — removing `MifareCard` from `Card`'s constructor
    meant dropping that auto-specialization).
  - `crypto1-test.toit` (moved, same name convention issue as before: file
    content uses snake_case identifiers like `set_key`/`expect_equals`
    calling kebab-case definitions like `set-key` — confirmed Toit treats
    `_` and `-` as equivalent within identifiers, so this just works
    without rewriting the test) still passes, byte-for-byte identical
    output to the pre-move baseline (modulo the now-gone deprecation
    warnings from the `LITTLE-ENDIAN` import fix).
  - Not done yet, deliberately out of scope for this slice: Crypto1 key
    recovery (darkside/nested/mfkey-style attacks) itself. The plumbing
    (`RawFrameTarget`, the moved engine) is now in place for it.

- **2026-11-06 (steps 4 and 5, done together):** Built both
  `toit-mifare-ultralight` and `toit-nfc-parser`, picked because neither
  needs hardware to write or test — see "what else can we continue with
  before a hardware test is mandatory" in the session this was done in.
  - `toit-mifare-ultralight`: `UltralightCard` (read, write, authenticate
    via `PWD_AUTH`, get-version, read-signature, read-counter) built on
    `Target` directly — notably, none of the Ultralight-family commands
    need `RawFrameTarget`, unlike Classic's Crypto1, so this package works
    over any reader including the PN532. `UltralightException` mirrors
    the NAK-code shape of `toit-mifare-classic`'s `MifareException`.
    Scoped out: Ultralight C's 3DES authentication (no 3DES in the SDK),
    and per-model configuration pages (`AUTH0`/`ACCESS`/`CFG0`/`CFG1` —
    their page numbers differ per model/memory size, which would need a
    model lookup table built on firmer ground than memory). Unit-tested
    against the NTAG213 `GET_VERSION` response documented in NXP's
    datasheet.
  - `toit-nfc-parser`: `ndef` (`NdefRecord`/`NdefMessage`, well-known
    Text/URI helpers, chunked records explicitly rejected rather than
    mis-parsed), `tlv` (Type 2 Tag memory TLV framing, plus
    `Tlv.find-ndef-message`), `mad` (MAD1 only — sectors 1-15; MAD2 not
    implemented), `flipper` (the stable backbone of Flipper's `.nfc`
    format: device type/UID/ATQA/SAK/block-or-page dumps; unrecognized
    fields kept verbatim rather than rejected, since the format evolves
    across firmware versions). No dedicated card-identification module —
    `CardType` in `toit-nfc` already covers what's identifiable from SAK
    alone; going further (eg. NTAG213 vs 215 vs 216) needs
    `GET_VERSION`, which needs hardware.
  - Confidence notes, both flagged to Ian directly and in each package's
    README rather than as hedge-words buried in code comments: the MAD
    CRC parameters (`CRC-8/MIFARE-MAD`: poly `0x1D`, init `0xC7`) are
    self-checked against that algorithm's own published test vector
    (`"123456789"` → `0x99`), which confirms the SDK's `Crc` is configured
    the way that catalogued algorithm is defined, but that's independent
    of whether it's actually what a real MAD-using card uses. The Flipper
    `.nfc` format support is built from its publicly documented shape,
    not a live export from an actual Flipper device. Both are listed as
    good first things to check once there's hardware (or a Flipper)
    at hand.
  - Everything in both packages is round-trip tested (encode then decode,
    or the reverse) rather than against real data, since that's the
    strongest check available without hardware.

- **2026-11-06 (toit-des, and Ultralight C auth):** Ian asked whether
  3DES is viable in software given it's not in the SDK. Answer: yes —
  3DES's weaknesses (64-bit block size, effective key strength below its
  nominal bit count) are about scale, not about it being broken the way
  Crypto1 is; the SDK just doesn't ship it. MIFARE Ultralight C and
  legacy MIFARE DESFire (EV0, and EV1 in backward-compatible mode) both
  need it and are still out in the field, so built it.
  - New package `toit-des`: `Des` (single DES) and `TripleDes` (3DES,
    EDE mode, 16-byte 2-key or 24-byte 3-key), plus `cbc-encrypt`/
    `cbc-decrypt`. Deliberately **not** NFC-specific — no dependency on
    or awareness of `toit-nfc` — because DES/3DES has no NFC-specific
    content; it's a generic cipher the SDK happens to be missing. Lives
    as its own repo rather than inside `toit-nfc` for that reason. A
    future DESFire package would depend on it directly, the same way
    `toit-mifare-ultralight` now does.
  - Checked against the classic published DES known-answer test vector
    (key `13 34 57 79 9B BC DF F1`, plaintext `01 23 45 67 89 AB CD EF`
    → ciphertext `85 E8 13 54 0F 0A B4 05`) — confirmed to actually
    discriminate by deliberately corrupting one table entry and
    confirming the test suite failed, then reverting. Also checked the
    degenerate identity that 3DES with all three keys equal must equal
    plain single DES (holds regardless of whether the cipher matches the
    real standard — it only proves encrypt/decrypt are true inverses of
    each other; the known-answer test is what proves standards
    compliance). None of this run against real hardware.
  - Added `UltralightCard.authenticate-ultralight-c` to
    `toit-mifare-ultralight`, implementing Ultralight C's 3DES mutual
    authentication (ISO/IEC 11770-2 three-pass) on top of `toit-des`.
    Tested by simulating the tag side of the handshake with the same key
    (`FakeUltralightCTarget` in the test file — same technique as
    `crypto1-test.toit`'s reader-against-writer simulation), which
    checks the CBC chaining, nonce-rotation and comparison logic is
    self-consistent; verified this test actually discriminates by
    breaking the rotation check and confirming the test failed, then
    reverting. **Open question, flagged in the package's README**: the
    exact byte-level framing of the second step's response (whether the
    card's final reply carries a leading status byte before the 8-byte
    encrypted nonce) wasn't checked against a real card or the datasheet
    text this session — the code accepts either shape rather than
    committing to one, and this is the first thing to verify once
    there's an Ultralight C card and reader on hand.

- **2026-11-06 (ISO-DEP layer):** Built `IsoDepCard` in
  `toit-nfc/src/iso-dep.toit` — RATS/ATS and the I-block/R-block/S-block
  framing (`toit-mifare-classic`/`toit-mifare-ultralight` sit directly on
  `Target`; a future DESFire or NTAG 424 package would sit on this
  instead). Lives in `toit-nfc` itself, not its own repo, since it has no
  card-specific content — same reasoning as `Frame`/CRC-A, the opposite
  conclusion from `toit-des` (which has no *NFC*-specific content and so
  got its own repo).
  - Only needs plain `Target.transceive`, not raw-frame access — RATS
    and I-blocks are standard framed command/response pairs with their
    own CRC, not a raw-frame-only exchange like Crypto1 — so this works
    over any reader, PN532 included.
  - Before writing the PCB (Protocol Control Byte) bit constants from
    memory, searched for and cross-checked them against a real captured
    I-block (PCB `0x0A`: CID-following, block 0) and R-block (PCB `0xBA`:
    NAK, CID-following, block 0) rather than trusting recollection alone
    — they matched what was recalled, which is reassuring but not the
    same as a hardware test. Also confirmed the ATS field layout (T0's
    presence bits for TA1/TB1/TC1, FSCI in T0's low nibble, FWI/SFGI in
    TB1) against multiple independent sources before implementing the
    parser.
  - Implements: FSC (max frame size) from ATS's FSCI, FWI→FWT informational
    only (not actively enforced — `Target.transceive`'s timeout is the
    underlying driver's concern, not this layer's), NAD/CID support flags
    from TC1, historical bytes, I-block chaining in both directions
    (splitting an outgoing APDU wider than FSC, reassembling a chained
    response), transparent S(WTX) echo-back, S(DESELECT) on `close`.
  - Explicitly **not** implemented: PPS (bit-rate negotiation — costs
    throughput, not correctness, to skip) and R-block-based
    retransmission on a corrupted/missing reply (needs real timeout/retry
    handling this layer doesn't have yet; a broken exchange throws
    instead of retrying).
  - **2026-11-06 follow-up:** closed both gaps partially. Added a simple
    retry (resend the exact same block, up to 3 times) on a timeout or a
    caught exception from `target_.transceive`, in
    `send-and-wait-out-wtx_`. This is a simplification of the standard's
    own R-block-based recovery (which would distinguish "my command
    never arrived" from "the reply got corrupted"), kept simple since
    that distinction can't be meaningfully checked without real hardware
    noise. Verified the new tests (`test-retries-on-transient-failure`,
    `test-gives-up-after-too-many-failures`) actually discriminate by
    temporarily lowering the retry limit and confirming the suite failed,
    then reverting. PPS is still deliberately not implemented — it
    would negotiate a bit rate that neither `toit-mfrc522` nor
    `toit-pn53x` can currently act on, so there's nothing for it to do
    yet.
  - Tested by simulating the full PICC side of the protocol independently
    of `IsoDepCard`'s own code (`FakeIsoDepTarget` in
    `tests/iso-dep-test.toit` — same "simulate both sides" technique as
    `crypto1-test.toit` and the Ultralight C auth test): ATS parsing (both
    a TL-only response and one with all of TA1/TB1/TC1 and historical
    bytes present), a plain exchange, outgoing request chaining, incoming
    response chaining, a WTX request mid-response, and deselect-on-close.
    Verified the chaining and WTX tests actually discriminate by
    deliberately breaking each one (wrong chaining bit, wrong WTX
    selector) and confirming the suite failed, then reverting. None of
    this has been run against a real ISO 14443-4 card.

- **2026-11-06 (toit-pn53x SPI transport):** Added `Pn53x.spi` and
  `SpiCommunication_`, filling in the one gap left over from step 2
  (`toit-pn53x` previously only had UART and I2C). Built from NXP
  application note AN133910 ("PN532 SPI").
  - The PN532 shifts data LSB-first on the wire, which Toit's `spi`
    library has no setting for (`--mode` only configures CPOL/CPHA), so
    every byte sent and received is bit-reversed in software. Before
    reading a response, the host polls a status control byte until the
    chip reports ready, replacing the IRQ pin the I2C transport uses for
    the same purpose.
  - **Estimates introduced, flagged per the standing instruction to call
    these out**: the ~1 ms NSS-low wakeup pulse (from AN133910's own
    text, not measured), and the 1000 ms status-poll timeout with a 1 ms
    poll interval (both picked as reasonable values, not derived from a
    specific datasheet number or a measurement). These are the first
    things to tune once there's a real board to test against.
  - `SpiCommunication_` and its bit-reversal/status-poll helpers are
    library-private to `src/pn53x.toit`, the same as the UART/I2C
    transports, so none of them can be unit-tested from `tests/` without
    changing that — which is why `toit-pn53x` has no test files for any
    of its three transports. Not run against a real board.

## Carried over from toit-mfrc522's TODO.md and .reference/notes.txt

`toit-mfrc522` had its own `TODO.md` and a `.reference/notes.txt` (research
notes, kept — with the datasheets — in `.reference/`, now committed there
pending a conversation with floitsch about whether they belong in the repo
at all). The items below are specifically about Crypto1/MIFARE Classic,
so they're now about `toit-mifare-classic`, not `toit-mfrc522`; moved here
since that's where they'll actually get picked up.

**Open TODOs:**
- **Nested authentication is wired up but known not to actually work.**
  `crypto1.toit`'s state machine supports it (`MifareCryptoReader`
  transitions to a nested state when `start-authentication` is called a
  second time), and `ClassicCard.authenticate` exercises that path
  automatically on a second call — but the original note says this was
  tried against real hardware and didn't work, without a confirmed root
  cause. Said to use the trace papers in `.reference/notes.txt` (below) to
  figure out why. This is almost certainly the first thing to debug before
  attempting any nested-auth-dependent key-recovery attack.
- **Naming consistency**: `crypto1.toit` isn't fully consistent about
  "plain"/"plaintext" vs "cipher"/"ciphertext" terminology. Minor, cosmetic,
  low priority.
- **Bring back the "crypto-writer"**: `MifareCryptoWriter` already exists
  in `crypto1.toit` (used today only by the test, to simulate the tag side
  of a handshake) but nothing drives it for real. Relevant once tag
  emulation becomes a goal — PN532 can emulate a tag; MFRC522 can't (see
  "Known gaps" above).

**Reference material worth keeping even if `.reference/` itself doesn't
survive the floitsch conversation** — attack techniques and sources to
read before implementing MIFARE Classic key recovery in
`toit-mifare-classic`:
- Wirelessly Pickpocketing a Mifare Classic Card: https://repository.ubn.ru.nl/bitstream/handle/2066/75545/1/75545.pdf
- Dismantling Mifare (darkside attack; reader attack = LFSR rollback, section 6.2): https://www.cs.bham.ac.uk/~garciaf/publications/Dismantling.Mifare.pdf
- Ciphertext-only cryptanalysis on hardened MIFARE Classic cards: http://www.cs.ru.nl/~rverdult/Ciphertext-only_Cryptanalysis_on_Hardened_Mifare_Classic_Cards-CCS_2015.pdf
- DEF CON China — tag-side attacks against NFC (also explains attacking Crypto1 from the tag side): https://media.defcon.org/DEF%20CON%20China%201/DEF%20CON%20China%201%20presentations/DEF%20CON%20China%201.0%20-%20Presentations/DEF%20CON%20China%201.0%20-%20Christopher-Wade-Tag-side-attacks-against-NFC.pdf
- Proxmark3's `mfkey32` (reference implementation of the nested-auth key-recovery math): https://github.com/Proxmark/proxmark3/blob/master/tools/mfkey/mfkey32.c
- Hardnested attack implemented against an actual MFRC522 (closest prior art to what we'd build): https://github.com/HakonHystad/MFRC522_nested_attack
- MIFARE Ultralight protocol description, including how to build a tag emulator (relevant to `toit-mifare-ultralight` too): https://ora.ox.ac.uk/catalog/uuid:8e52bcfe-5ab5-40b8-b1f4-6b11fd0e67f2/download_file?file_format=application%2Fpdf&safe_filename=12-15.pdf

Real captured authentication traces (reader↔tag byte exchanges with known
keys) are also in `.reference/notes.txt` — useful as additional
`crypto1-test.toit` test vectors beyond the ones already there, if the
nested-auth bug above needs a wider net to catch.

## Plan / order of work

1. ~~Extract the core interface from `toit-mfrc522` with no behaviour
   change~~ — done.
2. ~~Clean up `toit-pn53x` scaffolding (naming, README) and implement the
   core `Reader`/`Target` interface on both drivers~~ — done.
   `toit-pn53x`'s SPI transport (the one gap left here) is also now
   done — see progress log, 2026-11-06.
3. ~~Build `toit-mifare-classic` on the core interface~~ — done (software
   Crypto1 only, see above). Running the same example against a PN532
   board is still outstanding — needs real hardware testing, which
   hasn't happened yet (Ian is travelling).
4. ~~Add `toit-mifare-ultralight` for NTAG support~~ — done (read, write,
   authenticate, get-version, read-signature, read-counter). Not run
   against a real chip yet.
5. ~~Build `toit-nfc-parser` for NDEF/MAD/Flipper-format~~ — done
   (`ndef`, `tlv`, `mad` — MAD1 only — and `flipper`). No dedicated
   card-identification module was built; `CardType` in `toit-nfc` already
   covers SAK-based identification, and anything beyond that (eg.
   distinguishing NTAG213/215/216) needs `GET_VERSION`, which is
   hardware-only, so there wasn't more to add here without a reader.
6. ~~Ultralight C's 3DES authentication~~ — done (`toit-des` +
   `authenticate-ultralight-c`; see progress log). Still later: DESFire
   (needs step 7 plus DESFire's own command set and session-key
   derivation), nested authentication, key-recovery attacks against
   owned cards (planned as a v1 feature of `toit-mifare-classic`, not
   required for first read/write release), MAD2.
7. ~~Software ISO-DEP layer (RATS, I-blocks, WTX chaining)~~ — done
   (`IsoDepCard` in `toit-nfc/src/iso-dep.toit`; see progress log). A
   simple retry-the-same-block recovery was added afterward; PPS stays
   deliberately unimplemented since no driver can act on a negotiated
   bit rate yet — see the README.

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
