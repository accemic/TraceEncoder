#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Red cross-checks for the eTIP slot bound (P-SLOT-1).
#
# Two directions, because a bound property can fail in two ways:
#
#   R-TIGHT  the committed bound must be the MINIMUM. Shrinking ETIP_PAR_MSG
#            by exactly one slot must make a_p4_slot_bound fire. If it did
#            not, the formula would be padded and the "proof" would say
#            nothing about the real demand. The shrink happens on the
#            GENERATED model (SLOT_MINUS1=1), so this check never carries a
#            second copy of the formula.
#   R-EXCL   the slot-sharing argument must be alive. Removing the exclusion
#            `Cmd != ACT_CAP_ST_WATCHPOINT` from the DAQ arm lets one beat
#            raise a watchpoint AND a DAQ slot -- exactly the coupling that
#            lets CT_EN_WATCHPOINT_MSG cost +0 slots. With the exclusion gone
#            the bound must break.
#
# BOTH run in the `f_slots1` top (SPLIT_DATA_ACCESS = 1), and that is not a
# detail: the package constant has to cover BOTH settings of a module
# parameter it cannot see, so in the shipped SPLIT_DATA_ACCESS = 0 build it
# carries exactly one slot of deliberate margin (proven: with that setting a
# bound of 8 also passes k-induction, the formula gives 9). A tightness check
# in the margin-carrying configuration is vacuous -- measured, not assumed:
# both mutations came back GREEN on `bmc0` before this was corrected.
#
# Both are expected RED. A green run here is a gate failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red=0
report=()

run_red () { # $1 label, $2.. command
	local label="$1"; shift
	echo "########## RED $label"
	if "$@" ; then
		report+=("GREEN $label  <-- MUST BE RED")
		red=1
	else
		report+=("RED   $label")
	fi
}

run_red "R-TIGHT (bound shrunk by one slot, SPLIT_DATA_ACCESS=1)" \
	env SLOT_MINUS1=1 bash "$SCRIPT_DIR/run.sh" bmc1

run_red "R-EXCL (DAQ arm no longer excludes ACT_CAP_ST_WATCHPOINT)" \
	env MUTATE='s/\s*&& \(act_cap_st\.cmd\.Cmd\.value != ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_WATCHPOINT\)//' \
	bash "$SCRIPT_DIR/run.sh" bmc1

printf '%s\n' "${report[@]}"
if [ "$red" -ne 0 ]; then
	echo "RED MUTATION CROSS-CHECKS FAILED (a mutation stayed green)"
	exit 1
fi
echo "RED MUTATION CROSS-CHECKS OK (2/2 red where they must be)."
