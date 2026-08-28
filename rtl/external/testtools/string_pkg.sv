// SPDX-FileCopyrightText: 2020 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief    Provides convenience functions to manipulate strings
 * @author   Albert Schulz <aschulz@accemic.com>
 */
package string_pkg;

	/// Returns a new string of a specified totalWidth
	/// in which the beginning of the current string is padded with spaces
	function automatic string left_pad(string s, int totalWidth);
		automatic int pad_length = totalWidth - s.len();
		automatic string prefix = "";
		for(int i = 0; i < pad_length; i++)
			prefix = {" ", prefix};
		return { prefix, s };
	endfunction

	// split string at seperator into array
	function automatic void split(input string in, output string out[], input byte separator = " ");
		automatic int index [$];
		foreach (in[i]) begin
			if (in[i] == separator) begin
			index.push_back(i-1);
			index.push_back(i+1);
			end
		end
		index.push_front(0);
		index.push_back(in.len()-1);

		out = new[index.size()/2];
		foreach (out[i]) begin
			out[i] = in.substr(index[2*i], index[2*i+1]);
		end
	endfunction

	// checks for suffix of string, case sensitive
	function automatic bit ends_with(string s, string suffix);
		if (s.len() < suffix.len()) return 0;
		else begin
			automatic string sub = s.substr(s.len() - suffix.len(), s.len()-1);
			return sub == suffix;
		end
	endfunction

	// returns first index of target, or -1 if not found
	function automatic int index_of_char(input string s, input byte target);
		index_of_char = -1;
		for (int i = 0; i < s.len(); i++) begin
			if (s.getc(i) == target) begin
				index_of_char = i;
				break;
			end
		end
	endfunction

	// checks for prefix of string, case sensitive
	function automatic bit starts_with(input string s, input string prefix);
		automatic bit match = 1'b1;
		if (prefix.len() > s.len()) begin
			return 1'b0;
		end
		for (int i = 0; i < prefix.len(); i++) begin
			if (s.getc(i) != prefix.getc(i)) begin
				match = 1'b0;
			end
		end
		return match;
	endfunction

	// checks whether a string contains a character
	function automatic bit contains_char(input string s, input byte target);
		return (index_of_char(s, target) >= 0);
	endfunction

	// trims leading spaces and ASCII whitespace
	function automatic string ltrim(input string s);
		automatic int first = 0;
		while ((first < s.len()) && ((s.getc(first) == 8'd32) || (s.getc(first) == 8'd9)
			|| (s.getc(first) == 8'd10) || (s.getc(first) == 8'd13))) begin
			first++;
		end
		if (first >= s.len()) begin
			return "";
		end
		return s.substr(first, s.len()-1);
	endfunction

	// returns the substring after the first separator, then left-trims it
	function automatic string payload_from_line(input string line, input byte separator = ":");
		automatic int sep_idx;
		sep_idx = index_of_char(line, separator);
		if (sep_idx < 0) begin
			return ltrim(line);
		end
		if (sep_idx + 1 >= line.len()) begin
			return "";
		end
		return ltrim(line.substr(sep_idx + 1, line.len()-1));
	endfunction

endpackage : string_pkg
