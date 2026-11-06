// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Identification of card types from their SAK (Select Acknowledge) byte and
  UID length, independent of which reader chip obtained them.

See NXP AN10833 - MIFARE Type Identification Procedure.
*/
class CardType:
  /** Unknown type of card. */
  static UNKNOWN ::= 0

  /** MIFARE Ultralight or Ultralight C. */
  static MIFARE-UL ::= 1
  /** MIFARE Classic protocol, 320 bytes. */
  static MIFARE-MINI ::= 2
  /** MIFARE Classic protocol, 1KB. */
  static MIFARE-1K ::= 3
  /** MIFARE Classic protocol, 4KB. */
  static MIFARE-4K ::= 4
  /** MIFARE Plus (2KB or 4KB) or MIFARE DESFire. */
  static MIFARE-PLUS-DESFIRE ::= 5

  /**
  Determines the card type from its $sak and the length of its $uid.

  See NXP AN10833 - MIFARE Type Identification Procedure.
  */
  static from-sak sak/int uid/ByteArray -> int:
    type-bits := sak & 0x7F
    if type-bits == 0x00: return MIFARE-UL
    if type-bits == 0x09: return MIFARE-MINI
    if type-bits == 0x08: return uid.size == 4 ? MIFARE-1K : MIFARE-PLUS-DESFIRE
    if type-bits == 0x18: return uid.size == 4 ? MIFARE-4K : MIFARE-PLUS-DESFIRE
    if type-bits == 0x10: return MIFARE-PLUS-DESFIRE
    if type-bits == 0x11: return MIFARE-PLUS-DESFIRE
    if type-bits == 0x20: return MIFARE-PLUS-DESFIRE
    return UNKNOWN

  /** A human-readable description of the card $type. */
  static to-string type/int -> string:
    if type == UNKNOWN: return "Unknown card"
    if type == MIFARE-MINI: return "MIFARE Mini, 320 bytes"
    if type == MIFARE-1K: return "MIFARE 1KB"
    if type == MIFARE-4K: return "MIFARE 4KB"
    if type == MIFARE-PLUS-DESFIRE: return "MIFARE Plus or DESFire"
    if type == MIFARE-UL: return "MIFARE Ultralight or Ultralight C"
    unreachable
