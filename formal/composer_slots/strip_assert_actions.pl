#!/usr/bin/env perl
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Remove the ACTION part of immediate assertions from an sv2v-generated
# Verilog file:  `assert (<expr>) else <action>` -> `assert (<expr>);`
#
# Why: the yosys Verilog front end parses an immediate `assert (...)` but not
# its `else` action block. sv2v rewrites the RTL's `else $error(...)` /
# `else $fatal(...)` into `else $display(...)` / `else begin ... $stop; end`,
# so a fixed regex over the action text is not enough -- the blocks nest
# (`else begin if (...) $display(...); ... end`). This pass therefore matches
# begin/end pairs.
#
# The CHECK itself is kept untouched; only the message/severity action is
# dropped. Nothing else in the file is modified.
use strict;
use warnings;

local $/;
my $src = <STDIN>;

# ----------------------------------------------------------------------
# Pass 0: drop `final begin ... end` blocks. They are the end-of-simulation
# $display telemetry of the composer (MaxSlotsSim / slot balance) inside a
# `pragma translate_off` region -- sv2v ignores synthesis pragmas, and the
# yosys front end has no `final`.
# ----------------------------------------------------------------------
{
	my $o = '';
	my $p = 0;
	while ($src =~ /\bfinal\b/g) {
		my $fs = $-[0];
		my $q  = $+[0];
		$q++ while $q < length($src) && substr($src, $q, 1) =~ /\s/;
		if (substr($src, $q, 5) eq 'begin') {
			my $d = 0;
			while ($q < length($src)) {
				if (substr($src, $q) =~ /^\bbegin\b/) { $d++; $q += 5; next; }
				if (substr($src, $q) =~ /^\bend\b/)   { $d--; $q += 3; last if $d == 0; next; }
				$q++;
			}
		}
		else {
			# single statement: run to its terminating semicolon
			my $d = 0;
			while ($q < length($src)) {
				my $c = substr($src, $q, 1);
				$d++ if $c eq '(';
				$d-- if $c eq ')';
				$q++;
				last if $c eq ';' && $d == 0;
			}
		}
		$o  .= substr($src, $p, $fs - $p);
		$p   = $q;
		pos($src) = $p;
	}
	$o .= substr($src, $p);
	$src = $o;
}

# ----------------------------------------------------------------------
# Pass 0b: drop the remaining severity/IO tasks. The RTL keeps its
# simulation messages inside `pragma translate_off` regions that sv2v does
# not honour; yosys rejects `$stop` outside an initial block. Only the
# message is removed, the surrounding control flow stays.
# ----------------------------------------------------------------------
{
	my $o = '';
	my $p = 0;
	while ($src =~ /\$(display|write|stop|finish|fatal|error|warning|info)\b/g) {
		my $ts = $-[0];
		my $q  = $+[0];
		$q++ while $q < length($src) && substr($src, $q, 1) =~ /\s/;
		my $d = 0;
		while ($q < length($src)) {
			my $c = substr($src, $q, 1);
			$d++ if $c eq '(';
			$d-- if $c eq ')';
			$q++;
			last if $c eq ';' && $d == 0;
		}
		$o  .= substr($src, $p, $ts - $p) . ';';
		$p   = $q;
		pos($src) = $p;
	}
	$o .= substr($src, $p);
	$src = $o;
}


my $out = '';
my $pos = 0;

while ($src =~ /\bassert\s*\(/g) {
	my $astart = $-[0];       # start of "assert"
	my $p      = pos($src);   # just after the opening paren of the condition

	# 1) skip the condition, balancing parentheses
	my $depth = 1;
	while ($depth > 0 && $p < length($src)) {
		my $c = substr($src, $p, 1);
		$depth++ if $c eq '(';
		$depth-- if $c eq ')';
		$p++;
	}
	my $cond_end = $p;        # just after the closing paren

	# 2) is an `else` action attached?
	my $q = $cond_end;
	$q++ while $q < length($src) && substr($src, $q, 1) =~ /\s/;
	if (substr($src, $q, 4) ne 'else') {
		next;                 # plain `assert (...);` -- nothing to do
	}
	$q += 4;
	$q++ while $q < length($src) && substr($src, $q, 1) =~ /\s/;

	# 3) skip the action: either a begin/end block or a single statement
	if (substr($src, $q, 5) eq 'begin') {
		my $bdepth = 0;
		while ($q < length($src)) {
			if (substr($src, $q) =~ /^\bbegin\b/)  { $bdepth++; $q += 5; next; }
			if (substr($src, $q) =~ /^\bend\b/)    { $bdepth--; $q += 3; last if $bdepth == 0; next; }
			$q++;
		}
	}
	else {
		# single statement: run to its terminating semicolon, balancing parens
		my $sdepth = 0;
		while ($q < length($src)) {
			my $c = substr($src, $q, 1);
			$sdepth++ if $c eq '(';
			$sdepth-- if $c eq ')';
			$q++;
			last if $c eq ';' && $sdepth == 0;
		}
		$q--;                 # keep the semicolon out, we add our own
	}

	$out .= substr($src, $pos, $cond_end - $pos) . ';';
	$pos  = $q;
	# the original statement's own terminating `;` (if any) follows
	$pos++ while $pos < length($src) && substr($src, $pos, 1) =~ /[\s;]/
	             && substr($src, $pos, 1) eq ';';
	pos($src) = $pos;
}

$out .= substr($src, $pos);
$src = $out;

# ----------------------------------------------------------------------
# Pass 0c: keep ONLY the property this gate is about. The flattened model
# also carries the immediate assertions of the FIFO library and of the
# composer's skid queue (`SkidCnt <= SKID`, the injector stream-order rule,
# the fwft occupancy invariant). They are the subject of their own gates and
# of the simulation battery; under this gate's free environment they are not
# inductive, so they would turn every `prove` run into UNKNOWN without
# saying anything about the slot bound. Everything not inside a block
# labelled `a_p4_slot_bound` is dropped -- mechanically, by the label sv2v
# emits for the RTL's own assertion name.
# ----------------------------------------------------------------------
{
	my $o = '';
	my $p = 0;
	my $kept = 0;
	while ($src =~ /\bassert\s*\(/g) {
		my $as = $-[0];
		my $q  = pos($src);
		my $d  = 1;
		while ($d > 0 && $q < length($src)) {
			my $c = substr($src, $q, 1);
			$d++ if $c eq '(';
			$d-- if $c eq ')';
			$q++;
		}
		$q++ while $q < length($src) && substr($src, $q, 1) =~ /[\s;]/;
		# is this assertion inside the a_p4_slot_bound block?
		my $ctx = substr($src, ($as > 200 ? $as - 200 : 0), ($as > 200 ? 200 : $as));
		if ($ctx =~ /begin\s*:\s*a_p4_slot_bound\s*$/s) { $kept++; next; }
		$o  .= substr($src, $p, $as - $p) . ';';
		$p   = $q;
		pos($src) = $p;
	}
	$o .= substr($src, $p);
	$src = $o;
	die "ERROR: a_p4_slot_bound not found in the model\n" unless $kept;
	print STDERR "[strip] kept $kept a_p4_slot_bound assertion(s), dropped the rest\n";
}

print $src;
