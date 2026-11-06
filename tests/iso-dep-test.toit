// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the TESTS_LICENSE file.

import expect show *
import nfc.reader show Target
import nfc.iso-dep show IsoDepCard

main:
  test-ats-defaults-with-tl-only-response
  test-ats-parses-ta1-tb1-tc1-and-historical-bytes
  test-simple-exchange
  test-outgoing-request-chaining
  test-incoming-response-chaining
  test-wtx-during-response
  test-deselect-on-close

test-ats-defaults-with-tl-only-response:
  fake := FakeIsoDepTarget
      --ats-response=#[0x01]
      --reply-chunk-size=32
  card := IsoDepCard fake
  expect-equals 32 card.fsc
  expect-equals 4833 card.frame-waiting-time-us
  expect-not card.supports-nad
  expect-not card.supports-cid
  expect-bytes-equal #[] card.historical-bytes

test-ats-parses-ta1-tb1-tc1-and-historical-bytes:
  // TL, T0 (FSCI=5 -> FSC=64; TA1/TB1/TC1 all present), TA1, TB1
  // (FWI=6, SFGI=2), TC1 (NAD+CID both supported), then 3 historical bytes.
  t0 := 0x75 // 0b0111_0101: TA1/TB1/TC1 present (bits 4-6), FSCI=5.
  ta1 := 0x00
  tb1 := (6 << 4) | 2
  tc1 := 0x03 // NAD (bit0) + CID (bit1).
  historical := #[0xAA, 0xBB, 0xCC]
  body := #[t0, ta1, tb1, tc1] + historical
  ats := #[1 + body.size] + body

  fake := FakeIsoDepTarget
      --ats-response=ats
      --reply-chunk-size=32
  card := IsoDepCard fake
  expect-equals 64 card.fsc
  expect-equals (302 * (1 << 6)) card.frame-waiting-time-us
  expect card.supports-nad
  expect card.supports-cid
  expect-bytes-equal historical card.historical-bytes

test-simple-exchange:
  request := #[0xDE, 0xAD, 0xBE, 0xEF]
  reply := #[0xCA, 0xFE]
  fake := FakeIsoDepTarget
      --ats-response=#[0x01]
      --reply-chunk-size=32
      --expected-request=request
      --reply-data=reply
  card := IsoDepCard fake
  expect-bytes-equal reply (card.transceive request)

  // A second, independent exchange on the same card must also work (the
  // block-number bit must have been toggled correctly, not left stuck).
  fake.expect-next request --reply=reply
  expect-bytes-equal reply (card.transceive request)

test-outgoing-request-chaining:
  // FSCI=0 -> FSC=16, so with a 1-byte header the PCD can only fit 15
  // INF bytes per I-block, forcing a 25-byte request to chain.
  ats := #[2, 0x00]
  request := ByteArray 25: it
  reply := #[0x90, 0x00]
  fake := FakeIsoDepTarget
      --ats-response=ats
      --reply-chunk-size=32
      --expected-request=request
      --reply-data=reply
  card := IsoDepCard fake
  expect-equals 16 card.fsc
  expect-bytes-equal reply (card.transceive request)

test-incoming-response-chaining:
  // A reply bigger than our own reply-chunk-size forces the PICC side
  // to chain, which the PCD must reassemble.
  request := #[0x01]
  reply := ByteArray 40: 0xA0 + (it % 16)
  fake := FakeIsoDepTarget
      --ats-response=#[0x01]
      --reply-chunk-size=12
      --expected-request=request
      --reply-data=reply
  card := IsoDepCard fake
  expect-bytes-equal reply (card.transceive request)

test-wtx-during-response:
  request := #[0x5A]
  reply := #[0x5B, 0x5C, 0x5D]
  fake := FakeIsoDepTarget
      --ats-response=#[0x01]
      --reply-chunk-size=32
      --expected-request=request
      --reply-data=reply
      --inject-wtx
  card := IsoDepCard fake
  expect-bytes-equal reply (card.transceive request)
  expect fake.wtx-was-echoed-back-unchanged

test-deselect-on-close:
  fake := FakeIsoDepTarget
      --ats-response=#[0x01]
      --reply-chunk-size=32
  card := IsoDepCard fake
  card.close
  expect fake.was-deselected

/**
Plays the PICC side of ISO 14443-4 (RATS/ATS, I-block chaining in both
  directions, S(WTX), S(DESELECT)), independently of $IsoDepCard's own
  logic, so $IsoDepCard can be checked by simulating both sides of the
  protocol with it — the same technique used elsewhere in this package
  family (eg. toit-mifare-classic's crypto1-test.toit).
*/
class FakeIsoDepTarget implements Target:
  ats-response_/ByteArray
  reply-chunk-size_/int
  inject-wtx_/bool
  expected-request_/ByteArray := #[]
  reply-data_/ByteArray := #[]

  rats-done_/bool := false
  accumulated-request_/ByteArray := #[]
  reply-offset_/int := 0
  send-block-number_/int := 0
  sent-wtx_/bool := false
  wtx-was-echoed-back-unchanged/bool := false
  was-deselected/bool := false

  constructor
      --ats-response/ByteArray
      --reply-chunk-size/int
      --inject-wtx/bool=false
      --expected-request/ByteArray=#[]
      --reply-data/ByteArray=#[]:
    ats-response_ = ats-response
    reply-chunk-size_ = reply-chunk-size
    inject-wtx_ = inject-wtx
    expected-request_ = expected-request
    reply-data_ = reply-data

  /** Resets this fake for a second, independent exchange on the same connection. */
  expect-next request/ByteArray --reply/ByteArray -> none:
    expected-request_ = request
    reply-data_ = reply
    accumulated-request_ = #[]
    reply-offset_ = 0
    sent-wtx_ = false

  uid -> ByteArray: return #[0x04, 0x00, 0x00, 0x00]
  type -> int: return 0
  close -> none:

  transceive bytes/ByteArray --check-crc/bool=false -> ByteArray?:
    if bytes.size == 2 and bytes[0] == 0xE0 and not rats-done_:
      rats-done_ = true
      return ats-response_

    pcb := bytes[0]
    block-type := pcb & 0xC0
    has-cid := pcb & 0x08 != 0
    inf-offset := 1 + (has-cid ? 1 : 0)

    if block-type == 0xC0: // S-block.
      selector := pcb & 0x30
      if selector == 0x30:
        // The PCD's echo of our WTX demand: now send the real reply.
        wtx-was-echoed-back-unchanged = true
        return send-next-reply-chunk_ has-cid
      was-deselected = true
      return bytes // DESELECT ack echoes the same PCB.

    if block-type == 0x80: // R-block: ack of our chained reply.
      return send-next-reply-chunk_ has-cid

    // I-block.
    chaining := pcb & 0x10 != 0
    inf := bytes[inf-offset ..]
    accumulated-request_ += inf

    if chaining:
      ack-pcb := 0xA2 | (has-cid ? 0x08 : 0) | (pcb & 0x01)
      return has-cid ? #[ack-pcb, bytes[1]] : #[ack-pcb]

    if accumulated-request_ != expected-request_: throw "UNEXPECTED_REQUEST"

    reply-offset_ = 0
    send-block-number_ = 0
    if inject-wtx_ and not sent-wtx_:
      sent-wtx_ = true
      return #[0xF2, 0x01]
    return send-next-reply-chunk_ has-cid

  send-next-reply-chunk_ has-cid/bool -> ByteArray:
    remaining := reply-data_.size - reply-offset_
    chunk-size := min remaining reply-chunk-size_
    chaining := reply-offset_ + chunk-size < reply-data_.size
    chunk := reply-data_[reply-offset_ .. reply-offset_ + chunk-size]
    reply-offset_ += chunk-size
    pcb := 0x02 | (chaining ? 0x10 : 0) | (has-cid ? 0x08 : 0) | send-block-number_
    send-block-number_ ^= 1
    return has-cid ? #[pcb, 0x00] + chunk : #[pcb] + chunk
