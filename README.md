# web-cat-plugin-PythonPlugin
A Web-CAT grading plug-in for Python that is designed to execute the student program against a set of student-provided tests and also against a set of instructor-provided tests (reference tests).

The pythontesting module provides some testing support for Python. This includes:

  I/O redirection for easier grading of programs that use standard input/output.
  A tokenizer to parse output into string, int or float values.
  Modified test classes that:
    Disable eval, exec, compile functions
    Determine if modules, classes, functions/methods exist through reflection
    Run code through reflections
    Allow for weighting of test cases
    
To use weighted tests,
  Inherit from WeightedTestCase (std_tests module)
  Modify the test file to include:
  
  if __name__ == "__main__":
    unittest.main(testRunner=WeightedTextTestRunner())

  WeightedTextTestRunner is in std_tests module.
  The file should be run normally and not as a test case.
  
