<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# bin/ — the fetched decoder lives here

The reference decoder is **CTTD (CEDARtools.TraceDecoder)** and is no longer
committed. Get the pinned build:

    py scripts/fetch_cttd.py            # this host
    py scripts/fetch_cttd.py --all      # all three platforms (board deploys need linux-arm64)

The pin (version + sha256 per platform) is `scripts/cttd.pin`; a checksum
mismatch is a hard error, because every decode verdict in this repository is
worth exactly what the decoder is. CTTD's home is
[github.com/accemic/CTTD](https://github.com/accemic/CTTD); `base_url` in
the pin names where its release assets are fetched from. The pin-by-pin
behavioural record that used to fill this file lives in the git history of
this README and in CTTD's `CHANGELOG.md`.
