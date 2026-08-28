// SPDX-FileCopyrightText: 2018-2024 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief    Provides math functions which may also be used in localparam definitions
 * @author   Albert Schulz <aschulz@accemic.com>
 *
 */

package math;

	/**
	 * @brief    Get the maximum value of two int values
	 * @author   Albert Schulz <aschulz@accemic.com>
	 */
	function int max (int a, int b);
		return (a > b) ? a : b;
	endfunction

	/**
	 * @brief    Get the minimum value of two int values
	 * @author   Albert Schulz <aschulz@accemic.com>
	 */
	function int min (int a, int b);
		return (a < b) ? a : b;
	endfunction

	function automatic real ceil(input real a);
		automatic int rounded = int'(a);
		automatic real sub = rounded - a;

		if (sub >= 0) return rounded;
		else return a + (1+sub);
	endfunction

	function automatic real log10(input int value);
		automatic real a = clog2(value);
		automatic real b = 3.3219280948;

		return a/b;
	endfunction

	function automatic int round_up_to_power_of_2(input int value);
		automatic int  v = value;
		v--;
		v |= v >> 1;  // handle  2 bit numbers
		v |= v >> 2;  // handle  4 bit numbers
		v |= v >> 4;  // handle  8 bit numbers
		v |= v >> 8;  // handle 16 bit numbers
		v |= v >> 16; // handle 32 bit numbers
		v |= v >> 32; // handle 64 bit numbers
		v++;

		return v;

	endfunction

	/**
	 * @brief   Ceiled Log2 Function. In most cases, there is no need to use this function instead of the provided $clog2 function. This is more for internal use by the `log10` implementation for instance.
	 * @author  Albert Schulz <aschulz@accemic.com>
	 */
	function automatic int clog2(input int val);
		automatic int  v = val;
		v--;
		for(clog2 = 0; v != 0; clog2++)  v >>= 1;
	endfunction

	//-----------------------------------------------------------------------
	// Code Conversions
	//  Note:   All these functions are limited to word sizes that fit into a
	//          SystemVerilog integer ;(.
	//          More generic implementations require module instantiations.

	/**
	 * @brief   Converts a binary counter value to reflective GRAY code.
	 * @author  Thomas B. Preußer <tpreusser@accemic.com>
	 */
	function integer bin2gray(input integer  b);
		return  b ^ { 1'b0, b[$left(b):1] };
	endfunction

	/**
	 * @brief   Converts a reflective GRAY code value to binary.
	 * @author  Thomas B. Preußer <tpreusser@accemic.com>
	 */
	function integer gray2bin(input integer  g);
		automatic integer  r;
		r[$left(r)] = g[$left(r)];
			for(int  i = $left(r); i > 0; i--) begin
			r[i-1] = r[i] ^ g[i-1];
		end
		return  r;
	endfunction

	/**
	 * @brief   Converts a reflective GRAY code value to binary.
	 * @author  Thomas B. Preußer <tpreusser@accemic.com>
	 */
	function logic[63:0]  gray2bin64(input logic[63:0]  g);
		automatic logic[63:0]   r;
		r[$left(r)] = g[$left(r)];
		for(int  i = $left(r); i > 0; i--) begin
			r[i-1] = r[i] ^ g[i-1];
		end
		return  r;
	endfunction

	/**
	 * @brief   Converts a binary to 1-hot code.
	 * @author  Thomas B. Preußer <tpreusser@accemic.com>
	 */
	function integer bin2hot(input integer  b);
		automatic integer  r;
		for(int  i = 0; i < $bits(r); i++) begin
			r[i] = b == i;
		end
		return  r;
	endfunction

	/**
	 * @brief   Converts a 1-hot code value to its binary index.
	 * @author  Thomas B. Preußer <tpreusser@accemic.com>
	 */
	function integer hot2bin(input integer  h);
		automatic integer  r = 0;
		for(int  i = 0; i < $bits(h); i++) begin
			if(h[i])  r |= i;
		end
		return  r;
	endfunction

	/**
	 * @brief Returns the index of the maximum element in the array and writes the maximum value to an output argument.
	 * @param T         Element type (default logic[7:0]).
	 * @param arr       Dynamic array of N elements of type T to scan for the maximum value.
	 * @return          maximum value found in arr[0..N-1].
	 * @note The function is automatic; all locals are stack-allocated.
	 * @author  Alexander Weiss <aweiss@accemic.com>
	 */

	class array_math #(type T=logic[7:0]);
		static function T max_array (input T arr[]);
			T res;
			res = arr[0];
			for (int i = 1; i < arr.size(); i++) begin
				if (arr[i] > res) begin
					res = arr[i];
				end
			end
			return res;
		endfunction
	endclass

endpackage
