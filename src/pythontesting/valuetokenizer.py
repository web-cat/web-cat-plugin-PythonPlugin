'''
Created on Jun 7, 2018

@author: Schnook
'''

import re

# Default tokenization for strings. Extracts anything not whitespace (i.e.
# \S).
TOKEN_MATCH = "(\\S+)"

# @brief This specifies the symbols allowed to come before a number if
#    looking for a separate token.
#  
# This specifies the symbols allowed to come before a number if
# looking for a separate token. By default, the allows characters
# are: whitespace i.e. " 5" beginning of the line i.e. "5" $ i.e.
# "$5" # i.e. "#5" + i.e. "+5" ( i.e. "(5" * i.e. "*5" : i.e. ":5" ;
# i.e. ";5" / i.e. "/5" , i.e. ",5" \ i.e. "\5" [ i.e. "[5" { i.e.
# "{5"
# /
NUM_PREFIX = "[\\[{\\s$#+(*:;/,\\\\]|\\A"

# @brief This specifies the symbols allowed to come after a number if
# looking for a separate token.
# 
# This specifies the symbols allowed to come after a number if
# looking for a separate token. By default, the allows characters
# are: whitespace i.e. "5 " end of the line i.e. "5" a period i.e.
# "5." or "5. " ! i.e. "5!" ? i.e. "5?" % i.e. "5%" # i.e. "5#" /
# i.e. "5/" + i.e. "5+" * i.e. "5*" ) i.e. "5)" : i.e. "5:" ; i.e.
# "5;" , i.e. "5," - i.e. "5-" \ i.e. "5\" } i.e. "5}" ] i.e. "5]"
   
NUM_POSTFIX = "(?=(?=[\\]}\\s!?%#/+*,\\-:;" \
            + "\\)\\\\]|\\Z)|(?:\\.(?:\\s|\\Z)))"


# This matches integers that may be embedded in other text.
# 
# This matches integers that may be embedded in other text. i.e. this
# should match "5", "6,", ":7", "a9b", etc. The expressions must start with
# with something that is not a ., a number, or a - sign (or the beginning
# of the expression) The value captured is simpily an optional - sign and
# one or more digits. The expression must not end with a decimal followed
# by a number. It can end with a decimal followed by something not a number
# (i.e. a period at the end of a sentence).

INT_MATCH = "(?:[^.\\d-]|\\A)(-?\\d+)" \
            + "(?=(?:[^.\\d]|\\Z)|(?:\\.(?:\\D|\\Z)))"


# Regular expression for matching ints with printf like parameters for
# adding the set of characters before and after the int.
# 
# Regular expression for matching ints with printf like parameters for
# adding the set of characters before and after the int. This is used with
# NUM_PREFIX and NUM_POSTFIX to create INT_MATCH_SEPARATE and it can be
# used in the createMatchString method to generate a regular expression
# with different pre/postfixes.
# 

INT_MATCH_SEPARATE_BASE = "(?:{0})(-?\\d+)(?:{1})";


# Regular expression for matching ints that are considered separate tokens.
# This relies on NUM_PREFIX and NUM_POSTFIX and INT_MATCH_SEPARATE_BASE to
# determine what constitutes a separate token.
# 

INT_MATCH_SEPARATE = INT_MATCH_SEPARATE_BASE.format(NUM_PREFIX, NUM_POSTFIX)


# This matches doubles that may be embedded in other text.
# 
# This matches doubles that may be embedded in other text. i.e. this should
# match "5.5", "6,", ":7.3", "a9.74b", etc. The expressions must start with
# with something that is not a ., a number, or a - sign (or the beginning
# of the expression) The value captured is an optional - sign and one or
# more digits and a decimal point.

FLOAT_MATCH = "(?:(?:\\A|\\$)|(?:[^-\\d\\.]))+" \
            + "(-?(?:(?:\\d+(\\.\\d)?\\d*)|(?:(\\.\\d)+\\d*)))"


# Regular expression for matching double with printf like parameters for
# adding the set of characters before and after the double.
# 
# Regular expression for matching double with printf like parameters for
# adding the set of characters before and after the double. This is used
# with NUM_PREFIX and NUM_POSTFIX to create FLOAT_MATCH_SEPARATE and it can
# be used in the createMatchString method to generate a regular expression
# with different pre/postfixes.
# 

FLOAT_MATCH_SEPARATE_BASE = "(?:{0})" \
            + "(-?(?:(?:\\d+(\\.\\d)?\\d*)|(?:(\\.\\d)?\\d*)))(?:{1})";


# Regular expression for matching doubles that are considered separate
# tokens. This relies on NUM_PREFIX and NUM_POSTFIX and
# FLOAT_MATCH_SEPARATE_BASE to determine what constitutes a separate token.
# 

FLOAT_MATCH_SEPARATE = FLOAT_MATCH_SEPARATE_BASE.format(NUM_PREFIX, NUM_POSTFIX)



# Tokenizes the string are stores it in a list
# 
# This method tokenizes the string and tries to convert the data into the
# appropriate type. If successful, it is stored in the transformation.
# 
# @attention The tokenizer pulls out the 1st captured group from the
#     regular expression. If more than one group is used, make sure
#     that they are marked as uncaptured (i.e. ?:)
# 
# @param data
#     String to tokenize
# @param matches
#     Vector to store the data
# @param pattern
#     Pattern used to tokenize the data. This should match the
#     intended tokens and not describe where the string is split.
#     (i.e. \s would return a transformation of whitespace and not the
#     values delimited by the whitespace). The default value is to
#     tokenize it into strings
# @param converter
#     function that converts the token to the appropriate
#     object.
# 
# 
def tokenize(data, pattern, converter=None):
    fullpattern = "(?mis)" + pattern 
    matches = []
        
    for match in re.finditer(fullpattern, data):
        matchVal = match.group(0)
        try:
            matchVal = match.group(1)
        except:
            pass # no subgroup
        try:
            if matchVal: # no empty matches
                if converter is None:
                    matches.append(matchVal)
                else:
                    matches.append(converter(matchVal))
        except:
            pass # fail quietly if converter is bad
         
    return matches

 
# Converts the String into a list of tokens using the default pattern
# (MATCH).
# 
# @param data
#     String to tokenize
# @param pattern
#     Regular expression to use to tokenize the data.
# @return A list of String tokens from data

def tokenizeToString(data, pattern=TOKEN_MATCH):
        return tokenize(data, pattern);


# Converts the String into a list of of integer tokens using the pattern
# parameter.
# 
# @param data
#     String to tokenize
# @param pattern
#     Regular expression to use to tokenize the data.
# @attention The tokenizer pulls out the 1st captured group from the
#     regular expression. If more than one group is used, make sure
#     that they are marked as uncaptured (i.e. ?: or ?=).
# @return A list of Integer tokens from data

def tokenizeToInt(data, pattern=INT_MATCH):
    return tokenize(data, pattern, int);
    


# Converts the String into a list of of double tokens using the pattern
# parameter.
# 
# @param data
#     String to tokenize
# @param pattern
#     Regular expression to use to tokenize the data.
# @attention The tokenizer pulls out the 1st captured group from the
#     regular expression. If more than one group is used, make sure
#     that they are marked as uncaptured (i.e. ?: or ?=).

def tokenizeToFloat(data, pattern=FLOAT_MATCH):
        return tokenize(data, pattern, float);


# Determines if a numeric value is found in the list of tokens
# 
# @param tokens
#     List of tokens
# @param toFind
#     Token to find
# @param delta
#     Maximum difference between values
# @return true if tofind is found in tokens


# combine these two using keyward args **keywords - dictionary
# check type of each value (string, number) and compare accordingly
def findNumInTokens(tokens, tofind, delta=None, pattern=FLOAT_MATCH,
                     converter=float):
    if type(tokens).__name__ == "str":
        tokens = tokenize(tokens, pattern, converter)
    
    # assume that if delta is None, they are looking for ints
    if delta is None:
        pattern = INT_MATCH
        converter=int
       
    for token in tokens:
        if delta is None:
            if token == tofind:
                return True
        else:
            if (abs(token - tofind) < delta):
                return True

    return False




# Determines if a value is found in the list of tokens
# 
# @param tokens
#     List of tokens
# @param toFind
#     Token to find
# @param ignoreCase
#     Allows case to be ignored
# @param partial
#     Allows partial matches
# 
# @return true if toFind is found in tokens

def findStrInTokens(tokens, tofind, ignoreCase, partial, pattern=TOKEN_MATCH):
    ftoken = tofind

    if ignoreCase:
        ftoken = ftoken.lower()

    if type(tokens).__name__ == "str":
        tokens = tokenize(tokens, pattern, str)

    for token in tokens:

        if ignoreCase:
            token = token.lower()

        if partial:
            try:
                token.index(ftoken)
                return True
            except:
                pass
        else:
            if token == ftoken:
                return True;

    return False;




if __name__ == '__main__':
    pass
