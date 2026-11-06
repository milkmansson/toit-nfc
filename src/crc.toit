// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import crypto.crc show crc-a
import .nfc-exception

export crc-a

/**
Checks that the last two bytes of $data are a correct CRC_A (as computed by
  $crc-a) over the preceding bytes.

Throws $NfcException.crc if the check fails.
*/
check-crc-a data/ByteArray -> none:
  if data.size < 3: throw NfcException.protocol
  crc := crc-a data[..data.size - 2]
  if crc & 0xFF != data[data.size - 2] or crc >> 8 != data[data.size - 1]:
    throw NfcException.crc
