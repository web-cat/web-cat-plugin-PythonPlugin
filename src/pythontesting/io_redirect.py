'''
Created on Jun 4, 2018

@author: Schnook
'''


import io
import sys

class IORedirect:
    '''
    Supports redirection of standard i/o to streams.
    @author saturner
    '''

    def __init__(self):
        '''
        Constructor
        '''
        
        self.__orig_stdout = sys.stdout
        self.__orig_stderr = sys.stderr
        self.__orig_stdin = sys.stdin

        self.__isredirected = False
        
        
    
    def redirectio(self, input_stream=""):
        """
        Redirects i/o to the streams in the class.  
        @param input_stream Input data as a string
        """
        
        self.__output = io.StringIO()
        self.__error = io.StringIO()
        self.__input = io.StringIO(input_stream)

        sys.stdout = self.__output
        sys.stderr = self.__error
        sys.stdin = self.__input
        
        self.__isredirected = True
     
    def restoreio(self): 
        """
        Reverts the i/o back to the original settings
        """
        sys.stdout = self.__orig_stdout
        sys.stderr = self.__orig_stderr
        sys.stdin = self.__orig_stdin
        
        self.__isredirected = False

    
#     def resetio(self, new_input=""):
#         """
#         Resets the output streams and sets new input.
#         @param newInput Input data as a string
#          """
#         self.output = io.StringIO()
#         self.error = io.StringIO()
#         self.input = io.StringIO(new_input)
# 
#         sys.stdout = self.output
#         sys.stderr = self.error
#         sys.stdin = self.input
    
    
    def setinput(self, new_input):
        """
        Sets the input to be read
        @param input Input data as a string
        """
        self.__input = io.StringIO(new_input)
        sys.stdin = self.__input


    def getinputstream(self):
        return self.__input

    def getoutput(self): 
        """
        Gets the output as a String
        @return output from standard out
        """
        return self.__output.getvalue()
    
    
    def geterror(self): 
        """
        Gets the error output as a String
        @return output from standard err
        """
        return self.__error.getvalue()
        