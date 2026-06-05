// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2018 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*/

/**
* @brief    Provides functions to operate and parse files
* @author   Albert Schulz <aschulz@accemic.com>
*/
package file_pkg;

	/*
	 * Structure representing one line within a file
	 * comprising its line number and the actual content
	 */
	typedef struct {
		integer line_number;
		string content;
	} line_t;

	/// Representation of a single textfile comprising a variable number of lines
	typedef line_t textfile_t[];

	/*
	 * @brief   Returns the number of lines of the given file
	 * @details If the file could not be opened, an invalid number of -1 is returned
	 */
	function integer number_of_lines_in_file(string filename);
		automatic integer line_count = 0;
		automatic integer fd;

		if (filename == "") // workaround for Vivado 2018.2 crashing on $fopen("")
			return -1;

		fd = $fopen(filename, "r");
		if (fd == 0) return -1;

		while(!$feof(fd)) begin
			automatic string line;
			automatic int return_code; /// Note: Used to avoid warning message of non-existent LHS for $fgets()
			return_code = $fgets(line, fd);
			line_count++;
		end
		$fclose(fd);
		return line_count;
	endfunction

	/*
	 * @brief Remove lines with whitespaces only from file and returns the stripped result
	 */
	function textfile_t strip_empty_lines(textfile_t lines);
		automatic line_t stripped_file[$];

		foreach(lines[i]) begin
			if (!contains_whitespaces_only(lines[i].content))
				stripped_file.push_back(lines[i]);
		end

		begin
			automatic int stripped_size = stripped_file.size();
			automatic textfile_t return_file = new[stripped_size];
			for (int i = 0; i <= stripped_size; i++) begin
				automatic line_t line = stripped_file.pop_front();
				return_file[i] = line;
			end

			return return_file;
		end
	endfunction

	/*
	 * @brief Removes comments from all lines of the file and returns the stripped file
	 * @param lines The file from which the comments should be removed
	 * @param comment_identifier A string which is identifying a comment, e.g. `//` or `#`
	 */
	function textfile_t strip_comments(textfile_t lines, string comment_identifier);
		automatic textfile_t stripped_textfile = new[lines.size()];

		foreach(lines[i]) begin
			stripped_textfile[i].line_number = lines[i].line_number;
			stripped_textfile[i].content = strip_comment(lines[i].content, comment_identifier);
		end
		return stripped_textfile;
	endfunction

	/*
	 * @brief   Remove a comment from a string
	 * @details Removes the comment identifier and all characters which are followed by the identifier
	 *          ! Note: Also line breaks might be stripped due to the current implementation
	 * @param str String containing the comment
	 * @param comment_identifier A string which is identifying a comment, e.g. `//` or `#`
	 */
	function string strip_comment(string str, string comment_identifier);
		automatic integer comment_identifier_index = index_for_substring(str, comment_identifier);
		if (comment_identifier_index == -1) return str;

		return str.substr(0, comment_identifier_index-1);
	endfunction

	/*
	 * @brief   Find the position of a substring within a string
	 * @details Returns the index of the first occurance of the substring within the string. Characters index starts at 0.
	 * @param str The string which may contain the search string
	 * @param search_str The string which should be searched for
	 */
	function integer index_for_substring(string str, string search_str);
		if (search_str.len() == 0) return -1;

		for (int i = 0; i <= str.len()-search_str.len(); i++) begin
			if (str.substr(i, i+search_str.len()-1) == search_str) return i;
		end

		return -1;
	endfunction

	/*
	 * Returns '1 if string only consists of whitespace characters,
	 * Otherwise returns '0
	 */
	function bit contains_whitespaces_only(string str);
		for (int i = 0; i < str.len(); i++)
			if (str.getc(i) != 32
			&& str.getc(i) != 9
			&& str.getc(i) != 10
			&& str.getc(i) != 11
			&& str.getc(i) != 12
			&& str.getc(i) != 13) return '0;
		return '1;
	endfunction

	/*
	 * @brief   Reads file and transfers it to a textfile_t structure
	 * @details If the file can not be opened, an empty structure is returned
	 */
	function textfile_t read_file(string filename);
		automatic integer number_of_lines = number_of_lines_in_file(filename);
		automatic textfile_t textfile;

		if (number_of_lines == -1) return textfile;
		else begin
			automatic integer index = 0;
			automatic integer fd = $fopen(filename, "r");
			if (fd == 0) return textfile;

			textfile = new[number_of_lines];

			while (!$feof(fd)) begin
				automatic string line;
				automatic integer return_code = $fgets(line, fd);

				// Strip new line character
				if (line.getc(line.len()-1) == 10 || line.getc(line.len()-1) == 13)
					line = line.substr(0,line.len()-2);

				textfile[index].line_number = index+1;
				textfile[index].content = line;
				index++;
			end

			$fclose(fd);
		end

		return textfile;
	endfunction

	/// Display the contents of a textfile in the format <line number>: <line string>
	task display_textfile(textfile_t textfile);
		foreach(textfile[i]) $display("%0d: %s", textfile[i].line_number, textfile[i].content);
	endtask

	// Task to check if a file exists and provide detailed error information
	task automatic check_file_exists;
		input  string file_name;       // Input: File name to check

		integer file_handle;
		integer test_write_handle;
		string  abs_path;
		string  error_msg;

		begin
			// Step 1: Try to open file for reading
			file_handle = $fopen(file_name, "r");

			if (file_handle == 0) begin
				// File could not be opened
				// Try to determine why

				// Check 1: Is the path absolute or relative?
				if (file_name[0] == "/" || file_name[0] == "\\" ||
					(file_name.len() > 2 && file_name[1] == ":")) begin
					abs_path = file_name;
					error_msg = $sformatf("Absolute path: %s\n", abs_path);
				end else begin
					abs_path = file_name;  // Relative paths are hard to determine
					error_msg = $sformatf("Relative path (relative to working directory): %s\n",
										  abs_path);
				end

				// Check 2: Try to open file for writing (permissions test)
				test_write_handle = $fopen(file_name, "a");

				if (test_write_handle == 0) begin
					// File does NOT exist or is read-only
					$error("ERROR: Could not open file!");
					$error("  %s", error_msg);
					$error("  Possible causes:");
					$error("    1. File does not exist");
					$error("    2. Path does not exist (directory missing)");
					$error("    3. No write permissions on directory");
					$error("    4. File is read-only (write-protected)");
					$error("    5. Invalid characters in path or filename");
					$error("    6. Filename too long (>255 characters)");
					$error("    7. File is currently in use by another process");

					// Try to get details using $system (Linux/Mac/Windows)
					void'($system($sformatf("test -e '%s' && echo 'FILE_EXISTS' || echo 'FILE_NOT_EXIST'",
											file_name)));
					void'($system($sformatf("test -r '%s' && echo 'FILE_READABLE' || echo 'FILE_NOT_READABLE'",
											file_name)));
					void'($system($sformatf("test -w '%s' && echo 'FILE_WRITABLE' || echo 'FILE_NOT_WRITABLE'",
											file_name)));

					$finish;
				end else begin
					// File exists, but test-open in append mode succeeded
					// This means: file exists and is writable
					$fclose(test_write_handle);

					$error("ERROR: File %s could not be opened in read mode!",
						   file_name);
					$error("  But the file exists and is writable!");
					$error("  Possible causes:");
					$error("    1. File is locked/currently in use");
					$error("    2. Encoding problem (e.g., invalid UTF-8 sequences)");
					$error("    3. Path too long for simulator");
					$error("    4. Temporary error - try again");

					$finish;
				end
			end else begin
				// File handle is valid (> 0)
				// File exists and could be opened
				$fclose(file_handle);
				$display("[OK] File found and opened successfully: %s", file_name);
			end
		end
	endtask

	// Task to open a file
	task automatic file_open;
		input  string file_path;        // File path to open
		input  string mode;             // File mode (e.g., "w" for write)
		output integer file_handle;     // File handle output
		begin
			if (file_path == "") begin
				$error("Error: File path %s is missing.", file_path);
				$stop;
			end else begin
				file_handle = $fopen(file_path, mode);
				if (file_handle == 0) begin
					$error("Error: Failed to open file: %s", file_path);
					$stop;
				end
				$display("File %s successfully opened with handle %0d", file_path, file_handle);
			end
		end
	endtask

endpackage
