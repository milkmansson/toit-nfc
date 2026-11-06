// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .reader show Target

/**
ISO/IEC 14443-4 ("ISO-DEP") transport: RATS/ATS, and the I-block/R-block/
  S-block framing (chaining, time-extension, deselection) ISO 14443-4
  uses to exchange application data with any compliant card — MIFARE
  DESFire, NTAG 424 DNA, and JavaCards all sit on top of this, the same
  way `toit-mifare-classic` and `toit-mifare-ultralight` sit directly on
  $Target.

This is a shared, card-family-agnostic piece (like `Frame` and CRC-A),
  not specific to any one card — hence living in `toit-nfc` rather than
  in a card-family package.

Needs only plain $Target.transceive, not raw-frame access: RATS and the
  I-block exchange are standard framed command/response pairs with their
  own CRC, same as any other ISO 14443-3 command, so this works over any
  reader, PN532 included.

Protocol and Parameter Selection (PPS) — which would negotiate a faster
  bit rate after RATS — is still not implemented, and deliberately so:
  it would have nothing to do. PPS only matters if the underlying reader
  driver can actually switch the PICC's communication speed, and neither
  `toit-mfrc522` nor `toit-pn53x` exposes that yet, so negotiating a
  faster rate here would just be protocol-level theater with no way to
  act on it. Worth revisiting once a driver supports changing bit rate.

A failed exchange (a timeout, or a corrupted/CRC-failing reply) is now
  retried up to a few times by resending the exact same block, rather
  than immediately throwing — see $send-and-wait-out-wtx_ for why this
  is a simplification of the standard's own recovery (which would
  distinguish the two failure cases and use an R-block in one of them)
  rather than a full implementation of it.
*/
class IsoDepCard implements Target:
  static RATS_ ::= 0xE0
  static MAX-RETRIES_ ::= 3

  // PCB (Protocol Control Byte) bit layout, cross-checked against a real
  // captured R-block (PCB 0xBA: NAK, CID-following, block 0) and I-block
  // (PCB 0x0A: CID-following, block 0) rather than taken from memory
  // alone.
  static PCB-I-BLOCK-BASE_ ::= 0x02
  static PCB-CHAINING_ ::= 0x10
  static PCB-CID-PRESENT_ ::= 0x08
  static PCB-NAD-PRESENT_ ::= 0x04
  static PCB-BLOCK-NUMBER_ ::= 0x01
  static PCB-R-BLOCK-ACK_ ::= 0xA2
  static PCB-R-BLOCK-NAK_ ::= 0xB2
  static PCB-S-BLOCK-DESELECT_ ::= 0xC2
  static PCB-S-BLOCK-WTX_ ::= 0xF2
  static PCB-TYPE-MASK_ ::= 0xC0
  static PCB-TYPE-I-BLOCK_ ::= 0x00
  static PCB-TYPE-R-BLOCK_ ::= 0x80
  static PCB-TYPE-S-BLOCK_ ::= 0xC0

  // FSCI -> FSC (max frame size, in bytes) table, from ISO 14443-3/4.
  // FSCI values 9-15 are RFU; treated as the largest defined size.
  static FSCI-TO-FSC_ ::= {
    0: 16, 1: 24, 2: 32, 3: 40, 4: 48, 5: 64, 6: 96, 7: 128, 8: 256,
  }

  target_/Target
  cid_/int?
  send-block-number_/int := 0
  receive-block-number_/int := 0

  /** Max frame size the card can receive, from ATS's TA1 (FSCI). Defaults to 32 (FSCI=2) if TA1 is absent. */
  fsc/int := 32

  /**
  Frame Waiting Time, in microseconds, from ATS's TB1 (FWI). Defaults to
    the standard's own default of FWI=4 (≈4833 µs) if TB1 is absent.

  Informational only: this layer doesn't actively enforce it, since
    $Target.transceive's own timeout is set by the underlying reader
    driver, not by this class.
  */
  frame-waiting-time-us/int := 4833

  /** Whether the card's ATS (TC1) declared NAD support. */
  supports-nad/bool := false
  /** Whether the card's ATS (TC1) declared CID support. */
  supports-cid/bool := false
  /** The historical bytes from ATS, if any (0-15 bytes, meaning not defined by ISO 14443-4). */
  historical-bytes/ByteArray := #[]

  /**
  Activates ISO-DEP on the given target by sending RATS, and parses the
    card's ATS response.

  $cid (Card ID) is only meaningful when multiple ISO-DEP cards are
    active at once; leave it null for the common single-card case.
  */
  constructor .target_ --cid/int?=null:
    cid_ = cid
    rats_

  uid -> ByteArray: return target_.uid
  type -> int: return target_.type

  /** Deselects (if still active) and closes the underlying $Target. */
  close -> none:
    catch: deselect
    target_.close

  /** Sends an S(DESELECT) request, ending the ISO-DEP session. */
  deselect -> none:
    target_.transceive (s-block_ PCB-S-BLOCK-DESELECT_) --check-crc

  rats_ -> none:
    command := #[RATS_, (cid_ or 0) & 0x0F]
    response := target_.transceive command --check-crc
    if not response or response.is-empty: throw "ISO_DEP_RATS_FAILED"

    tl := response[0]
    if tl != response.size: throw "ISO_DEP_INVALID_ATS"
    if tl == 1: return // TL-only ATS: every field stays at its default.

    t0 := response[1]
    fsci := t0 & 0x0F
    fsc = FSCI-TO-FSC_.contains fsci ? FSCI-TO-FSC_[fsci] : 256

    offset := 2
    if t0 & 0x10 != 0: offset += 1 // TA1 present; bit-rate options, not used here.
    if t0 & 0x20 != 0:
      tb1 := response[offset]
      fwi := (tb1 >> 4) & 0x0F
      frame-waiting-time-us = 302 * (1 << fwi)
      offset += 1
    if t0 & 0x40 != 0:
      tc1 := response[offset]
      supports-nad = tc1 & 0x01 != 0
      supports-cid = tc1 & 0x02 != 0
      offset += 1

    historical-bytes = response[offset ..]

  /**
  Exchanges one APDU (application-level command) with the card.

  Transparently splits $bytes into multiple I-blocks if it's wider than
    the card's $fsc, and reassembles a chained response back into a
    single byte array. Automatically replies to the card's S(WTX)
    time-extension requests by echoing them back, as the standard
    requires, without otherwise acting on the requested extension (see
    $frame-waiting-time-us).
  */
  transceive bytes/ByteArray --check-crc/bool=true -> ByteArray?:
    header-size := 1 + (cid_ ? 1 : 0)
    max-chunk := fsc - header-size

    offset := 0
    last-response/ByteArray? := null
    did-send-one := false
    while offset < bytes.size or not did-send-one:
      did-send-one = true
      remaining := bytes.size - offset
      chunk-size := min remaining max-chunk
      chaining := offset + chunk-size < bytes.size
      chunk := bytes[offset .. offset + chunk-size]

      response := send-and-wait-out-wtx_ (i-block_ chunk --chaining=chaining)
      offset += chunk-size

      if chaining:
        if (block-type_ response) != PCB-TYPE-R-BLOCK_: throw "ISO_DEP_UNEXPECTED_BLOCK"
        send-block-number_ ^= 1
      else:
        last-response = response

    send-block-number_ ^= 1

    result := #[]
    response := last-response
    while true:
      if (block-type_ response) != PCB-TYPE-I-BLOCK_: throw "ISO_DEP_UNEXPECTED_BLOCK"
      pcb := response[0]
      inf-offset := 1 + (pcb & PCB-CID-PRESENT_ != 0 ? 1 : 0) + (pcb & PCB-NAD-PRESENT_ != 0 ? 1 : 0)
      result += response[inf-offset ..]

      if pcb & PCB-CHAINING_ == 0: break
      receive-block-number_ ^= 1
      response = send-and-wait-out-wtx_ (r-block_ --nak=false)

    receive-block-number_ ^= 1
    return result

  /**
  Sends $frame and returns the card's eventual non-WTX response, throwing
    if there's none. Along the way, transparently echoes back any
    S(WTX) time-extension requests, as the standard requires.
  */
  send-and-wait-out-wtx_ frame/ByteArray -> ByteArray:
    outgoing := frame
    attempts := 0
    while true:
      response/ByteArray? := null
      exception := catch: response = target_.transceive outgoing --check-crc
      if exception or not response:
        // Treats a timeout (null response) and a corrupted/CRC-failing
        // response the same way: resend the exact same block and hope
        // the retry gets through. This is a simplification of the
        // standard's own recovery (which would distinguish "my command
        // never arrived" from "the reply got corrupted" and respond
        // with an R-block in the latter case) that this layer doesn't
        // implement, since it can't be meaningfully checked without
        // real hardware noise to provoke it.
        attempts += 1
        if attempts > MAX-RETRIES_: throw "ISO_DEP_NO_RESPONSE"
        continue
      attempts = 0
      if (block-type_ response) == PCB-TYPE-S-BLOCK_ and response[0] & 0x30 == 0x30:
        outgoing = response // Echo the WTX request back unchanged.
        continue
      return response

  block-type_ block/ByteArray -> int:
    return block[0] & PCB-TYPE-MASK_

  i-block_ inf/ByteArray --chaining/bool -> ByteArray:
    pcb := PCB-I-BLOCK-BASE_
    if chaining: pcb |= PCB-CHAINING_
    if cid_: pcb |= PCB-CID-PRESENT_
    pcb |= send-block-number_ & PCB-BLOCK-NUMBER_
    prefix := cid_ ? #[pcb, cid_] : #[pcb]
    return prefix + inf

  r-block_ --nak/bool -> ByteArray:
    pcb := nak ? PCB-R-BLOCK-NAK_ : PCB-R-BLOCK-ACK_
    if cid_: pcb |= PCB-CID-PRESENT_
    pcb |= receive-block-number_ & PCB-BLOCK-NUMBER_
    return cid_ ? #[pcb, cid_] : #[pcb]

  s-block_ base-pcb/int -> ByteArray:
    pcb := base-pcb
    if cid_: pcb |= PCB-CID-PRESENT_
    return cid_ ? #[pcb, cid_] : #[pcb]
