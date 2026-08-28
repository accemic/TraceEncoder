# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Session-local formal toolchain environment (SymbiYosys route).
# Deliberately NOT a global PATH change: source this from the per-target
# run.sh only. Override the install locations via environment variables
# when they differ from the workstation defaults:
#
#   OSS_CAD_SUITE  root of the YosysHQ OSS CAD Suite (yosys, sby, solvers)
#   SV2V_HOME      directory containing the sv2v binary
#
# The defaults below only cover the common install locations -- set the two
# variables when yours differ.
#
# Windows note: do NOT prepend /c/msys64/usr/bin here. Its coreutils mangle
# the environment across the Git-Bash / native-tool boundary.

# Defaults are TRIED IN ORDER, not assumed: the Linux install prefix first,
# then the Windows workstation layout. scripts/run_formal.sh already
# carried the Windows path in its stack-reserve guard while this file only
# knew /opt -- so the guard found a yosys the environment then refused to
# set up, and the run died in the first target with "yosys not found" after
# the guard had just reported OK on the very same binary.
ct_first_dir() {  # $1 = probe (relative), $2.. = candidate roots
	local probe="$1"; shift
	local d
	for d in "$@"; do
		[ -x "$d/$probe" ] || [ -x "$d/$probe.exe" ] && { echo "$d"; return 0; }
	done
	return 1
}

: "${OSS_CAD_SUITE:=$(ct_first_dir bin/yosys /opt/oss-cad-suite /d/tools/oss-cad-suite "$HOME/oss-cad-suite")}"
: "${SV2V_HOME:=$(ct_first_dir sv2v /opt/sv2v /d/tools/sv2v "$HOME/sv2v")}"

if [ ! -x "$OSS_CAD_SUITE/bin/yosys" ] && [ ! -x "$OSS_CAD_SUITE/bin/yosys.exe" ]; then
	echo "ERROR: yosys not found under OSS_CAD_SUITE=${OSS_CAD_SUITE:-<none of the defaults>}" >&2
	echo "       set OSS_CAD_SUITE to the root of your YosysHQ OSS CAD Suite" >&2
	return 1 2>/dev/null || exit 1
fi
if [ ! -x "$SV2V_HOME/sv2v" ] && [ ! -x "$SV2V_HOME/sv2v.exe" ]; then
	echo "ERROR: sv2v not found under SV2V_HOME=${SV2V_HOME:-<none of the defaults>}" >&2
	echo "       set SV2V_HOME to the directory containing the sv2v binary" >&2
	return 1 2>/dev/null || exit 1
fi

export PATH="$OSS_CAD_SUITE/bin:$OSS_CAD_SUITE/lib:$SV2V_HOME:$PATH"
# sby's bundled python (mirrors environment.bat of the suite). This is a
# WINDOWS path and it used to be exported unconditionally -- on Linux it named
# a file that does not exist, so anything honouring PYTHON_EXECUTABLE was
# pointed at nothing. Set it only when it is actually there; on Linux the
# suite's own bin/ is already ahead on PATH and sby finds its interpreter.
if [ -x "$OSS_CAD_SUITE/lib/python3.exe" ]; then
	export PYTHON_EXECUTABLE="$OSS_CAD_SUITE/lib/python3.exe"
fi
