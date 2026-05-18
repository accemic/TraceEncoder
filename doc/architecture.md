<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# Architecture

> **Stub.** Fill in as the RTL ports begin.

## Block diagram

<!-- TODO: insert images/block-diagram.svg -->

## Clock domains

<!-- TODO: list clock domains and their roles (tip_clk, proc_clk, atb_atclk, wb_clk, wall_clk). -->

## Top-level IO

<!-- TODO: table of top-level ports, including:
       - TIP (instruction-trace input from the core)
       - ATB / AXIS (encoded trace output)
       - Wishbone CSR
       - Reset / clock topology -->

## Pipeline stages

<!-- TODO: L1 funnel → L2/L3 preproc → message gen → formatter (ATB, AXIS). -->

## Parameters and feature switches

<!-- TODO: e.g. SPLIT_DATA_ACCESS, NUM_TRACE_FILTER, etc. -->
