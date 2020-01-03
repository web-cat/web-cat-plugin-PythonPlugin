'''
Created on May 17, 2018


'''


#web-cat uses 3.3

# from idlelib.query import ModuleName
from platform import node
from builtins import isinstance
import warnings

"""Test case implementation."""

# TODO Class to redirect input/output - test
# Method to run a function
#    Input as a list
#    use compile and exec - maybe not
#    Need to look up if module/file exists - done
#    Need to determine if function exists - done
# 


import io
import unittest
import traceback
import sys
import re
import threading
import ctypes
import time
import pythontesting.io_redirect as io_redirect
import importlib
import ast


#~ Sandbox overrides ..........................................................

_originalBuiltins = {}


# -------------------------------------------------------------
def _disabled_compile(source, filename, mode, flags=0, dont_inherit=False):
    raise RuntimeError("You are not allowed to call 'compile'.")

# -------------------------------------------------------------
def _disabled_eval(object, globals=globals(), locals=locals()):
    raise RuntimeError("You are not allowed to call 'eval'.")

# -------------------------------------------------------------
def _disabled_exec(object, globals=globals(), locals=locals()):
    raise RuntimeError("You are not allowed to call 'exec'.")

# -------------------------------------------------------------
def _disabled_globals():
    raise RuntimeError("You are not allowed to call 'globals'.")

# -------------------------------------------------------------
_open_forbidden_names = re.compile(r"(^[./])|(\.py$)")
_open_forbidden_modes = re.compile(r"[wa+]")

def _restricted_open(name, mode='r', buffering=-1):
    if _open_forbidden_names.search(name):
        raise RuntimeError('The filename you passed to \'open\' is restricted.')
    elif _open_forbidden_modes.search(mode):
        raise RuntimeError('You are not allowed to \'open\' files for writing.')
    else:
        return _originalBuiltins['open'](name, mode, buffering)


_reject_traceback_file_pattern = re.compile(r'[./]')



#~ Global functions ...........................................................

# -------------------------------------------------------------
def timeout(duration, func, *args, **kwargs):
    """
    Executes a function and kills it (throwing an exception) if it runs for
    longer than the specified duration, in seconds.
    """

    # -------------------------------------------------------------
    class InterruptableThread(threading.Thread):

        # -------------------------------------------------------------
        def __init__(self):
            threading.Thread.__init__(self)
            self.daemon = True
            self.result = None
            self.exc_info = (None, None, None)

    
        # -------------------------------------------------------------
        def run(self):
            try:
                self.result = func(*args, **kwargs)
            except Exception: # as e:
                self.exc_info = sys.exc_info()

    
        # -------------------------------------------------------------
        @classmethod
        def _async_raise(cls, tid, excobj):
            res = ctypes.pythonapi.PyThreadState_SetAsyncExc( \
                ctypes.c_long(tid), ctypes.py_object(excobj))
        
            if res == 0:
                raise ValueError("nonexistent thread id")
            elif res > 1:
                ctypes.pythonapi.PyThreadState_SetAsyncExc(tid, 0)
                raise SystemError("PyThreadState_SetAsyncExc failed")


        # -------------------------------------------------------------
        def raise_exc(self, excobj):
            assert self.isAlive(), "thread must be started"
            for tid, tobj in threading._active.items():
                if tobj is self:
                    self._async_raise(tid, excobj)
                    return


        # -------------------------------------------------------------
        def terminate(self):
            self.raise_exc(SystemExit)


    target_thread = InterruptableThread()
    target_thread.start()
    target_thread.join(duration)

    if target_thread.isAlive():
        target_thread.terminate()
        raise TimeoutError('Hint: Your code took too long to run '
                           '(it was given {} seconds); '
                           'maybe you have an infinite loop?'.format(duration))
    else:
        if target_thread.exc_info[0] is not None:
            ei = target_thread.exc_info
            # Python 2 had the three-argument raise statement; thanks to PEP 3109
            # for showing how to convert that to valid Python 3 statements.
            e = ei[0](ei[1])
            e.__traceback__ = ei[2]
            raise e


# -------------------------------------------------------------
def runAllTests(stream=sys.stderr,timeoutCeiling=2.5):
    """
    Runs all test cases in suites that extend pythy.TestCase.
    """

    global _timeoutData
    _timeoutData = _TimeoutData(timeoutCeiling)

    _recursivelyRunTests(WeightedTestCase, stream)


# -------------------------------------------------------------
def _recursivelyRunTests(cls, stream):
    for child in cls.__subclasses__():
        suite = unittest.TestLoader().loadTestsFromTestCase(child)
        TestRunner(stream).run(suite)
        _recursivelyRunTests(child, stream)



#~ Decorators .................................................................

# -------------------------------------------------------------
def category(catname):
    """
    Specifies a category for a test case, which will be written in the
    result output.
    """
    def decorator(test_item):
        test_item.__pythytest_category__ = catname
        return test_item
    return decorator



#~ Classes ....................................................................

# =========================================================================
class TimeoutError(Exception):
    """
    Thrown by a test case if it exceeds the allowed amount of execution time.
    """
    pass


# =========================================================================
class _TimeoutData:
    """
    Port of Craig Estep's AdaptiveTimeout JUnit rule from the VTCS student
    library.
    """
  
    # -------------------------------------------------------------
    def __init__(self, ceiling):
        self.ceiling = ceiling # sec
        self.maximum = ceiling * 2 # sec
        self.minimum = 0.25 # sec
        self.threshold = 0.6
        self.rampup = 1.4
        self.rampdown = 0.5
        self.start = self.end = 0
        self.nonterminatingMethods = 0

  
    # -------------------------------------------------------------
    def beforeTest(self):
        """
        Call this before a test case runs in order to reset the timer.
        """
        self.start = time.time()


    # -------------------------------------------------------------
    def afterTest(self):
        """
        Call this after a test case runs. This will examine how long it took
        the test to execute, and if it required an amount of time greater than
        the current ceiling, it will adaptively adjust the allowed time for
        the next test.
        """
        self.end = time.time()
        diff = self.end - self.start

        if diff > self.ceiling:
            self.nonterminatingMethods += 1

            if self.nonterminatingMethods >= 2:
                if self.ceiling * self.rampdown < self.minimum:
                    self.ceiling = self.minimum
                else:
                    self.ceiling = (self.ceiling * self.rampdown)
        elif diff > self.ceiling * self.threshold:
            if self.ceiling * self.rampup > self.maximum:
                self.ceiling = self.maximum
            else:
                self.ceiling = (self.ceiling * self.rampup)




_timeoutData = _TimeoutData(2.5)

# =========================================================================
class TestCase(unittest.TestCase):

    __ERR_NO_ERROR = 0
    __ERR_NO_MODULE = 1
    __ERR_FILE_NOT_READ = 2
    __ERR_NOT_FOUND = 4
    __ERR_CLASS_NOT_FOUND = 8
    __ioredir = io_redirect.IORedirect() 
        

    # -------------------------------------------------------------
    def __init__(self, methodName='runTest'):
        unittest.TestCase.__init__(self, methodName)
        
        try:
            weightMatch = re.search(r'test_weight\s*:\s*(\d+)',self._testMethodDoc)
            tmpWeight = weightMatch.group(1)
            self.weight = int(tmpWeight)
        except:
            self.weight = 1


    # -------------------------------------------------------------
    #def runBare(self, function):
    #  timeout(_timeoutData.ceiling, unittest.TestCase.runBare, self, function)


    # -------------------------------------------------------------
    def run(self, testMethod):
        _timeoutData.beforeTest()
        unittest.TestCase.run(self, testMethod)
        _timeoutData.afterTest()

    
    def getWeight(self):
        return self.weight
    
    # create object - just calling __init__?
    # run method
    # run method with i/o


   

    def runFunction(self, modulename, funcname, *args, **keyw):
        """
        
        Tries to run a function with a set of arguments. Can optionally supply
        input and/or check if the function used stdin/stdout. 
        
        :param modulename: Name of the module with the function. Should not be
             a standard Python module
        :param funcname: Name of the function to run
        :param *args: Arguments to pass to the function when it is invoked
        :param input: Keyword argument that contains the input that should be
            available to the function on stdin. Defaults to ""
        :param allowoutput: Keyword argument that denotes whether output should
            be allowed or not on stdout. If False and there is output, the 
            test will fail. Defaults to True.
        :param allowinput: Keyword argument that denotes wheterh input should be
            allowed or not on stdin. If False and the input stream has been read 
            from, the test will fail. Defaults to True.
            
        :returns a tuple with the return value and the output from stdout
        """
        self.checkIfFunctionExists(modulename, funcname)
        
        inpt = ""
        if 'input' in keyw:
            inpt = keyw['input']
        
        allowout = True
        if 'allowoutput' in keyw:
            allowout = keyw['allowoutput']
            
        allowin = True
        if 'allowinput' in keyw:
            allowin = keyw['allowinput']
        
        
        self.__ioredir.redirectio(inpt)
        try: 
            __import__(modulename)
            val = getattr(sys.modules[modulename], funcname)(*args)
           
        except:
            self.fail("Calling " + funcname + " in module " + modulename + 
                      " caused the program to crash.")
        finally:
            self.__ioredir.restoreio()
            
        output = self.__ioredir.getoutput()
        self.assertFalse(not allowout and output, funcname + " in module " 
                        + modulename + " produced output when it should "
                        + "not have. If you have print statements "
                        + "in the function for debugging purposes, remove them.")
        
        self.assertFalse(not allowin and self.__ioredir.getinputstream().tell() != 0,
                         funcname + " in module " 
                        + modulename + " tried to read from the input when it should "
                        + "not have. If you have input statements "
                        + "in the function, remove them. The data for the function should "
                        + "come from the parameters.")  
        
        return (val, output)              
        

    # -------------------------------------------------------------
    def runFile(self, filename, inpt='', appendext=True):
        """
        Runs the Python code in the specified file (if omitted, main.py is
        used) under a restricted environment, using the specified input string
        as the content of stdin and capturing the text sent to stdout.
        Returns a 2-tuple (studentLocals, output), where studentLocals is a
        dictionary containing the state of the local variables, functions, and
        class definitions after the program was executed, and output is the
        text that the program wrote to stdout.

        """
        """
        self.__overrideBuiltins({
            'compile':  _disabled_compile,
            'eval':     _disabled_eval,
            'exec':     _disabled_exec,
            'globals':  _disabled_globals,
            'open':     _restricted_open
        })
        """    

        # studentLocals = self.safeGlobals

        # captureout = io.StringIO()
        # injectin = io.StringIO(inpt)

        # oldstdout = sys.stdout
        # oldstdin = sys.stdin

        # sys.stdout = captureout
        # sys.stdin = injectin
        
        if filename[-3:].lower() != ".py" and appendext:
            filename += ".py"
        
        self.__ioredir.redirectio(inpt)

        try:
            # Calling compile instead of just passing the string source to exec
            # ensures that we get meaningul filenames in the traceback when tests
            # fail or have errors.
            
            # don't think these next two lines are needed
            # with open(filename, 'r') as fh:
            #    code = fh.read() + '\n'
        # use runpy.run_module instead?
            with open(filename, 'r') as sf:
                code = sf.read() + '\n'

            codeObject = compile(code, filename, 'exec')
            beast = {"oeu":2}
            exec(codeObject,beast )
        finally:
            # sys.stdout = oldstdout
            #sys.stdin = oldstdin
            self.__ioredir.restoreio()

        return (self.__ioredir.getoutput())


    # -------------------------------------------------------------
    def captureOutput(self, fn):
        # captureout = io.StringIO()
        # oldstdout = sys.stdout
        # sys.stdout = captureout
        self.__ioredir.redirectio("")
        try:
            fn()
            return self.__ioredir.getoutput()
        finally:
            # sys.stdout = oldstdout
            self.__ioredir.restoreio()


#     def wasPrintUsed(self):
#         """
#         Determines if the code uses the print function.
#         Useful for checking if functions are using print 
#         when they should not be (i.e. should be returning data
#         or something similar)
#         """
#         return self.__ioredir.getoutput()
#     
#     def wasInputUsed(self):
#         """
#         Determines if the code uses the print function.
#         Useful for checking if functions are using print 
#         when they should not be (i.e. should be returning data
#         or something similar)
#         """
#         return self.__ioredir.getoutput()
    


    def doesModuleExist(self, modulename):
        """
        Determines if a module exists.
        @return Returns true if it exists, false otherwise
        """
        # 3.4 and higher, Web-CAT in 3.3
        mod = importlib.util.find_spec(modulename)
        # 3.3 and lower
        # mod = importlib.find_loader(modulename)
        return mod is not None
        # TODO need try?
        # try:
        #     importlib.import_module(modulename)
        #     return True
        # except:
        #     return False
       
    
    def checkIfModuleExists(self, modulename):
        self.assertTrue(self.doesModuleExist(modulename),
                        "The module/file \"" + modulename
                        + "\" could not be found. Check your "
                        + "spelling (including capitalization) "
                        + "and the location of the file.")
            
    
    def __findClass(self, node, classname):
        try:
            if type(node) == ast.ClassDef and node.name == classname:
                return node
        except:
            pass
        
        for child in ast.iter_child_nodes(node):
            found = self.__findClass(child, classname)
            if (found is not None):
                return found
        return None
    
    def __doesValueExist(self, modulename, classname, valuename, valuetype):
        # only really useful for ast.FunctionDef, ast.ClassDef, ast.Name
        # 3.4 and higher, Web-CAT in 3.3
        mod = importlib.util.find_spec(modulename)
#         mod = importlib.find_loader(modulename)
           
        if mod is None:
            return self.__ERR_NO_MODULE
        
        code = ""
        try:
            with open(mod.origin, 'r') as modfile:
                code = modfile.read() + '\n'                
        except: 
            return self.__ERR_FILE_NOT_READ
        
        tree = ast.parse(code, mod.origin)
        
        if classname is not None and not classname == "":
            classnode = self.__findClass(tree, classname)
            if classnode is None:
                return self.__ERR_CLASS_NOT_FOUND
            if valuetype == ast.ClassDef and classname == classnode.name \
                and (classname == valuename or valuename is None \
                     or valuename is ""):
                return self.__ERR_NO_ERROR 
        else:
            classnode = tree    
                
        
        # for node in ast.walk(tree):
        #    try:
        #        print(node, node.name)
        #    except:
        #        pass
        
        for node in ast.iter_child_nodes(classnode):
            if type(node) == valuetype \
                and node.name == valuename:
                # if type(node) == ast.FunctionDef:
                #     print(dir(node))
                return self.__ERR_NO_ERROR
        return self.__ERR_NOT_FOUND
    
    
    def __checkIfValueExists(self, modulename, classname, valuename, valuetype):
        # only really useful for ast.FunctionDef, ast.ClassDef, ast.Name
        errval = self.__doesValueExist(modulename, classname, valuename, valuetype)
        
        if errval == self.__ERR_NO_ERROR:
            return
        elif errval == self.__ERR_NO_MODULE:
            self.fail("The module/file \"" + modulename
                        + "\" could not be found. Check your "
                        + "spelling (including capitalization) "
                        + "and the location of the file.")
        elif errval == self.__ERR_FILE_NOT_READ:
            self.fail("The module/file \"" + modulename
                        + "\" could not be opened.")
        elif errval == self.__ERR_CLASS_NOT_FOUND:
            self.fail("The class \"" + classname
                        + "\" could not be found. Check your "
                        + "spelling (including capitalization).")
        else:
            typestr = ""
            classstr = ""
        
            if valuetype == ast.FunctionDef:
                typestr = "function"
                if classname: # if classname is valide, this shold be a method
                    typestr = "method"
                    classstr = "in the class \"" + classname + "\" "
            elif valuetype == ast.ClassDef:
                typestr = "class"
            
            self.fail("The " + typestr +  " \"" + valuename
                        + "\" " + classstr + "could not be found. Check your "
                        + "spelling (including capitalization).")    
     
    
    
    
    
    def doesFunctionExist(self, modulename, functionname):
        return self.__doesValueExist(modulename, "", functionname,
                                      ast.FunctionDef) == self.__ERR_NO_ERROR

    def checkIfFunctionExists(self, modulename, functionname):
        self.__checkIfValueExists(modulename, "", functionname,
                                      ast.FunctionDef)

    def doesClassExist(self, modulename, classname):
        return self.__doesValueExist(modulename, "", classname,
                                      ast.ClassDef) == self.__ERR_NO_ERROR

    def checkIfClassExists(self, modulename, classname):
        self.__checkIfValueExists(modulename, "", classname,
                                      ast.ClassDef)

    def doesMethodExist(self, modulename, classname, methodname):
        return self.__doesValueExist(modulename, classname, methodname,
                                      ast.FunctionDef) == self.__ERR_NO_ERROR

    def checkIfMethodExists(self, modulename, classname, methodname):
        return self.__checkIfValueExists(modulename, classname, methodname,
                                      ast.FunctionDef)
                                      
    # -------------------------------------------------------------
    def __overrideBuiltins(self, dictionary):
        # Create a shallow copy of the dictionary of built-in methods. Then,
        # we'll take specific ones that are unsafe and replace them.
        self.safeGlobals = {}
        safeBuiltins = self.safeGlobals["__builtins__"] = __builtins__.copy()

        for name, function in dictionary.items():
            _originalBuiltins[name] = __builtins__[name]
            safeBuiltins[name] = function



class WeightedTestCase(TestCase):

   

    # -------------------------------------------------------------
    def __init__(self, methodName='runTest'):
        TestCase.__init__(self, methodName)
        
        try:
            weightMatch = re.search(r'test_weight\s*:\s*(\d+)',self._testMethodDoc)
            tmpWeight = weightMatch.group(1)
            self.weight = int(tmpWeight)
        except:
            self.weight = 1
    
    def getWeight(self):
        return self.weight
    
  


# =========================================================================
class TestRunner:
 
    # -------------------------------------------------------------
    def __init__(self, stream=sys.stderr):        
         
        self.stream = stream
        self.testData = {
            'categories': set(),
            'tests': []
        }       
 
    # -------------------------------------------------------------
    def run(self, test):
        result = _PythyTestResult(self)
        test(result)        
        self.__dumpOutcomes()
        return result
 
 
    # -------------------------------------------------------------
    def __dumpOutcomes(self):
        # Convert the 'categories' set to a list so that it gets dumped cleanly
        # in the YAML output.
        self.testData['categories'] = list(self.testData['categories'])
 
    #  yaml.dump(self.testData, self.stream, default_flow_style=False)
 
 
    # -------------------------------------------------------------
    def _startTest(self, test):
        newtest = { 'name': test.id() }
 
        if test.shortDescription():
            newtest["description"] = test.shortDescription()
 
        testMethod = getattr(test, test._testMethodName)
        category = getattr(testMethod, '__pythytest_category__', None)
 
        if category:
            newtest['category'] = category
            self.testData['categories'].add(category)
 
        self.testData['tests'].append(newtest)
        return newtest
 
 
 
# =========================================================================
class _PythyTestResult(unittest.TestResult):
    """
    A custom test result class that prints output in Yaml format
    that Pythy's worker process can easily read in and process.
    """
 
    # -------------------------------------------------------------
    def __init__(self, runner):
        unittest.TestResult.__init__(self)
        self.runner = runner
 
 
    # -------------------------------------------------------------
    def startTest(self, test):
        unittest.TestResult.startTest(self, test)
        self.currentTest = self.runner._startTest(test)
 
 
    # -------------------------------------------------------------
    def addError(self, test, err):
        unittest.TestResult.addError(self, test, err)
        self.currentTest["result"] = "error"
        self.__populateWithError(err)
 
 
    # -------------------------------------------------------------
    def addFailure(self, test, err):
        unittest.TestResult.addFailure(self, test, err)
        self.currentTest["result"] = "failure"
        self.__populateWithError(err)
 
 
    # -------------------------------------------------------------
    def addSuccess(self, test):
        unittest.TestResult.addSuccess(self, test)
        self.currentTest["result"] = "success"
 
 
    # -------------------------------------------------------------
    def addSkip(self, test, reason):
        unittest.TestResult.addSkip(self, test, reason)
 
 
    # -------------------------------------------------------------
    def addExpectedFailure(self, test, err):
        unittest.TestResult.addExpectedFailure(self, test, err)
 
 
    # -------------------------------------------------------------
    def addUnexpectedSuccess(self, test):
        unittest.TestResult.addUnexpectedSuccess(self, test)
 
 
    # -------------------------------------------------------------
    def stopTest(self, test):
        unittest.TestResult.stopTest(self, test)
         
 
 
    # -------------------------------------------------------------
    def __populateWithError(self, err):
        if err[0].__name__ == 'AssertionError':
            self.currentTest["reason"] = str(err[1])
        else:
            self.currentTest["reason"] = err[0].__name__ + ": " + str(err[1])
 
        # Reject tracebacks that are absolute paths or dot-leading paths;
        # most of these are going to be internal unittest or Python noise
        # anyway.
        tbList = traceback.extract_tb(err[2])
        tbList = filter(lambda frame: \
            not _reject_traceback_file_pattern.match(frame[0]), tbList)
 
        frames = list(map(lambda frame: "{2} ({0}:{1})".format(*frame), tbList))
        frameCount = min(len(frames), 20)
        self.currentTest["traceback"] = frames[0:frameCount]
     


class WeightedTestSuite(unittest.TestSuite):
    def __init__(self, tests=()):
        unittest.TestSuite.__init__(self, self.__flatten__(tests))
        # count weights and tests
        self.totalTests = 0;
        self.totalWeight = 0;
        self.passedTests = 0;
        self.passedWeight = 0;
       
        for t in self.__iter__():
            self.totalTests += 1
            if isinstance(t, WeightedTestCase):                
                self.totalWeight += t.getWeight()
            else:
                self.totalWeight += 1
    
    def __flatten__(self, tests):
        testList = []
        
        if isinstance(tests, unittest.BaseTestSuite):
            for t in tests.__iter__():
                testList += self.__flatten__(t)                
        else:
            testList += [tests]
            
        return testList
        
    def run(self, result, debug=False):
        topLevel = False
        lastErrors = len(result.errors)
        lastFailures = len(result.failures)
        
        if getattr(result, '_testRunEntered', False) is False:
            result._testRunEntered = topLevel = True
        for index, test in enumerate(self):
            if result.shouldStop:
                break
            if unittest.suite._isnotsuite(test):
                self._tearDownPreviousClass(test, result)
                self._handleModuleFixture(test, result)
                self._handleClassSetUp(test, result)
                result._previousTestClass = test.__class__
                if (getattr(test.__class__, '_classSetupFailed', False) or 
                    getattr(result, '_moduleSetUpFailed', False)):
                    continue
            if not debug:
                test(result)
                if (len(result.errors) == lastErrors and len(result.failures) == lastFailures): 
                    self.passedTests += 1
                    if isinstance(test, WeightedTestCase):
                        self.passedWeight += test.getWeight()
                    else:
                        self.passedWeight += 1
#                 print(result, test, self.passedWeight)
                lastErrors = len(result.errors)
                lastFailures = len(result.failures)
            else:
                test.debug()
            if self._cleanup:
                self._removeTestAtIndex(index)
        
        if topLevel:
            self._tearDownPreviousClass(None, result)
            self._handleModuleTearDown(result)
            result._testRunEntered = False
        return result    
    
    def getTotalTests(self):
        return self.totalTests
    
    def getTotalWeight(self):
        return self.totalWeight
    
    def getPassedTests(self):
        return self.passedTests
        
    def getPassedWeight(self):
        return self.passedWeight
    
    
         
class WeightedTextTestRunner(unittest.TextTestRunner):
    def __init__(self, **kwargs):        
        unittest.TextTestRunner.__init__(self, **kwargs)
        
#     def _getTestWeight(self, test):
#         if (isinstance(test, TestCase)):
#             return (0, 0) # TODO fix 
#         else:
#             return (0, 1)
        
    def run(self, test):
        
        wTest = WeightedTestSuite(test)
                
#         results = unittest.TextTestRunner.run(self, wTest)
        self.stream.writeln("Running: {0} test(s) (with a weight of {1})".format(
            wTest.getTotalTests(), wTest.getTotalWeight()))
        
        
        # modified version from TextTestRunner
        "Run the given test case or test suite."
        result = self._makeResult()
        unittest.registerResult(result)
        result.failfast = self.failfast
        result.buffer = self.buffer
        result.tb_locals = self.tb_locals
        with warnings.catch_warnings():
            if self.warnings: # if self.warnings is set, use it to filter all the warnings
                warnings.simplefilter(self.warnings)
            # if the filter is 'default' or 'always', special-case the
            # warnings from the deprecated unittest methods to show them
            # no more than once per module, because they can be fairly
            # noisy.  The -Wd and -Wa flags can be used to bypass this
            # only when self.warnings is None.
                if self.warnings in ['default', 'always']:
                    warnings.filterwarnings('module', 
                     category=DeprecationWarning, message=r'Please use assert\w+ instead.')
            startTime = time.perf_counter()
            startTestRun = getattr(result, 'startTestRun', None)
            if startTestRun is not None:
                startTestRun()
            try:
                wTest(result)
            finally:
                stopTestRun = getattr(result, 'stopTestRun', None)
                if stopTestRun is not None:
                    stopTestRun()
            
            stopTime = time.perf_counter()
        timeTaken = stopTime - startTime
        result.printErrors()
        if hasattr(result, 'separator2'):
            self.stream.writeln(result.separator2)
        run = result.testsRun
        self.stream.writeln("Ran %d test%s in %.3fs" % (run, run != 1 
         and "s" or "", timeTaken))
        self.stream.writeln()
        expectedFails = unexpectedSuccesses = skipped = 0
        try:
            results = map(len, (result.expectedFailures, 
                    result.unexpectedSuccesses, 
                    result.skipped))
        except AttributeError:
            pass
        else:
            expectedFails, unexpectedSuccesses, skipped = results
        
        infos = []
        if not result.wasSuccessful():
            self.stream.write("FAILED")
            failed, errored = len(result.failures), len(result.errors)
            if failed:
                infos.append("failures=%d" % failed)
            if errored:
                infos.append("errors=%d" % errored)
        else:
            self.stream.write("OK")
        if skipped:
            infos.append("skipped=%d" % skipped)
        if expectedFails:
            infos.append("expected failures=%d" % expectedFails)
        if unexpectedSuccesses:
            infos.append("unexpected successes=%d" % 
             unexpectedSuccesses)
        if infos:
            self.stream.writeln(" (%s)" % (", ".join(infos), ))
        else:
            self.stream.write("\n")
               
        # add output with weighted results        
        self.stream.writeln("Weighted Results: {0} out of {1}".format(
            wTest.getPassedWeight(), wTest.getTotalWeight()))

        return result