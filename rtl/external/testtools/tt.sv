// SPDX-FileCopyrightText: 2018 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 */

/**
 * @brief     Helper functions to write testbenches
 *
 * @attention May only be used in simulation code, since not synthesizable.
 *            Synthesis will fail when using functions, since string data type is not supported by synthesis tools.
 *
 * @details   To create a new test:
 *
 *            tt::tt_testcase tc = tt::create_testcase("Overflow Test");
 *
 *            tc.tt_assert(overflow, "Overflow should happen");
 *            tc.tt_assert_eq_int(result, 'x, "Result should not have any valid value");
 *
 *            final tt::tt_evaluate(); // Make sure your Testbench gets terminated with a $finish call
 *
 * @author  Albert Schulz <aschulz@accemic.com>
 * @author  Thomas B. Preußer <tpreusser@accemic.com>
 */
package tt;

	/// Different printing styles for integer variables
	typedef enum {
		DEC,
		HEX
	} print_style_t;

	/// Testcase - identified by its name - on which multiple assertions can be validated
	class tt_testcase;

		/// Name of the Testcase
		string name;

		// Stop on error
		bit stop_on_error = 0;

		// Total number of failed assertions
		int failed_assertions = 0;

		// Total number of checked assertions
		int checked_assertions = 0;

		// Array containing errors occured during test run
		string errors[$];

		/// Create a new Testcase with a `name`
		function new(string name);
			this.name = name;
		endfunction

		function void tt_stop_on_error(input bit stop = 1);
			stop_on_error = stop;
		endfunction

		// Plain assertion with statistics update
		function bit tt_assert0(input bit cond);
			checked_assertions++;
			if(!cond)   failed_assertions++;
			return  cond;
		endfunction : tt_assert0

		// Enqueue an error message (without statistics update)
		function void tt_error0(input string msg);
			errors.push_back(msg);
			$error(msg);
			if(stop_on_error)   $stop;
		endfunction : tt_error0

		function bit tt_assert_eq_int(input longint value, input longint expected, input string msg, input print_style_t print_style = DEC);
			automatic bit cond = tt_assert0(value === expected);
			if(!cond) begin
				automatic string fmt;
				if (print_style == HEX) fmt = "Assertion failed. Expected 0x%0h, but got 0x%0h. Message: %s";
				else                    fmt = "Assertion failed. Expected %0d, but got %0d. Message: %s";

				tt_error0($sformatf(fmt, expected, value, msg));
			end
			return  cond;
		endfunction

		// Greater than or equal
		function bit tt_assert_gte_int(input longint value, input longint expected, input string msg, input print_style_t print_style = DEC);
			automatic bit cond = tt_assert0(value >= expected);
			if(!cond) begin
				automatic string fmt;
				if (print_style == HEX) fmt = "Assertion failed. Expected min. 0x%0h, but got 0x%0h. Message: %s";
				else                    fmt = "Assertion failed. Expected min. %0d, but got %0d. Message: %s";

				tt_error0($sformatf(fmt, expected, value, msg));
			end
			return  cond;
		endfunction


		/// Assert a string value (case sensitive)
		function bit tt_assert_eq_str(input string value, input string expected, input string msg);
			automatic bit cond = tt_assert0(value == expected);
			if(!cond)   tt_error0($sformatf("Assertion failed. Expected %p, but got %p. Message: %s", expected, value, msg));
			return  cond;
		endfunction

		function bit tt_assert_neq_int(input integer value, input integer forbidden, input string msg);
			automatic bit cond = tt_assert0(value !== forbidden);
			if(!cond)   tt_error0($sformatf("Assertion failed. Forbade %p, but got %p. Message: %s", forbidden, value, msg));
			return  cond;
		endfunction

		// Assert condition & display message on failure
		function bit tt_assert(input bit cond, input string msg);
			void'(tt_assert0(cond));
			if(!cond)   tt_error0(msg);
			return  cond;
		endfunction

		// Throw simulation error with message
		function void tt_error(input string msg);
			void'(tt_assert0(0));
			tt_error0(msg);
		endfunction

	endclass : tt_testcase

	localparam SHOW_DEBUG_MESSAGES = 0;

	localparam string DELIMITER = "-----------------------------------------------------------------------------------------------";

	tt_testcase global_context = new("Global Testset");

	tt_testcase testcases [$] = '{ global_context };

	function void register_testcase(tt_testcase t);
		testcases.push_back(t);
	endfunction

	function tt_testcase create_testcase(string name);
		automatic tt_testcase tc = new(name);
		register_testcase(tc);
		return tc;
	endfunction

	function void tt_stop_on_error(input bit stop = 1);
		global_context.tt_stop_on_error(stop);
	endfunction

	function bit tt_assert0(input bit cond);
		return  global_context.tt_assert0(cond);
	endfunction : tt_assert0

	function void tt_error0(input string msg);
		global_context.tt_error0(msg);
	endfunction : tt_error0

	function int tt_assert (input bit condition, input string msg);
		return global_context.tt_assert(condition, msg);
	endfunction

	function int tt_assert_eq_int (input longint value, input longint expected, input string msg, input print_style_t print_style = DEC);
		return global_context.tt_assert_eq_int(value, expected, msg, print_style);
	endfunction

	function int tt_assert_gte_int (input longint value, input longint expected, input string msg, input print_style_t print_style = DEC);
		return global_context.tt_assert_gte_int(value, expected, msg, print_style);
	endfunction

	/// Assert a string value (case sensitive)
	function int tt_assert_eq_str (input string value, input string expected, input string msg);
		return global_context.tt_assert_eq_str(value, expected, msg);
	endfunction

	function int tt_assert_neq_int (input integer value, input integer forbidden, input string msg);
		return global_context.tt_assert_neq_int(value, forbidden, msg);
	endfunction

	// Throw simulation error with message
	function void tt_error(input string msg);
		global_context.tt_error(msg);
	endfunction

	task debug (input string debug_msg);
		if (SHOW_DEBUG_MESSAGES) $display($sformatf("Debug: %s", debug_msg));
	endtask

	// Evaluate success of testbench
	function void tt_evaluate();
		automatic bit testbench_succeeded = '1;
		automatic int overall_checked_assertions = 0;

		$display(DELIMITER);

		foreach (testcases[i]) begin
			automatic tt_testcase tc = testcases[i];

			overall_checked_assertions += tc.checked_assertions;

			if (tc.errors.size() == 0) begin
				$display("Testcase: %s passed. Checked %0d assertions.", tc.name, tc.checked_assertions);
			end
			else begin
				testbench_succeeded = '0;
				$display("Testcase: %s failed:", tc.name);
				foreach (tc.errors[i]) $display($sformatf("    Error: %s", tc.errors[i]));
			end
		end

		$display(DELIMITER);

		if (overall_checked_assertions == 0) $display("Warning: No assertion has been checked. Testbench seems to be empty.");

		if (testbench_succeeded) $display("Info: Testbench passed.");
		else $display("Error: Testbench failed.");

		$display(DELIMITER);

	endfunction : tt_evaluate

endpackage : tt
