# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Shared environment setup for the CTTE developer scripts.
#
# Source it near the top of a script (it is not executable on its own):
#
#     . "$(cd "$(dirname "$0")/.." && pwd)/scripts/ct_env.sh"
#
# Everything it resolves can be overridden from the environment, so the
# scripts stay usable on a machine whose tool layout differs from the
# reference one. Nothing here is machine-specific by default.
#
# Provides:
#   CT_ROOT            repository root (script-relative, so it also works
#                      when this tree is vendored inside a superproject
#                      without its own .git)
#   NEXRV              CTTD reference decoder for this platform (fetched: py scripts/fetch_cttd.py)
#   ct_need_nexrv      make sure that decoder RUNS and knows the switches
#                      this tree uses (a stock upstream NexRv does not; the pinned CTTD does)
#   ct_need_vivado     put the pinned Vivado bin/ on PATH (xsim/xvlog/xelab)
#   ct_need_verilator  make sure `verilator` runs (fixes VERILATOR_ROOT on
#                      Windows/MSYS2)
#   ct_need_verible    make sure `verible-verilog-lint` RUNS (a missing linter
#                      must never be reported as a lint verdict)
#   ct_need_python     make sure `python3` AND bare `python` run (heals the
#                      Microsoft Store stubs via bld/pyshim wrappers; also
#                      fixes `#!/usr/bin/env python3` shebang resolution)
#   ct_need_abc        make sure the abc-flow driver runs
#   ct_pyrdl           echo the pinned PeakRDL interpreter of THIS tree (or
#                      of the main checkout a linked worktree came from)
#   ct_need_prj TB     make sure the xsim project of testbench TB exists in
#                      THIS tree (generates it with abc if bld/ is empty)
#   ct_xsim LOG ARGS   run xsim and verify it REALLY ran (see below)
#   ct_xsim_ok LOG RC  the same verdict for callers that build the command
#                      line themselves
#   ct_die MSG         print MSG to stderr and exit CT_E_TOOL (78)
#
# Environment overrides:
#   CT_ROOT        repository root
#   CT_TREE        (not an override -- always this file's own tree, see below)
#   NEXRV          explicit path to the CTTD decoder (default: bin/cttd-<platform>)
#   CT_VIVADO_BIN  Vivado bin/ directory (skips auto-discovery)
#   CT_ABC_BIN     directory containing the abc-flow `abc` driver
#   CT_ABC_TIMEOUT seconds a bootstrap `abc -sim` may take (default 900)
#   VERILATOR_ROOT Verilator installation prefix

# ---------------------------------------------------------------- root ----
if [ -z "${CT_ROOT:-}" ]; then
	# ${BASH_SOURCE[0]} is this file, wherever the caller sourced it from.
	CT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export CT_ROOT

# CT_ROOT is EXPORTED and therefore inherited: a byte-neutrality gate sources
# this file in the main tree and then runs cli_* scripts inside a detached
# worktree, where CT_ROOT still names the main tree. That is fine for finding
# a decoder binary and wrong for anything that WRITES -- a bootstrap keyed on
# CT_ROOT would generate the project in the tree that is not under test.
# CT_TREE is therefore recomputed from this file's own location on every
# source and deliberately NOT exported.
CT_TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exit code for "the toolchain or the build tree could not be established".
# It is NOT a property failure: scripts/run_gates.sh reports it as TOOL, so a
# missing tool never reads as a broken encoder (and never as a pass either).
CT_E_TOOL=78

# ct_die is the OTHER half of that promise, and until 2026-08-12 it broke it:
# it exited 127, which scripts/run_gates.sh maps through its `*)` arm to
# `FAIL  <gate>` -- so the one case the TOOL slot was invented for, "Vivado /
# python / abc is not on this machine", was the one case that still read as a
# broken encoder. ct_need_prj returned 78 and ct_need_vivado exited 127; the
# difference was invisible to everyone but the summary. Both now say 78.
#
# ct_die EXITS, it does not return: ct_env.sh is SOURCED, so `ct_need_abc ||
# rc=78` in a caller never gets control. That is why the code has to be right
# here -- a caller cannot translate it afterwards.
ct_die() {
	echo "ct_env: $*" >&2
	exit "$CT_E_TOOL"
}

# --------------------------------------------------------------- NexRv ----
# The vendored reference decoder ships as a Linux ELF (bin/NexRv) and a
# Windows executable (bin/NexRv.exe). Pick the one this shell can run.
if [ -z "${NEXRV:-}" ]; then
	# Preference order: the fetched CTTD build for THIS machine (incl. the
	# aarch64 leg a KV260 board runs -- the old two-way case could not
	# resolve it), then the legacy committed NexRv names. fetch_cttd.py
	# populates bin/ from the pinned dist assets; the legacy fallback keeps
	# a tree that never ran the fetch working until AP3 removes bin/ from git.
	case "$(uname -s)-$(uname -m)" in
		MINGW*|MSYS*|CYGWIN*)   _cttd="cttd-windows-x64.exe"; _legacy="NexRv.exe" ;;
		Linux-aarch64|Linux-arm64) _cttd="cttd-linux-arm64";  _legacy="NexRv-aarch64" ;;
		*)                       _cttd="cttd-linux-x86_64";   _legacy="NexRv" ;;
	esac
	for cand in "$CT_ROOT/bin/$_cttd" "$CT_ROOT/bin/$_legacy" \
	            "$CT_ROOT/bin/NexRv.exe" "$CT_ROOT/bin/NexRv"; do
		[ -f "$cand" ] && { NEXRV="$cand"; break; }
	done
	unset _cttd _legacy
	if [ -z "${NEXRV:-}" ] || [ ! -f "$NEXRV" ]; then
		echo "ct_env: no decoder in bin/ -- run: py scripts/fetch_cttd.py" >&2
		NEXRV="$CT_ROOT/bin/cttd-missing"   # a named, wrong path beats an empty one in errors
	fi
fi
export NEXRV

# The block above only *picks* a path. Until 2026-08-13 nothing verified it:
# 48 scripts execute "$NEXRV" and exactly one host check ever tested
# even for the file's existence. Measured on this tree with a NEXRV that
# points nowhere:
#
#   cold tree  -> "[decode-pc] basic_tb: FAIL -- NexRv produced no pcout"
#                 rc=1, plus the hint "(often an undrained trace tail / no
#                 inst trace)" -- a red verdict that names the ENCODER
#   warm tree  -> "[decode-pc] basic_tb: PASS -- all 26 PCs match", rc=0,
#                 because the pcout of the PREVIOUS run is still on disk and
#                 nothing noticed that this run wrote nothing
#
# The second one is the reason this check is not cosmetic: a broken decoder
# does not merely lie about the encoder, on a warm tree it certifies it.
#
# The check is on FUNCTION, not existence. A NexRv that starts but does not
# know the switches this tree uses is exactly as broken as a missing one, and
# it fails LATER and less legibly (the fork added -decoe; a stock upstream
# binary dropped in here would run, print "Unkown option" -- and, measured,
# still exit 1, which several call sites read as "decode failed"). So the
# probe runs the binary and reads its usage banner.
CT_NEXRV_OPTS="-deco -decoe -dump -enco -pcinfo -pcout -full -bp -none -csstrict"

ct_need_nexrv() {
	local usage opt
	[ -n "${NEXRV:-}" ] || ct_die "NEXRV is empty -- set it to the CTTD reference decoder (py scripts/fetch_cttd.py)"
	# Memoised per resolved path: 48 gates source this file, and a stage-2
	# run sources it dozens of times. Keyed on the path so a caller that
	# overrides NEXRV (a caller that builds its own) is re-checked.
	[ "${CT_NEXRV_OK:-}" = "$NEXRV" ] && return 0
	[ -f "$NEXRV" ] || ct_die "reference decoder not found at $NEXRV -- run: py scripts/fetch_cttd.py (pinned CTTD, scripts/cttd.pin), or set NEXRV"

	# No-arg NexRv prints its usage and exits 1; that is the normal answer,
	# so the exit code is deliberately ignored and the TEXT is the verdict.
	# The `|| :` is not decoration: most callers run under `set -e`, where the
	# non-zero status of a command substitution kills the assignment and thus
	# the script. Measured 2026-08-13 without it: decode_and_check.sh exited 1
	# with an EMPTY log -- the probe had become the very defect it hunts.
	usage="$("$NEXRV" 2>&1 || :)"
	case "$usage" in
		*Usage:*) ;;
		*) ct_die "NexRv at $NEXRV does not run (no usage banner). First line: $(printf '%s' "$usage" | sed -n '1{s/[[:cntrl:]]//g;p;}')" ;;
	esac
	for opt in $CT_NEXRV_OPTS; do
		case "$usage" in
			*"$opt"*) ;;
			*) ct_die "NexRv at $NEXRV does not know $opt -- this tree needs the c-trace fork ($CT_NEXRV_OPTS)" ;;
		esac
	done

	CT_NEXRV_OK="$NEXRV"
	export CT_NEXRV_OK
	return 0
}

# -------------------------------------------------------------- Vivado ----
# The Vivado version is pinned in .abc.config (vivado_sim=...), the same
# value abc-flow uses, so scripts and build driver never disagree.
ct_vivado_version() {
	sed -n 's/^vivado_sim=\(.*\)$/\1/p' "$CT_ROOT/.abc.config" 2>/dev/null | head -1
}

# Report the version an xvlog on PATH belongs to, or nothing.
ct_xvlog_version() {
	command -v xvlog >/dev/null 2>&1 || return 1
	xvlog --version 2>/dev/null | sed -n 's/.*Vivado Simulator v\([0-9][0-9.]*\).*/\1/p' | head -1
}

ct_need_vivado() {
	local ver have dir
	ver="$(ct_vivado_version)"

	# An xvlog that is ALREADY on PATH is only good enough if it is the
	# pinned version. Accepting whatever the ambient PATH happens to offer is
	# exactly the encoder-vs-toolchain divergence this pin exists to prevent,
	# and it fails silently: a different simulator just produces different
	# results. CT_VIVADO_ANY=1 opts out for a deliberate cross-version run.
	have="$(ct_xvlog_version || true)"
	if [ -n "$have" ]; then
		case "$have" in
			"$ver"|"$ver".*) return 0 ;;
		esac
		if [ "${CT_VIVADO_ANY:-0}" = 1 ]; then
			echo "ct_env: using Vivado $have (pin is $ver, CT_VIVADO_ANY=1)" >&2
			return 0
		fi
	fi

	# Both installer layouts are in the field: Vivado <= 2025.x installs to
	# <root>/Vivado/<version>/bin, 2026.1 and later to <root>/<version>/Vivado/bin.
	for dir in \
		${CT_VIVADO_BIN:+"$CT_VIVADO_BIN"} \
		${XILINX_VIVADO:+"$XILINX_VIVADO/bin"} \
		${ver:+"/c/Xilinx/Vivado/$ver/bin"} \
		${ver:+"/c/Xilinx/$ver/Vivado/bin"} \
		${ver:+"/opt/Xilinx/Vivado/$ver/bin"} \
		${ver:+"/opt/Xilinx/$ver/Vivado/bin"} \
		${ver:+"/tools/Xilinx/Vivado/$ver/bin"} \
		${ver:+"/tools/Xilinx/$ver/Vivado/bin"}
	do
		if [ -x "$dir/xvlog" ] || [ -x "$dir/xvlog.bat" ]; then
			PATH="$dir:$PATH"
			export PATH
			return 0
		fi
	done

	if [ -n "$have" ]; then
		ct_die "Vivado $ver (pinned in .abc.config) not found; PATH offers $have. Set CT_VIVADO_BIN, or CT_VIVADO_ANY=1 to accept it."
	fi
	ct_die "Vivado ${ver:-(version unset in .abc.config)} not found -- put xvlog on PATH or set CT_VIVADO_BIN"
}

# ----------------------------------------------------------------- xsim ----
# xsim does NOT report a failed run through its exit code. A snapshot that
# the running simulator cannot start -- wrong Vivado version, missing DLL,
# no licence -- produces
#
#     ERROR: [Simtcl 6-50] Simulation engine failed to start: Simulation
#     exited with status code -1073741511.
#
# in the LOG and exits 0. Every `xsim ... && cp dump` in this tree therefore
# used to promote the PREVIOUS leg's artefact on such a failure, and the
# comparison downstream then reports a byte drift that is really a stale
# file. That cost a red byte-neutrality gate and half a day of hypotheses
# on 2026-08-05 (P7 finding R4); the P7 audit found the class open in every
# other xsim caller (finding B-2), so the check lives here, once.
#
# The verdict has a positive half too: a run that really executed reaches
# `$finish` -- true for 427 of the 428 xsim logs in this tree at the time of
# writing, the exception being the backup of exactly such a failed launch.
# Checking only for known error strings would miss a killed or crashed sim.
#
#   ct_xsim <log> <xsim args...>   # appends -log <log>, silences stdout
#   ct_xsim_ok <log> <rc>          # verdict only (caller ran xsim itself)
# Both return 0 on a healthy run and 1 otherwise, with the reason on stderr.
ct_xsim_ok() {
	local log="$1" rc="${2:-0}" hit
	if [ "$rc" -ne 0 ]; then
		echo "ct_env: xsim exited with $rc (log: $log)" >&2
		return 1
	fi
	if [ ! -f "$log" ]; then
		echo "ct_env: xsim wrote no log at all ($log) -- it did not run" >&2
		return 1
	fi
	hit="$(grep -aiE 'failed to start|ERROR: \[Simtcl|ERROR: \[Common 17-|Abnormal program termination' "$log" | head -3)"
	if [ -n "$hit" ]; then
		echo "ct_env: xsim did not start (log: $log):" >&2
		printf '  %s\n' "$hit" >&2
		return 1
	fi
	if ! grep -aq 'finish called at time' "$log"; then
		echo "ct_env: xsim never reached \$finish (log: $log) -- the run was" >&2
		echo "  cut short; any dump next to it belongs to an EARLIER leg" >&2
		tail -3 "$log" | sed 's/^/  /' >&2
		return 1
	fi
	# Two different failures now share this function, and they must not share
	# a diagnosis. Everything above means "the run did not happen or was cut
	# short"; the SVA channel means "the run DID happen and the design or the
	# testbench complained". Callers were written when only the first existed
	# and print things like "FAIL: xsim did not run" -- which would be a false
	# statement about a simulation that ran to $finish. Hence the explicit
	# note, and a distinct exit code (2) so a caller CAN tell them apart.
	# Found on 2026-08-09 in the first stage-2 battery after this check went
	# in: dfdrop and tesyncreq reported "xsim did not run" over a $fatal.
	if ! ct_no_sva_errors "$log"; then
		echo "ct_env: NOTE -- the simulation DID run and reached \$finish." >&2
		echo "  What failed is the SVA channel above, not the launch. Ignore any" >&2
		echo "  'xsim did not run' wording that follows." >&2
		return 2
	fi
	return 0
}

ct_xsim() {
	local log="$1"; shift
	local rc=0
	xsim "$@" -log "$log" >/dev/null 2>&1 || rc=$?
	ct_xsim_ok "$log" "$rc"
}

# ---------------------------------------------------------- SVA channel ----
# The RTL carries concurrent and immediate assertions (I1-I11) plus testbench
# self-checks. In simulation they fire as `$error` / `$fatal`, which xsim
# prints as a line starting with "Error:" or "Fatal:" -- and then exits 0.
# A gate that judges only its decode or its byte identity therefore cannot see
# an assertion that fires WITHOUT corrupting the stream. V1 counted it: of the
# 29 xsim-driving gates, four looked at that channel and 25 did not
# (verification-infrastructure inventory V1, §5.3a).
#
# The answer is one road, not 25 patches: the check hangs in ct_xsim_ok, so
# every ct_xsim caller has it, and a gate written tomorrow has it without
# knowing the rule. scripts/check_sva_channel.py makes the omission red for
# the callers that cannot use ct_xsim (xelab -R runs its own simulation).
#
#   ct_no_sva_errors <log> [<log>...]
#
# The expectation comes from CT_SVA_EXPECT (default 0) and is an EXACT count
# over all named logs, not a ceiling: a red-control leg that suddenly produces
# two errors instead of the one it was written for has changed, and silence
# about that would be the same blindness one level down. Both directions red.
#
# CT_SVA_EXPECT=off exists for legs whose error count is genuinely
# workload-dependent, or whose verdict is INVERTED (a red control, where the
# errors are the point). It has to be written at the call site, and
# scripts/check_sva_channel.py counts the occurrences -- a waiver nobody
# counts grows.
#
# WHICH log. For `xsim -log X`, X carries the simulation output. For
# `xelab ... -R`, it does NOT: xelab's own -log holds the elaboration
# transcript and the run it spawns writes `xsim.log` in the working
# directory. Three gates in this tree grepped the elaboration log for
# `Error:` and could therefore never see one (V2-F1); pass the log the RUN
# wrote, and if a leg is unsure, name both -- a log that does not exist is a
# failure here, not a silent pass.
# Two spellings, because two backends. xsim starts the line with "Error:" /
# "Fatal:"; Verilator writes "%Error: file:line: ..." (optionally behind a
# "[time] " prefix). A detector that knew only one of them would be blind on
# the other backend -- which is how this class got here in the first place.
CT_SVA_RE='(^[[:space:]]*(Error|Fatal):)|(%(Error|Fatal)([-:]|$))'

ct_sva_count() {
	local total=0 n f
	for f in "$@"; do
		n="$(grep -acE "$CT_SVA_RE" "$f" 2>/dev/null || true)"
		total=$(( total + ${n:-0} ))
	done
	echo "$total"
}

ct_no_sva_errors() {
	local exp="${CT_SVA_EXPECT:-0}" n f missing=0
	[ "$#" -gt 0 ] || { echo "ct_env: ct_no_sva_errors: no log named" >&2; return 1; }
	for f in "$@"; do
		[ -f "$f" ] || { echo "ct_env: ct_no_sva_errors: no log at $f" >&2; missing=1; }
	done
	[ "$missing" -eq 0 ] || return 1
	[ "$exp" = "off" ] && return 0
	n="$(ct_sva_count "$@")"
	[ "$n" -eq "$exp" ] && return 0
	if [ "$exp" -eq 0 ]; then
		echo "ct_env: SVA channel: $n \$error/\$fatal line(s) in $* " >&2
		echo "  (xsim exits 0 even on \$fatal -- only the log says so)" >&2
	else
		echo "ct_env: SVA channel: $n \$error/\$fatal line(s) in $*, expected exactly $exp" >&2
	fi
	grep -aE "$CT_SVA_RE" "$@" | head -5 | sed 's/^/  /' >&2
	return 1
}

# ----------------------------------------------------------- Verilator ----
# Windows/MSYS2: the Verilator binary reports its data directory as an
# MSYS-internal POSIX path (/ucrt64/share/verilator) that the Windows process
# itself cannot open, so it aborts with "Cannot find verilated_std.sv".
# Derive a native path from the binary location instead. Harmless elsewhere:
# on Linux the default already resolves. Best-effort and silent -- callers
# that REQUIRE verilator use ct_need_verilator, which also dies when it is
# absent; callers that only MIGHT use it (ct_need_abc, whose backend depends
# on .abc.config) just want the variable right if it is there.
ct_fix_verilator_root() {
	command -v verilator >/dev/null 2>&1 || return 1
	if [ -z "${VERILATOR_ROOT:-}" ]; then
		case "$(uname -s)" in
			MINGW*|MSYS*|CYGWIN*)
				local bindir root
				bindir="$(dirname "$(command -v verilator)")"
				root="$(cd "$bindir/../share/verilator" 2>/dev/null && pwd -W 2>/dev/null)"
				[ -n "$root" ] && { VERILATOR_ROOT="$root"; export VERILATOR_ROOT; }
				;;
		esac
	fi
	return 0
}

ct_need_verilator() {
	command -v verilator >/dev/null 2>&1 \
		|| ct_die "verilator not found on PATH"
	ct_fix_verilator_root
	return 0
}

# ------------------------------------------------------------- verible ----
# scripts/lint.sh ran verible-verilog-lint, took its exit code as the VERDICT
# and printed, measured on this host 2026-08-13:
#
#   scripts/lint.sh: line 62: verible-verilog-lint: command not found
#   [lint] FAIL -- verible-verilog-lint exited 127      rc=127
#
# A lint verdict about a lint that never ran, and 127 lands in the `*)` arm of
# every summary, i.e. FAIL. The exit code cannot carry the difference either:
# verible uses 1 for "violations found", so "the linter is missing" and "the
# sources are dirty" are only distinguishable BEFORE the run.
#
# Probed on FUNCTION (--version), not existence: verible-verilog-lint is
# distributed as a single binary that people drop onto PATH by hand, and a
# half-extracted or wrong-arch drop is a present file that cannot lint.
#
# The verdict is the STATUS of --version, not its wording. The first version
# of this probe matched the banner text for "verible" and was fooled by a
# dummy whose LOADER ERROR read "verible-verilog-lint: error while loading
# shared libraries: ..." -- the failure message contains the tool's own name,
# so a text match cannot separate "ran" from "could not start" (measured
# 2026-08-13, probe L5: the run reached the linter and came back 127). A
# healthy verible answers --version with 0; a binary that cannot load, or is
# not verible at all, does not.
ct_need_verible() {
	local out vrc=0
	command -v verible-verilog-lint >/dev/null 2>&1 \
		|| ct_die "verible-verilog-lint not found on PATH -- install it (https://github.com/chipsalliance/verible/releases) or set PATH; NOT a lint failure"
	# `|| vrc=$?` also shields the assignment from `set -e`, the trap
	# documented at ct_need_nexrv.
	out="$(verible-verilog-lint --version 2>&1)" || vrc=$?
	[ "$vrc" -eq 0 ] || ct_die "verible-verilog-lint at $(command -v verible-verilog-lint) does not run (--version exited $vrc). First line: $(printf '%s' "$out" | sed -n '1{s/[[:cntrl:]]//g;p;}')"
	[ -n "$out" ] || ct_die "verible-verilog-lint at $(command -v verible-verilog-lint) answered --version with no output -- not a verible build"
	return 0
}

# -------------------------------------------------------------- Python ----
# The abc-flow driver and several gate scripts are Python consumers, under
# THREE different spellings: `python3`, bare `python` (both used by cli_*
# scripts) and the `#!/usr/bin/env python3` shebang of the abc driver. On
# Windows, either name on PATH is often the Microsoft Store stub, which
# prints an installation hint instead of running anything; on Linux, bare
# `python` may not exist at all. ct_need_python makes ALL three spellings
# work: if any of them is broken it resolves one real interpreter
# (CT_PYTHON_BIN > whichever PATH name already works > the `py` launcher >
# the default Windows install dirs), writes `python`/`python3` wrapper shims
# into bld/pyshim/ and prepends that directory to PATH. bld/ is disposable;
# the shims are recreated on demand.

# True if launcher $1 runs a real interpreter (the Store stub exits non-zero).
ct_python_ok() {
	"$1" -c "" >/dev/null 2>&1
}

ct_need_python() {
	ct_python_ok python3 && ct_python_ok python && return 0

	# Resolve one real interpreter to back the shims.
	local real="" cand
	for cand in ${CT_PYTHON_BIN:+"$CT_PYTHON_BIN/python.exe"} \
	            ${CT_PYTHON_BIN:+"$CT_PYTHON_BIN/python3"} \
	            python3 python py \
	            "${LOCALAPPDATA:-}/Programs/Python/Python313/python.exe" \
	            "${LOCALAPPDATA:-}/Programs/Python/Python312/python.exe"
	do
		case "$cand" in
			# Bare names resolve to their absolute path -- the shim sits FIRST
			# on PATH afterwards, so a bare name in the wrapper would recurse.
			python3|python|py)
				cand="$(command -v "$cand" 2>/dev/null)" || continue
				[ -n "$cand" ] || continue ;;
			*)	[ -x "$cand" ] || continue ;;
		esac
		ct_python_ok "$cand" && { real="$cand"; break; }
	done
	[ -n "$real" ] || ct_die "no working python -- put one on PATH or set CT_PYTHON_BIN"
	# Windows-style paths confuse the sh wrappers -- normalise when possible.
	case "$real" in
		*\\*|[A-Za-z]:*) command -v cygpath >/dev/null 2>&1 && real="$(cygpath -u "$real")" ;;
	esac

	# Shim directory: both names wrap the real interpreter, healing direct
	# calls AND env-shebang resolution in one place.
	local shim="$CT_ROOT/bld/pyshim"
	mkdir -p "$shim" || ct_die "cannot create $shim"
	printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$shim/python"  || ct_die "cannot write $shim/python"
	printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$shim/python3" || ct_die "cannot write $shim/python3"
	chmod +x "$shim/python" "$shim/python3"
	PATH="$shim:$PATH"
	export PATH

	ct_python_ok python3 && ct_python_ok python && return 0
	ct_die "python shim at $shim does not run -- check CT_PYTHON_BIN"
}

# ------------------------------------------------------------- abc-flow ----
# The simulation backend abc will pick for `-sim` unless a caller overrides it
# on the command line: the sim_backend key of .abc.config, or abc's own
# default (vivado) when the key is absent.
# The PeakRDL venv is gitignored, so its layout is a property of the MACHINE,
# not of the repository: `.venv-rdl-win/Scripts/python.exe` on Windows,
# `.venv-rdl/bin/python` on Linux. Eleven campaign scripts used to hardcode
# only the Windows spelling -- six with no fallback at all, and two with a
# fallback line that re-assigned the SAME path (a copy-paste that made the
# guard a no-op). On Linux they all died on a missing interpreter that the
# tree had built correctly under the other name.
#
# One resolver instead, with the same search order as scripts/gen_rdl.sh, and
# the same worktree rule as cli_etrace_test.sh: a linked worktree has no venv
# of its own, so fall back to the main checkout it was created from (read
# only). Override with CT_PYRDL.
#   usage: PYRDL="$(ct_pyrdl)" || ct_die "..."
ct_pyrdl() {
	if [ -n "${CT_PYRDL:-}" ]; then echo "$CT_PYRDL"; return 0; fi
	local root p main
	main="$(cd "$(dirname "$(git -C "$CT_TREE" rev-parse --git-common-dir 2>/dev/null)")" 2>/dev/null && pwd)" || main=""
	for root in "$CT_TREE" ${main:+"$main"}; do
		for p in "$root/.venv-rdl-win/Scripts/python.exe" \
		         "$root/.venv-rdl/Scripts/python.exe" \
		         "$root/.venv-rdl/bin/python"; do
			if [ -x "$p" ]; then echo "$p"; return 0; fi
		done
	done
	return 1
}

ct_abc_backend() {
	local b
	b="$(sed -n 's/^sim_backend=\(.*\)$/\1/p' "$CT_TREE/.abc.config" 2>/dev/null | head -1)"
	echo "${b:-vivado}"
}

ct_need_abc() {
	ct_need_python
	# The committed backend is `verilator` (the Vivado-free route for
	# `make sim` and the coverage runs). On Windows that binary needs
	# VERILATOR_ROOT repaired before it can find its own std package --
	# without this an `abc -sim` with the committed configuration dies in
	# "Cannot find verilated_std.sv", which reads like a broken repository
	# and is a broken environment variable (measured 2026-08-06: the very
	# same call succeeds once the variable is set).
	[ "$(ct_abc_backend)" = verilator ] && ct_fix_verilator_root
	command -v abc >/dev/null 2>&1 && return 0
	if [ -n "${CT_ABC_BIN:-}" ] && [ -x "$CT_ABC_BIN/abc" ]; then
		PATH="$CT_ABC_BIN:$PATH"
		export PATH
		return 0
	fi
	ct_die "abc-flow driver not found — put abc on PATH or set CT_ABC_BIN (https://github.com/accemic/abc-flow)"
}

# ------------------------------------------------- xsim project bootstrap ----
# Every cli_*_test.sh gate drives xvlog/xelab/xsim by hand over an xsim
# project that `abc` generates below bld/. bld/ is GITIGNORED, so a fresh
# clone or a fresh `git worktree add` has none, and the gates then reported
#
#     FAIL: donor prj missing (<path>)          (17 scripts)
#     FAIL: no prj at <path>                    (2 scripts)
#
# and the byte-neutrality gates on top of them summarised that as
# "BYTE NEUTRALITY: DRIFT / OVERALL: FAIL" -- a red verdict about an encoder
# that was never built, on a tree where nothing had drifted (P4 closing audit
# B-2/B-3). A gate that fails where nothing failed devalues itself, so the
# bootstrap happens here, once, instead of in nineteen error messages.
#
#   ct_need_prj <testbench> [<abc-file>]
#                             -> 0 when the project is there (or was built)
#                                CT_E_TOOL (78) when it could not be built
#
# Only the three projects the gates CLONE are registered below; every other
# gate testbench is a sed-substituted copy of one of them (`src_tb=` in the
# gates). Callers with their own project map (scripts/cli_sim.sh) pass the
# .abc path as the second argument.
ct_abc_project() {
	case "$1" in
		implicit_return_tb)  echo "tests/instruction/06_implicit_return/implicit_return_tb.abc" ;;
		repeated_history_tb) echo "tests/instruction/07_repeated_history/repeated_history_tb.abc" ;;
		overrun_recovery_tb) echo "tests/overflow/01_overrun_recovery/overrun_recovery_tb.abc" ;;
		*) return 1 ;;
	esac
}

ct_prj_path() {
	echo "$CT_TREE/bld/$1.abc.vivado/$1.abc.sim/sim_1/behav/xsim/$1_vlog.prj"
}

# True (0) when the xsim project at $1 has to be (re)built: it is missing, or
# an .abc file is newer than it. A project pins the FILE LIST, not the file
# contents -- xvlog recompiles every source it names on each run -- so only an
# added or removed source makes it wrong, and the file list can only change
# through an .abc. This is not a theoretical case: the main checkout carried a
# project from before P8 added rtl/pkg/ct_sync_req_pacer.sv to the dependency
# set, and every gate built from it died in
#     ERROR: [VRFC 10-2063] Module <ct_sync_req_pacer> not found
# which reads like broken RTL and is a cached file list. The gates that CLONE
# a donor project need the same test, or the refreshed donor never reaches
# them. CT_PRJ_REFRESH=1 (`make bld-refresh`) forces it regardless.
ct_prj_stale() {
	local prj="$1" newer
	[ "${CT_PRJ_REFRESH:-0}" = 1 ] && return 0
	[ -f "$prj" ] || return 0
	newer="$(find "$CT_TREE/rtl" "$CT_TREE/tests" -name '*.abc' -newer "$prj" -print 2>/dev/null | head -1)"
	[ -n "$newer" ] || return 1
	echo "ct_env: $(basename "$prj") is older than ${newer#$CT_TREE/} --"
	echo "  the file list may have changed, regenerating"
	return 0
}

ct_need_prj() {
	local tb="$1" prj proj log rc=0
	prj="$(ct_prj_path "$tb")"
	if ct_prj_stale "$prj"; then rm -f "$prj"; else return 0; fi

	proj="${2:-}"
	if [ -z "$proj" ] && ! proj="$(ct_abc_project "$tb")"; then
		echo "ct_env: no .abc project registered for testbench '$tb'" >&2
		echo "  pass its .abc path as the second argument, or add it to" >&2
		echo "  ct_abc_project() in scripts/ct_env.sh" >&2
		return "$CT_E_TOOL"
	fi
	if [ ! -f "$CT_TREE/$proj" ]; then
		echo "ct_env: $proj is missing from this tree" >&2
		return "$CT_E_TOOL"
	fi
	ct_need_abc || return "$CT_E_TOOL"

	log="$CT_TREE/bld/abc_bootstrap_$tb.log"
	if [ "${CT_PRJ_REFRESH:-0}" = 1 ]; then
		echo "ct_env: REFRESH -- regenerating the xsim project for $tb"
		echo "  (CT_PRJ_REFRESH=1; use it when a source was added to or removed"
		echo "  from the project). Log: $log"
	else
		echo "ct_env: BOOTSTRAP -- bld/ carries no xsim project for $tb (it is"
		echo "  gitignored, so a fresh clone or worktree has none). Generating it"
		echo "  with abc; this takes about a minute. Log: $log"
	fi
	mkdir -p "$CT_TREE/bld" || { echo "ct_env: cannot create $CT_TREE/bld" >&2; return "$CT_E_TOOL"; }

	# --sim-backend vivado, explicitly: the committed sim_backend is
	# `verilator`, which is right for `make sim` on a Vivado-free host but
	# never writes an xsim project -- and an xsim project is precisely what
	# the caller is asking for. Overriding it on the command line keeps the
	# repository default correct for both users.
	#
	# GIT_DIR/GIT_WORK_TREE: abc resolves its @DIR imports relative to
	# `git rev-parse --show-toplevel`, which points at the SUPER repository
	# when CTTE is vendored into one (and at the main checkout, not the
	# worktree, for a linked worktree).
	#
	# The run is EXPECTED to end in
	#     ERROR: [Common 17-180] Spawn failed: Broken pipe
	# on Windows -- Vivado's launch_simulation cannot spawn its own
	# compile.bat from this shell. Project generation is complete before
	# that step (the .prj is written first, and the compile.bat Vivado
	# could not spawn runs fine when started directly), so the verdict is
	# the presence of the .prj, never abc's exit code.
	( cd "$CT_TREE/bld" \
	  && GIT_DIR="$(git -C "$CT_TREE" rev-parse --absolute-git-dir 2>/dev/null)" \
	     GIT_WORK_TREE="$CT_TREE" \
	     timeout "${CT_ABC_TIMEOUT:-900}" abc --sim-backend vivado -sim "../$proj" \
	) > "$log" 2>&1 || rc=$?

	if [ -f "$prj" ]; then
		echo "ct_env: bootstrap ok -- $(basename "$prj") ($([ "$rc" -eq 0 ] && echo "abc rc=0" || echo "abc rc=$rc, expected"))"
		return 0
	fi
	echo "ct_env: BOOTSTRAP FAILED -- abc did not write $prj (rc=$rc)." >&2
	echo "  This is a TOOLCHAIN problem, not a test failure. Last lines:" >&2
	tail -5 "$log" 2>/dev/null | sed 's/^/    /' >&2
	return "$CT_E_TOOL"
}
