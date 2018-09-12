# Fix bugs:

* Assertion failed in `test-cases/multictr.wybe`
* `test-cases/stmt_for.wybe` gets "Internal error: Generator expression producing unexpected vars?"
* `test-cases/stmt_when.wybe` and `test-cases/stmt_unless.wybe`: compiled but not generating expected outputs
* `test-cases/stmt_if.wybe` gets "Internal error: Semidet proc call {..} in a Det context...“: should check how to call a test proc
* `test-cases/proc_gcd.wybe` gets "Internal error: Local variable not in scope: "r#0""
* `test-cases/multi_out.wybe` gets "clang: error: linker command failed with exit code 1 (use -v to see invocation)..." - should fix accessing to multi return variables
* `test-cases/exp_print.wybe` when println a double quoted string, it always produces an extra newline
* `test-cases/alias.wybe` Still gets seg faults; cannot access data structure fields
* `test-cases/import.wybe` Still get the error "No main (top-level) code in module 'import'; not building executable"
* `test-cases/type_list.wybe` gets "Internal error: Semidet proc call {test type_list.intlist.<0>tail(x:type_list.intlist @type_list:9:43, ?tmp$4:type_list.intlist @type_list:9:38)} in a Det context"
* `test-cases/io.wybe` gets "Error detected during generating low level code in io; Uninitialised variable 'wybe.io$io'"


# Documentation:
* Write Wybe intro
* Write setup/build/install document


# Complete the implementation:
* Generate print and comparison methods for user defined types
* Generate string function for user defined types, once we have decent strings
* Support many non-constant constructors
* Handle building `.o` files for foreign code using `make` or alternatives
* Ensure a variable both assigned and used in a statement has the assignment
  happen first, wherever it appears in the statement
* Support versioning for libraries
* Support auto-download for libraries (with sandboxing and caching)


# Error checking:
* Error if foreign call has no outputs; suggest use !I/O.
* Ensure no statement binds the same variable multiple times


# Improve error handling:
* Give meaningful message for errors detected in generated procs
* Detect and report use of uninitialised variables, including update
   of uninitialised variables
* Type and mode check foreign call arguments for llvm and lpvm calls;
  don't abort compiler on errors.


# Complete the language:
* Support higher order procs and functions through multiple specialisation
* Fix the syntax!
    * At expression level, support infix ops, where the ops are sequences of
      operator characters
    * At statement level, support brace-enclosed statement sequence as statement
    * Interpolation (string and array)
        * "...@foo..." = "..." ++ foo ++ "..."
	* "...@(foo(bar,baz))..." = "..." ++ foo(bar,baz) ++ "..."
	* [foo,@bar(baz),zip] = [foo] ++ bar(baz) ++ [zip]
	* if ++ can run backwards, then [?foo,@?bar] and [@?foo,bar] can be patterns
	* with this, no need for [ ... | ...] syntax
* Provide scoped way to set resources
* Provide way to give top-level initial value to resources
* Support automatic type conversion?
* Support polymorphism
* Provide switch-on-constructor syntax and implementation
* Support subtypes
* Support generators (lazy lists)
* Support declared laziness through multiple specialisation
* Support optional and named arguments
* Support generators (nondet procs)
* Support "commutative" resources, which don't need to be threaded everywhere
* Support unicode


# Library:
* Implement decent string type
* Map and set types
* Library of I/O operations using resources for streams
* Command line argument handling using resources
* Expandable array type


# Tooling:
* `wybedoc` utility with *markdown* support
* Wybe code reformatter/beautifier
* Tool to generate .wybe foreign interface file from C `.h` file
* Parser and scanner generators


# Optimise:
* Read-after-write optimisation:  record access as inverse of mutate instruction
* Extend read-after-write to support read with intervening write with different
  offset
* Keep track of bounds on tags to avoid unnecessary tests and allow tag switches
* Revise handling of inverse ops and other implied instructions to search for
  instruction variants instead of inserting them into table
* Delay instructions until their results are needed
* Move some argument threading into memory (global variables)
* Remove unneeded input and unchanged output arguments
* Inter-procedure common sub-expression elimination
* Code hoisting
* Destructive update transformation (CTGC)
* Update code generator to support destructive flag in lpvm mutate instruction
* delay statements until their outputs are needed
    * delay into one arm of a branch if only one arm needs the outputs
* Remove redundant mutate prim that will be overwritten by following mutates
  e.g. in person1.wybe, the first mutate of lastname could be removed in final LPVM


# Build System:
* Record procs before inlining to allow rebuild when dependencies change


# Blocks:
* add Procedure id for global module level procedures
* Insert target triple into the definition of LLVMAST.Module during
  creation.


# Emit:
* Improve Logging


# Make:
* Add creation of cabal sandbox and dependency install 


# Porting:
* to Linux
* to Windows
* Rewrite compiler in Wybe