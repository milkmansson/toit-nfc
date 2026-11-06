// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .card-type show CardType
import .frame show Frame

/**
What a $Reader chip does itself versus what has to be done in software on
  top of it.

Reader chips range from frame-level (MFRC522: the driver does anticollision,
  CRC and raw parity bits itself) to command-level (PN532: the firmware does
  anticollision and ISO-DEP chaining, and has its own hardware MIFARE
  Classic Crypto1 unit). Code that only needs "find a target and exchange
  bytes with it" can ignore these flags; code that needs raw frame access
  (Crypto1 attacks, emulation) must check them first.
*/
class ReaderCapabilities:
  /**
  Whether the driver can send and receive raw bits/frames, including
    control over parity bits and deliberate collisions.

  Needed for Crypto1 attacks (darkside, nested, mfkey-style key recovery).
  True on MFRC522-style chips; generally not available on PN532-style chips
    without register-level hacks.
  */
  supports-raw-frames/bool

  /**
  Whether the reader chip's firmware does anticollision/target selection
    itself, as opposed to the driver doing it frame-by-frame.
  */
  firmware-does-anticollision/bool

  /** Whether the reader chip can poll for ISO 14443 Type B targets. */
  supports-type-b/bool

  /** Whether the reader chip can emulate a tag (card emulation mode). */
  supports-tag-emulation/bool

  constructor
      --.supports-raw-frames/bool
      --.firmware-does-anticollision/bool
      --.supports-type-b/bool=false
      --.supports-tag-emulation/bool=false:

/**
A target (PICC, "Proximity Inductive/Inductive Coupling Card") found in the
  field of a $Reader.

Card-family packages (MIFARE Classic, Ultralight, ...) build on top of this:
  they use $uid and $type to recognize a card, and $transceive to talk to
  it, without caring which reader chip found it.
*/
interface Target:
  /** The UID of this target. */
  uid -> ByteArray

  /**
  The type of this target, as identified from its SAK and UID. See
    $CardType.

  Note that some cards (eg. MIFARE Plus) might report themselves as a
    generic type for privacy reasons.
  */
  type -> int

  /**
  Transmits $bytes to this target and returns its response, or null if the
    target did not answer in time.
  */
  transceive bytes/ByteArray --check-crc/bool=false -> ByteArray?

  /** Sends a halt command, so the target stops responding to further polls. */
  close -> none

/**
A reader chip (PCD, "Proximity Coupling Device").

Implemented by each chip driver package (toit-mfrc522, toit-pn53x, ...).
*/
interface Reader:
  /** What this reader chip can do; see $ReaderCapabilities. */
  capabilities -> ReaderCapabilities

  /** Turns the antenna/field on and resets internal state. */
  on -> none

  /** Turns the antenna/field off. */
  off -> none

  /**
  Polls once for a target in the field.

  If $new is true, only wakes up targets that are currently halted/idle
    (REQA-style); otherwise wakes up every compatible target in the field,
    including ones already selected before (WUPA-style).

  Returns the first $Target found, or null if none answered.
  */
  poll --new/bool=false -> Target?

/**
A $Target that can send and receive raw ISO 14443-3 frames: no automatic
  CRC, and parity bits exactly as given rather than computed.

Only implemented by readers with $ReaderCapabilities.supports-raw-frames.
This is the primitive MIFARE Classic Crypto1 authentication (and
  Crypto1 key-recovery attacks) are built on in software, since the
  authentication handshake's parity bits themselves carry keystream
  information that a normal $Target.transceive call's automatic parity
  handling would destroy.
*/
interface RawFrameTarget:
  /**
  Transmits $frame and returns the response, or null on timeout.

  If $Frame.is-raw, sends its bytes and parity bits exactly as given.
  Otherwise, computes standard odd parity for it, the same as
    $Target.transceive would.
  */
  transceive-raw frame/Frame -> Frame?
