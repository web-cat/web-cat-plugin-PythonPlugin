#!/usr/bin/perl -w
#=============================================================================
#   @(#)$Id$
#-----------------------------------------------------------------------------
#   Web-CAT Curator: execution script for Python submissions
#
#   usage:
#       executePythonNonTdd.pl <properties-file>
#=============================================================================
# Installation Notes:
# In the neighborhood of line 165, there are several python system-specific
# path settings that must be set to have the plugin work.

use strict;
use Config::Properties::Simple;
use File::Basename;
use File::Copy;
use File::stat;
use Proc::Background;
#use Web_CAT::Beautifier;    ## Soon, I hope. -sb
use Web_CAT::FeedbackGenerator;
use Web_CAT::Utilities
    qw( confirmExists filePattern copyHere htmlEscape addReportFile scanTo
        scanThrough linesFromFile );
use Web_CAT::PyUnitResultsReader;
 
my @beautifierIgnoreFiles = ( '.py' );


#=============================================================================
# Bring command line args into local variables for easy reference
#=============================================================================
#  Notes:
#  -- $scriptData is root directory for instructor assignment files.
#     E.g., "/var/WebCAT.data/UserScriptsData". Assignment-specific file
#     information (instructor scripts, input files) and at locations specified
#     as relative paths in the assignment options. The assignment options are
#     appended to $scriptData to obtain the specific directory/file values.
#  -- $instructorUnitTest is relative path to instructor test[s].
#  -- $localFiles is relative path to files to be copied over to the
#     working directory. The full path is obtained by appending this to
#     $scriptData. I.e., "$scriptData/$localFile".
#     E.g., "UOM/sbrandle/CSE101/Python_ReadFile
#  -- $log_dir is where results files get placed
#     E.g., "WebCAT.data/?/SchoolName/..."
#  -- $script_home is where plugin files are.
#     E.g., config.plist, execute.pl
#  -- $working_dir is Tomcat temporary working dir
#     E.g., "/usr/local/tomcat5.5/temp/UOM/submitterWeb-CATName"

our $propfile     = $ARGV[0];	# property file name
our $cfg          = Config::Properties::Simple->new( file => $propfile );

our $localFiles   = $cfg->getProperty( 'localFiles', '' );
our $log_dir	  = $cfg->getProperty( 'resultDir'      );
our $script_home  = $cfg->getProperty( 'scriptHome'     );
our $working_dir  = $cfg->getProperty( 'workingDir'     );

our $timeout	  = $cfg->getProperty( 'timeout', 30    );
our $reportCount  = $cfg->getProperty( 'numReports', 0  );

#-------------------------------------------------------
# Scoring Settings
#-------------------------------------------------------
#   Notes:
#   -- coverageMetric is Boolean for now. May mess with degree of coverage later.
#   -- allStudentTestsMustPass has apparently had many types of input. Swiped
#      the input tests from C++ tester.
our $maxCorrectnessScore     = $cfg->getProperty( 'max.score.correctness', 0 );
our $maxToolScore            = $cfg->getProperty( 'max.score.tools', 0 );
our $enableStudentTests      = $cfg->getProperty( 'enableStudentTests', 0 );
our $doStudentTests          = 
    ( $enableStudentTests      =~ m/^(true|on|yes|y|1)$/i );
our $measureCodeCoverage     = $cfg->getProperty( 'coverageMetric', 0 );
our $doMeasureCodeCoverage   =
    ( $measureCodeCoverage     =~ m/^(true|on|yes|y|1)$/i );
our $allStudentTestsMustPass = $cfg->getProperty( 'allStudentTestsMustPass', 0 );
    $allStudentTestsMustPass =
    ( $allStudentTestsMustPass =~ m/^(true|on|yes|y|1)$/i );
#   Keep directives in agreement.
    $doStudentTests = 1 if $doMeasureCodeCoverage || $allStudentTestsMustPass;

#-------------------------------------------------------
#   Feedback Settings
#-------------------------------------------------------
our $hintsLimit              = $cfg->getProperty( 'hintsLimit', 3 );
our $showExtraFeedback       = $cfg->getProperty( 'showExtraFeedback', 0 );
    $showExtraFeedback      =
    ( $showExtraFeedback       =~ m/^(true|on|yes|y|1)$/i );
our $hideHintsWithin         = $cfg->getProperty( 'hideHintsWithin', 0 );
our $dueDateTimestamp        = $cfg->getProperty( 'dueDateTimestamp', 0 );
our $submissionTimestamp     = $cfg->getProperty( 'submissionTimestamp', 0 );
#   Adjust time from milliseconds to seconds
    $dueDateTimestamp    /= 1000;
    $submissionTimestamp /= 1000;
#   Within extra feedback blackout period if 
#   (1) hideHintsWithin != 0 (covered by multiplication below), and
#   (2) submission time >= (due date - hideHintsWithin time) 
#   else will provide extra feedback if requested.
#   The reason for the extra variable is to be able to generate a message
#   to the effect that extra help would have been available if the student
#   had submitted earlier.
our $extraFeedbackBlackout   = 
    int ($submissionTimestamp + $hideHintsWithin * 3600 * 24 >= $dueDateTimestamp);
#   Turn extra feedback off within extra feedback blackout period.
    $showExtraFeedback       = $showExtraFeedback && !$extraFeedbackBlackout;

#-------------------------------------------------------
#   Language (Python) Settings
#-------------------------------------------------------
#   -- None at present
#   Script Developer Settings
our $debug                   = $cfg->getProperty( 'debug', 0 );

our $NTprojdir               = $working_dir . "/";

#   Considering borrowing this from C++ grader, but not currently active.
#our %status = (
#    'studentHasSrcs'     => 0,
#    'studentTestResults' => undef,
#    'instrTestResults'   => undef,
#    'toolDeductions'     => 0,
#    'compileMsgs'        => "",
#    'compileErrs'        => 0,
#    'feedback'           => undef,
#        #new Web_CAT::FeedbackGenerator( $log_dir, 'feedback.html' ),
#    'instrFeedback'      => undef,
#        #new Web_CAT::FeedbackGenerator( $log_dir, 'staffFeedback.html' )
#);

#-------------------------------------------------------
#   Local file location definitions within this script
#-------------------------------------------------------
if ( ! defined $log_dir )    { print "log_dir undefined"; }
our $script_log_relative      = "script.log";
our $script_log               = "$log_dir/$script_log_relative";
if ( ! defined $script_log ) { print "script_log undefined"; }
our $student_code_relative    = "student-code.txt";
our $student_code             = "$log_dir/$student_code_relative";

our $instr_output_relative    = "instructor-unittest-out.txt";
our $instr_output             = "$log_dir/$instr_output_relative";
our $instr_rpt_relative       = "instr-unittest-report.html";
our $instr_rpt                = "$log_dir/$instr_rpt_relative";

our $student_output_relative  = "student-unittest-out.txt";
our $student_output           = "$log_dir/$student_output_relative";
our $student_rpt_relative     = "student-unittest-report.html";
our $student_rpt              = "$log_dir/$student_rpt_relative";

# Will append a "-moduleName.txt" to each file. Doesn't exactly 
# follow approach of other report files, but seemed better this way.
our $coverage_output_relative = "student-coverage";
our $coverage_output          = "$log_dir/$coverage_output_relative";
our $coverage_rpt_relative    = "student-coverage-report.html";
our $coverage_rpt             = "$log_dir/$coverage_rpt_relative";
our $covfileRelative          = "test.cov";

our $timeout_log_relative     = "timeout_log.txt";
our $timeout_log              = "$log_dir/timeout_log";
our $debug_log                = "$log_dir/debug.txt";
our $testLogRelative          = "justTesting.log";
our $testLog                  = "$log_dir/$testLogRelative";

our $explain_rpt_relative     = "explanation_report.html";
our $explain_rpt              = "$log_dir/$explain_rpt_relative";

our $stdinInput               = '/dev/null';

#-------------------------------------------------------
#   Other local variables within this script
#-------------------------------------------------------
our $student_src      = "";
our $can_proceed      = 1;
our $timeout_occurred = 0;
our $version          = "0.6";
our $delete_temps     = 0;    # Change to 0 to preserve temp files
our $studentTestMsgs  = "";
our $expSectionId     = 0;    # For the expandable sections

if(0) {
adminLog( "
localFiles              = $localFiles
log_dir                 = $log_dir
script_home             = $script_home
working_dir             = $working_dir
maxCorrectnessScore     = $maxCorrectnessScore
maxToolScore            = $maxToolScore
enableStudentTests      = $enableStudentTests
measureCodeCoverage     = $measureCodeCoverage
allStudentTestsMustPass = $allStudentTestsMustPass
hintsLimit              = $hintsLimit
debug                   = $debug
" );
}

#-----------------------------
#   Python interpreter to use
#   Std linux: Improve portability later. Do some minimal testing.
#   Set a default, then check environment for python location. 
#   Die if can't find an executable.
#-----------------------------
my $python_interp  = "/usr/bin/python";
#  If PYTHON_HOME is set and meaningful, switch to use it.
if ( defined( $ENV{'PYTHON_HOME'} ) && $ENV{'PYTHON_HOME'} ne "" )
{
   $python_interp  = $ENV{'PYTHON_HOME'} 
}
-x $python_interp || die "$python_interp doesn't exist";

#  If PYTHONPATH is not defined or is empty, set PYTHONPATH.
my $python_path  = "/usr/lib/python2.5:.";      # How to include correct srch path?
if ( ! defined( $ENV{'PYTHONPATH'} ) || $ENV{'PYTHONPATH'} eq "" )
{
   $ENV{'PYTHONPATH'} = "${python_path}";
}

my $coverage_exe  = "/usr/bin/coverage";        # Where coverage is
#   This is required by the python program 'coverage' to place results
#   in more visible file location.
$ENV{'COVERAGE_FILE'} = $covfileRelative;       # Specify output file name


#=============================================================================
# Locate instructor unit test implementation
#=============================================================================
my $scriptData = $cfg->getProperty( 'scriptData', '.' );

$scriptData =~ s,/$,,;

## Should be renamed to "generateFullScriptPath"?
## 
sub findScriptPath
{
    my $subpath = shift;
    my $target = "$scriptData/$subpath";
    if ( -e $target )
    {
	return $target;
    }
    die "cannot file user script data file $subpath in $scriptData";
}

# instructorUnitTest
my $instr_src;
{
    my $instructor_unit_test = $cfg->getProperty( 'instructorUnitTest' );
    if ( defined $instructor_unit_test && $instructor_unit_test ne "" )
    {
	$instr_src = findScriptPath( $instructor_unit_test );
    }
}
if ( !defined( $instr_src ) )
{
    die "Instructor unit test not set.";
}
elsif ( (! -f $instr_src) && (! -d $instr_src) )
{
    die "Instructor unit test '$instr_src' not found.";
}


#=============================================================================
#   Script Startup
#=============================================================================
#   Change to specified working directory and set up log directory
chdir( $working_dir );
print "working dir set to $working_dir\n" if $debug;

#   Try to deduce whether or not there is an extra level of subdirs
#   around this assignment. 
#   FIXME: This may not be needed for Python.
{
    # Get a listing of all file/dir names, including those starting with
    # dot, then strip out . and ..
    my @dirContents = grep(!/^(\.{1,2}|META-INF)$/, <* .*> );

    # if this list contains only one entry that is a dir name != src, then
    # assume that the submission has been "wrapped" with an outter
    # dir that isn't actually part of the project structure.
    if ( $#dirContents == 0 && -d $dirContents[0] && $dirContents[0] ne "src" )
    {
        # Strip non-alphanumeric symbols from dir name
        my $dir = $dirContents[0];
        if ( $dir =~ s/[^a-zA-Z0-9_]//g )
        {
            if ( $dir eq "" )
            {
                $dir = "dir";
            }
            rename( $dirContents[0], $dir );
        }
        $working_dir .= "/$dir";
        chdir( $working_dir );
    }
}

if ($debug)
{
    print "working dir set to $working_dir\n";
    print "PYTHON_HOME  = ", $ENV{PYTHON}, "\n";
    print "PYTHONPATH   = ", $ENV{PYTHONPATH}, "\n";
    print "PATH         = ", $ENV{PATH}, "\n\n";
}

#-----------------------------------------------
# Copy over input/output data files as necessary
# localFiles
{
    my $localFiles = $cfg->getProperty( 'localFiles' );
    if ( defined $localFiles && $localFiles ne "" )
    {
        my $lf = confirmExists( $scriptData, $localFiles );
        print "localFiles = $lf\n" if $debug;
        if ( -d $lf )
        {
            print "localFiles is a directory\n" if $debug;
            copyHere( $lf, $lf, \@beautifierIgnoreFiles );
        }
        else
        {
            print "localFiles is a single file\n" if $debug;
            my $base = $lf;
            $base =~ s,/[^/]*$,,;
            copyHere( $lf, $base, \@beautifierIgnoreFiles );
        }
    }
}


#-----------------------------------------------
# Generate a script warning
sub adminLog {
    print "script_log undefined" if ! defined $script_log;
    open( SCRIPTLOG, ">>$script_log" ) ||
        die "Cannot open file for output '$script_log': $!";
    print SCRIPTLOG join( "\n", @_ ), "\n";
    close( SCRIPTLOG );
}

sub studentLog
{
    open( SCRIPT_LOG, ">>$script_log" ) ||
	die "cannot open $script_log: $!";
    print SCRIPT_LOG @_;
    close( SCRIPT_LOG );
}


#=============================================================================
# Find the student implementation file to use. The file should be named
# name be something like "className.py" (*.py).
#=============================================================================
# Temporarily comment out. The instructor's test program finds the student's
# implementation, so don't need this.
if(0) 
{
    my @sources = (<*.py>);
    if ( $#sources < 0 || ! -f $sources[0] )
    {
	studentLog( "<p>Cannot identify a Python source file ('.py' file).\n",
		    "Did you call it something like 'classname.py?</p>\n" );
	$can_proceed = 0;
    }
    else
    {
	## What is correct behavior here? Should run one test per class, no? - sb
	$student_src = $sources[0];
	if ( $#sources > 0 )
	{
	    studentLog( "<p>Multiple Python source files present.  Using ",
			"$student_src.\nIgnoring other Python files.",
			"</p>\n" );
	}
    }

    if ( $debug > 0 ) {
	print "Student source = $student_src\n";
    }
}

#=============================================================================
# A subroutine for executing a program/collecting the output
#=============================================================================
sub run_test
{
    my $cmd           = shift;
    my $unitTesterDir = shift;
    my $name          = shift;
    my $title         = shift;
    my $temp_input    = shift;
    my $outfile       = shift;
    my $resultReport  = shift;      # HTML output report of testing
    my $resultReportRelative = shift;      # HTML output report of testing
    my $show_details  = shift;

    ## Local variables
    my @testScripts;               # The set of test scripts to run
    # Track whether there was a compiler/interpreter/execution error
    my $execution_failed = 0;

    adminLog("
===== START - RUN THE TEST PARAMS =====
About to run the test. 'run_test' parameters are as follows:
cmd          = $cmd
args         = $unitTesterDir
name         = $name
title        = $title
temp_input   = $temp_input
outfile      = $outfile
resultReport = $resultReport
show_details = $show_details
===== END - RUN THE TEST PARAMS =====\n\n"
    );
    # Build an array of unit tester files.
    my $testScript = $unitTesterDir;

    if ( -f $testScript ) 
    {
	push( @testScripts, $testScript );
    }
    elsif ( -d $testScript ) {
	@testScripts = <${testScript}/*tests.py>;
    }
    else {
	die "No runnable instructor script found.";
    }

    ## START OF LOOP PROCESSING ALL UNIT TESTER FILES
    foreach( @testScripts ) {
	my $script = $_;
	my $testModuleName = basename( $script );
	my $moduleName = "";
	if ( $testModuleName =~ m/(.+)(test[s]?)\.py/i )
        {
	    $moduleName = $1 . ".py";
	}
	# Log that we're starting to process a specific test script
	open( RESULT_REPORT, ">>$outfile" ) ||
	    die "cannot open $outfile";
	print RESULT_REPORT "TEST START: Processing $testModuleName\n";
	close( RESULT_REPORT );
	#$num_cases++;
	#print "Running the $script script.\n";    
    
	my $cmdline = "$Web_CAT::Utilities::SHELL"
	    . "$python_interp $script 2>>$outfile";

	# Exec program and collect output
	my ( $exitcode, $timeout_status ) = 
	     Proc::Background::timeout_system( $timeout, $cmdline );
	
	$exitcode = $exitcode>>8;    # Std UNIX exit code extraction.
	# FIXME: Python sets the exit code to 1 if pyunit has any failed cases.
	# Not good! But, this is a hack to get past that for now.
	# Will need a better solution to to decide whether exec blew up.
	# Could possibly check $outfile to distinguish between the two cases.
	die "Exec died: $cmdline" if ( $exitcode < 0 || $exitcode > 1 );

        open( TEST_OUTPUT, "$outfile" ) ||
	die "Cannot open file for input '$outfile': $!";

	if ( $timeout_status )
	{   
	    if ( $@ )
	    {
		# timed out
		$timeout_occurred++;
		adminLog("Script thinks that a timeout happened.\n" .
			 "Timeout value = $timeout\n");

		$can_proceed = 0;

		my $timeOutFeedbackGenerator = new Web_CAT::FeedbackGenerator( $timeout_log );
		$timeOutFeedbackGenerator->startFeedbackSection( "Errors During Testing" );
		$timeOutFeedbackGenerator->print( <<EOF );
<p><font color="#ee00bb">Testing your solution exceeded the allowable time
limit for this assignment.</font></p>
<p>Most frequently, this is the result of <b>infinite recursion</b>--when
a recursive method fails to stop calling itself--or <b>infinite
looping</b>--when a while loop or for loop fails to stop repeating.</p>
<p>As a result, no time remained for further analysis of your code.</p>
EOF
		$timeOutFeedbackGenerator->endFeedbackSection;
		$timeOutFeedbackGenerator->close;
		# Add to list of reports
		# -----------
		$reportCount++;
		$cfg->setProperty( "report${reportCount}.file",
				   $timeout_log_relative );
		$cfg->setProperty( "report${reportCount}.mimeType", "text/html" );
	    }
	}

    } ## END OF LOOP PROCESSING ALL UNIT TESTER FILES
      ## Output from all unit testers was appended to the same file, "$outfile".

    #=========================================================================
    # Compare the output to test case expectations
    #=========================================================================

    if ( $can_proceed )
    {
    my $last_failed = -1;   # index of last failed case
    my $num_cases   = 0;
    my $failures    = 0;    # count of failures
    my $errors      = 0;    # Number of runtime errors, which is 0 or 1 since
    			    # such an error crashes the program
    my $has_hints   = 0;

    my $messages    = "";   # The collection of messages to output for a test.
    my $assertMsgs  = "";   # Output of assert messages

    open( TEST_OUTPUT, "$outfile" ) ||
	die "Cannot open file for input '$outfile': $!";

    my $unitTesterOutput = "";
    while ( <TEST_OUTPUT> )
    {
	chomp;

	s,\Q$working_dir\E(/?),,o;
	s,\Q$log_dir\E(/?),,o;
	# Syntax error: things blew up.
	# Should probably do something better with this.
	# FIXME: Leaving it here as a placeholder.
	if ( m/^SyntaxError:.+$/o )
	{
	    $unitTesterOutput .= $_ . "Stopping test.\n";
	    $can_proceed = 0;
	}
	while ( length( $_ ) > 78  &&  $_ =~ m/^[.EF]+$/o && 
                !( $_ =~ m/ERROR|FAILURE/o ) )
	{
	    $unitTesterOutput .= substr( $_, 0, 78 ) . "\n";
	    $_ = substr( $_, 78 );
	}
        # Deals with printing out [.FE] when line <= 78. Above only deals
        # with the overflow on really long lines.
	if ( m/^[.EF]+$/o )
	{
	    $unitTesterOutput .= $_ . "\n" ;
	}
	# "TEST START: .*" comes from this program, not pyunit.
	elsif ( m,^TEST START: Processing (.+)$,o )
	{
	    # $1 should be the module being tested
	    if( $1 ne "" ) {
                my $moduleName = $1;
                $moduleName =~ s,(.+)tests.py,$1,; 
		$unitTesterOutput .= "\nTesting module '" . 
                                            $moduleName . "'\n";
	    }
	}
	# Had a runtime error or a test failure on one unit test.
	# "ERROR: Test removing a valid book from library"
	# "FAIL: Test getting number of books"
	elsif ( m/^(ERROR|FAIL): (.+)$/o )
	{
	    # FIXME: should this count as "extra feedback"?
	    # Could show which tests failed, without giving
	    # details about what failed. For now, choosing
	    # not to count this as extra feedback.
	    # To change, comment out the three relevant lines.
	    if( $showExtraFeedback )
	    {
		$unitTesterOutput .= "------------------\n";
		# Depends on the test function doc string existing
		if( $1 ne "" ) {
		    $unitTesterOutput .= $_ . "\n";
		}
	    }
	}
        # "AssertionError: Number of books reported incorrectly"
	# "ZeroDivisionError: integer division or modulo by zero"
	elsif ( m/^.*Error: (.+)$/o )
	{
	    if( $showExtraFeedback )
	    {
		# Depends on the value of last parameter to the assert func()
		if( $1 ne "" ) {
		    $unitTesterOutput .= $_ . "\n";
		}
	    }
	}
	# Report that unit test did not pass (at least one failure or error).
	# Possible input follows formats below. I have made decision to have
	# perl die if pyunit's format changes; we need to know that right away.
	elsif ( m/^FAILED \(/o )
	{
	    # "FAILED (failures=1, errors=2)"
	    if ( m/\(failures=([0-9]+), errors=([0-9]+).*\)/o ) {
		$failures += $1;
		$errors   += $2;
	    }
	    # "FAILED (failures=1)"
	    elsif ( m/\(failures=([0-9]+)\)/o ) {
		$failures += $1;
	    }
	    # "FAILED (errors=2)"
	    elsif ( m/\(errors=([0-9]+)\)/o ) {
		$errors   += $1;
	    }
	    else { die "Testing script died: pyunit FAILED. Report format has changed!"; }
	    $unitTesterOutput .= $_ . "\n";
	}
        # The happier alternative to "FAILED (....)" above.
        # "OK"
	elsif ( m/^OK$/o )
	{
	    $unitTesterOutput .= $_ . "\n";
	}
	# Pick up final report of number of cases run.
	# "Ran 1 test in 0.001s"
	# "Ran 3 tests in 0.003s"
	elsif ( m/Ran (\d+) test[s]? in/o )
	{
	    $num_cases += $1;
	    $unitTesterOutput .= "------\n";
	    $unitTesterOutput .= $_ . "\n";
	}
	# FIXME: Not currently doing hints, but keep as placeholder.
	# Could use the AssertionError strings as hints?
	# E.g., "AssertionError: Number of books reported incorrectly"
	# Or could just print  "^hint: hint_msg" and snag it here.
	elsif ( !$has_hints && m/^hint:/o )
	{
	    if( $showExtraFeedback )
	    {
		$unitTesterOutput .= $_;
		$has_hints++;
		adminLog("Found a hint: " . $_ . "\n");
	    }
	}
    }

    # Done processing test output
    close( TEST_OUTPUT );

    # Compute overall values
    my $succeeded = $num_cases - $failures - $errors;
    my $eval_score = ( $num_cases > 0 )
	? $succeeded/($num_cases*1.0)
	: 0;

# FIXME: It might be a good idea to get this working instead of 
#     continuing with how it do it in major block above?
# Try faking Web_CAT::JUnitResultsReader results for instructor
# Web_CAT::PyUnitResultsReader -> 
#     new( hasResults, testsExecuted, allTestsPass, testsFailed )
#
#$status{'instrTestResults'} = Web_CAT::PyUnitResultsReader->
#    new( 1, $num_cases > 0, $succeeded == $num_cases, $succeeded == $num_cases );

    my $testsExecuted = $num_cases;
    my $allTestsPass = $succeeded == $num_cases;
    my $sectionTitle = "$title ";
    if ( $testsExecuted == 0 )
    {
	# This used to say "no tests submitted". That might be true, but
	# it is more likely that the student messed up. 
	# Be vague and sort of blame them.  :-)
        $sectionTitle .=
            "<b class=\"warn\">(No Testable Files Found!)</b>";
    }
    elsif ( $allTestsPass )
    {
        $sectionTitle .= "(100%)";
    }
    else
    {
        my $studentCasesPercent = 
	        $allTestsPass ? 
		100 : 
		sprintf( "%.1f", $eval_score * 100 );
        $sectionTitle .= "<b class=\"warn\">($studentCasesPercent%)</b>";
    }

    #--------------------------------
    # Fire up the feedback generator
    my $feedbackGenerator = new Web_CAT::FeedbackGenerator( $resultReport );

    # startFeedbackSection( title, report number, 
    #     initially collapsed (1) or expanded (0) )
    $feedbackGenerator->startFeedbackSection( 
             $sectionTitle,
             ++$expSectionId,
             1 );

    my $casesPlural = ($num_cases!=1) ? "s" : "";
    my $failuresPlural = ($failures!=1) ? "s" : "";
    my $errorsPlural = ($errors!=1) ? "s" : "";
    $feedbackGenerator->print( "Summary: $num_cases case" . $casesPlural
             . " ($failures failure" . $failuresPlural
	     . ", $errors error" . $errorsPlural . ")<br>\n" );

    # Inform student that extra feedback is being withheld if we are within
    # the extra feedback blackout period. NOTE: because $extraFeedback is
    # turned off if within blackout period, the extra feedback was already
    # suppressed at the point when it would normally have been produced.
    # Don't have to do anything extra here, other than inform student of
    # their misfortune.
    if ( $extraFeedbackBlackout && ! $allTestsPass ) 
    {
           $feedbackGenerator->print( 
	     "<p>Your instructor has choosen to cut off extra feedback "
	     . "$hideHintsWithin day(s) before the due date. Consequently, "
	     . "no extra feedback will be given.</p>\n"
	   );
    }
    # FIXME: Do we hide details if all tests pass? 
    # If all is well, why report? On the other hand, students may be happy
    # to see details of passing tests, even if there are few details.
    # Currently choosing not to report if all is well.
    if( ! $allTestsPass )
    {
	$feedbackGenerator->print( "<pre>\n" );
	$feedbackGenerator->print( $unitTesterOutput );
	$feedbackGenerator->print( "</pre>\n" );
    }
    $feedbackGenerator->endFeedbackSection;

    # Close down this report
    $feedbackGenerator->close; 
    $reportCount++;
    $cfg->setProperty( "report${reportCount}.file",     $resultReportRelative );
    $cfg->setProperty( "report${reportCount}.mimeType", "text/html"       );

adminLog("Return values from processing are: \n
eval_score = $eval_score,
succeeded  = $succeeded,
num_cases  = $num_cases\n");

	return ( $eval_score, $succeeded, $num_cases );
    }   # End of "if ($can_proceed ) ..."
    else
    {
	# Things blew up.
	return (0, 0, 1);
    }
}


#=============================================================================
# A subroutine for processing student unit test coverage.
#=============================================================================
sub run_coverage
{
    my $cov_outfile_relative  = shift;
    my $cov_outfile           = shift;
    my $cov_rpt_relative      = shift;
    my $cov_rpt               = shift;

    # Build the coverage test file lists:
    # (1) The list of unit test files to be executed.
    # (2) The list of tested files to have coverage evaluated.
    # All files should be in the current directory: viz $working_dir.
    # If no test files were submitted, this function should not have been
    # called, so we have relative assurance that there is at least one
    # test file present. But do a sanity check below loop anyway.

    my @allScripts = <*.py>;
    my @unitTestScripts;            # All "*test[s]?.py"
    my @testedScripts;              # All *.py that don't match "*test[s]?"
    my @testedScripts2;             # To test hypothesis about #1 getting trashed

    # Hash structure is hash of arrays.
    # Index is tested file name (e.g., "book.py".
    # Referenced array is ( moduleName, stmts, stmtsExec ).
    my %coveredFiles;     
    my $coveredFileCount = 0;
    foreach( @allScripts ) {
	if ( m/(.*)tests?\.py/i ) {              # It is a test script
            push( @unitTestScripts, $_ );        # Build list of testers
	    my $moduleName = $1;
	    my $fileName = $1 . ".py";
            push( @testedScripts, $fileName ); # Build list of tested
push( @testedScripts2, $fileName );
	    # E.g., "book.py" => ( "book", 0 stmts, 0 stmtsExec )
	    $coveredFiles{$fileName} = [ $moduleName, 0, 0 ];
	    $coveredFileCount++;    # Don't know if still needed.
	} 
    }

    print "Testing contents of testedScripts array.\n";
    foreach( @testedScripts ) {
        print "Script = " . $_ . "\n";
    }
    # Sanity check.
    #if $#unitTestScripts < 0;
    #if $#testedScripts < 0;

    # How to process test coverage:
    #
    # "coverage -x ${file}test.py" to create the '.coverage' file in 
    #    current dir.
    #
    # "coverage -r ${file}.py" to report on the coverage for $file.
    #    E.g., "coverage -r library.py" =>
    #    Name      Stmts   Exec  Cover
    #    -----------------------------
    #    library      17     16    94%
    #
    # "coverage -a ${file}.py" to generate the annotated coverage 
    #    document for $file in output name "${file}.py,coverage".
    #    "-d DIRECTORY" lets you specify the destination directory.
    #    E.g., "coverage -a library.py" generates "library.py,coverage".
    # Lines that start with a '>' were tested, lines that start with a
    #    '!' were not tested, and lines that start with ' ' were not
    #    executable (e.g., white space only, comment lines).

    #----------------------------
    # First run unit test scripts to generate statistics.
    # Coverage 2.85 appears to want the scripts to be executed 
    # one at a time. So loop through them.
    foreach( @unitTestScripts ) {
        my $cmdline = "$Web_CAT::Utilities::SHELL"
	. "$coverage_exe -x $_ 2>>$log_dir/coverage_stats_gen.txt";

	# Exec program and collect output
	my ( $exitcode, $timeout_status ) = 
	     Proc::Background::timeout_system( $timeout, $cmdline );
	
	# FIXME: See run_tests for details about exit code problems.
	$exitcode = $exitcode>>8;    # Std UNIX exit code extraction.
	die "Exec died: $cmdline" if ( $exitcode < 0 || $exitcode > 1 );
    }

    # Index is tested file name (e.g., "book.py".)
    # Referenced array is ( moduleName, stmts, stmtsExec ).
    #----------------------------
    # Second, run report statistics for tested scripts.
    my $totalStmts     = 0;
    my $totalStmtsExec = 0;
    my $coverageOutput = "";
    my $coverageScore  = 0;

    foreach( @testedScripts ) 
    {
	my $file = $_;
	my $testedModuleName = $coveredFiles{$file}[0];
	my $resultsFile      = "$cov_outfile-$testedModuleName.txt";
	my $cmdline = "$Web_CAT::Utilities::SHELL"
	   . "$coverage_exe -r $file >> $resultsFile";

	# Exec program and collect output
	my ( $exitcode, $timeout_status ) = 
	     Proc::Background::timeout_system( $timeout, $cmdline );
	
	# FIXME: See run_tests for details about exit code problems.
	$exitcode = $exitcode>>8;    # Std UNIX exit code extraction.
	die "Exec died: $cmdline" if ( $exitcode < 0 || $exitcode > 1 );

	# Now open output and parse.
	open( COVERAGE_OUTPUT, "$resultsFile" ) ||
	    die "Cannot open file for input '$resultsFile";

        while ( <COVERAGE_OUTPUT> )
	{
	    #       "moduleName   stmts  exec  d+%"
	    # E.g., "TOTAL        23     22    95%"
	    if ( m/^\S+\s+(\d+)\s+(\d+)\s+\d+%/o )
	    {
		# [0]=modName, [1]=stmts, [2]=stmtsExec
		$totalStmts     += $1;
		$totalStmtsExec += $2;
		$coveredFiles{$file}[1] = $1;
		$coveredFiles{$file}[2] = $2;
	    }
	}
	close( COVERAGE_OUTPUT );
    }
# KILLME when done. For some reason, @testedScripts is getting messed up
# in the loop above. It still has items, but the values have been set
# to empty strings. No idea why. I currently hate perl! -sb
# Solution was to create a second array that can be used later. Yuck.
foreach( @testedScripts2 ) {
    my $f = $_;
    print "Array #2. Script = " . $f . "\n";
}
    #--------------------------------
    # Fire up the feedback generator
    my $feedbackGenerator = new Web_CAT::FeedbackGenerator( $cov_rpt );

    if( $totalStmts == $totalStmtsExec ) {
        $coverageScore = 100;
    } else {
        $coverageScore = (100.0 * $totalStmtsExec) / $totalStmts;
    }
    my $sectionTitle = "Code Coverage from Your Tests ";
    $coverageScore = sprintf( "%.1f", $coverageScore);
    if ( $coverageScore == 100 )
    {
        $sectionTitle .= "($coverageScore%)";
    }
    else
    {
        $sectionTitle .= "<b class=\"warn\">($coverageScore%)</b>";
    }
    # startFeedbackSection( title, report number, 
    #     initially collapsed (1) or expanded (0) )
    $feedbackGenerator->startFeedbackSection( 
             $sectionTitle,
             ++$expSectionId,
             1 );

    my $plural = ($coveredFileCount>1) ? "s" : "";
    $feedbackGenerator->print( "Summary: tested $totalStmtsExec of $totalStmts "
                     . "total statements in $coveredFileCount file"
		     . $plural
		     . " for $coverageScore% coverage.<br/ >\n" );
    # FIXME: Have a choice about whether to not show coverage of statements
    # if within extra feedback blackout period.
    if ( $coverageScore != 100 && $extraFeedbackBlackout ) 
    {
           $feedbackGenerator->print( 
	     "<p>Your instructor has choosen to cut off extra feedback "
	     . "$hideHintsWithin day(s) before the due date. Consequently, "
	     . "you will not be shown which lines are not being tested by "
	     . "your tests.</p>\n"
	   );
    }
    $feedbackGenerator->print( "<pre>\n" );
    $feedbackGenerator->print( $coverageOutput );

    die "Coverage testing: no unit test scripts found." if $#unitTestScripts < 1;
    die "Coverage testing: no tested scripts found." if $#testedScripts < 1;
    # Only generate annotated files if score is  not 100%
    if( $coverageScore != 100 )
    {
	my $annotatedLines = "";
	#----------------------------
	# Third, generate annotated files. Loop through each tested file.
	# If all is well, there should be no output. (I think.)
	foreach ( @testedScripts2 ) {
	    my $file = $_;
	    if( $coveredFiles{$file}[1] == $coveredFiles{$file}[2] )
	    {
                $annotatedLines .= "module '"
		    . $coveredFiles{$file}[0] . "' has 100% coverage\n";
	    }
	    else
	    {
                $annotatedLines .= "module '"
		    . $coveredFiles{$file}[0] . "' has "
		    . $coveredFiles{$file}[2] . "/" 
		    . $coveredFiles{$file}[1] . " executable lines covered (" 
		    . sprintf("%.1f", $coveredFiles{$file}[2] * 100.0 /
		                      $coveredFiles{$file}[1]) 
		    . "%)\n";
		if( $showExtraFeedback )
		{
print "showExtraFeedback is turned on.\n";
		    my $cmdline = "$Web_CAT::Utilities::SHELL"
		       . "$coverage_exe -d $log_dir -a $file";
		    # Exec program and collect output
		    my ( $exitcode, $timeout_status ) = 
			  Proc::Background::timeout_system( $timeout, $cmdline );
		    
		    # FIXME: See run_tests for details about exit code problems.
		    $exitcode = $exitcode>>8;    # Std UNIX exit code extraction.
		    die "Exec died: $cmdline" if ( $exitcode < 0 || $exitcode > 1 );

		    open( ANNOTATED_SCRIPT, "$log_dir/$file,cover" ) ||
			die "Cannot open file for input '$file,cover': $!";
		    $annotatedLines .= "<h3>$file</h3>";
		    while( <ANNOTATED_SCRIPT> )
		    {
			chomp;
			if ( m/^! /o )
			{
			    $annotatedLines .= "<span style=\"background-color:#F0C8C8\">"
			    . substr( $_, 2 )
			    . "</span>\n";
			}
			else
			{
			    $annotatedLines .= substr( $_, 2 ). "\n";
			}
		    }

		    close( ANNOTATED_SCRIPT );
	        } # if showExtraFeedback
	    } # end else (! 100%)
	} # end foreach
	$feedbackGenerator->print( $annotatedLines );
    }

    $feedbackGenerator->print( "</pre>\n" );
    $feedbackGenerator->endFeedbackSection;

    # Close down this report
    $feedbackGenerator->close; 
    $reportCount++;
    $cfg->setProperty( "report${reportCount}.file",     $cov_rpt_relative );
    $cfg->setProperty( "report${reportCount}.mimeType", "text/html"       );

    # Normalize into 0-1 range.
    return $coverageScore / 100.0;
}

#=============================================================================
# A subroutine to explain results score
#=============================================================================
sub explain_results
{
    my $doStudentTests          = shift; 
    my $doMeasureCodeCoverage   = shift;
    my $allStudentTestsMustPass = shift;
    my $totalScore              = shift;
    my $studentCasesPercent     = shift;
    my $codeCoveragePercent     = shift;
    my $instructorCasesPercent  = shift;
    my $maxCorrectnessScore     = shift;
    
    $totalScore = int( $totalScore * 10 + 0.5 ) / 10;
    $studentCasesPercent = int( $studentCasesPercent * 10 + 0.5 ) / 10;
    $codeCoveragePercent = int( $codeCoveragePercent * 10 + 0.5 ) / 10;
    $instructorCasesPercent = int( $instructorCasesPercent * 10 + 0.5 ) / 10;
    my $possible = int( $maxCorrectnessScore * 10 + 0.5 ) / 10;
    my $mustNotReportAllTests = 
       int( $allStudentTestsMustPass && $studentCasesPercent < 99.99 ); 
    my $feedbackGenerator = 
       new Web_CAT::FeedbackGenerator( $explain_rpt );
    $feedbackGenerator->startFeedbackSection(
        "Interpreting Your Correctness/Testing Score "
        . "($totalScore/$possible)",
        ++$expSectionId,
        1 );
    my $feedbackStr = "";
    if( $mustNotReportAllTests )
    {
       $feedbackStr .= "<p>This assignment requires that all student tests pass "
                    . "before any other results are computed.<br/ >Because some "
		    . "of your tests failed, only the results of your testing "
		    . "are shown and your score will be zero until your code "
		    . "passes all your tests.</p>\n";
    }
    $feedbackStr .= "<table style=\"border:none\">\n";
    my $feedbackStr2 = "<tr><td colspan=\"2\">score =";

    if( $doStudentTests )
    {
	$feedbackStr .=
	"<tr><td><b>Results from running your tests:</b></td>\n"
	. "<td class=\"n\">$studentCasesPercent%</td></tr>\n";
	$feedbackStr2 .= " $studentCasesPercent% ";
	if( $doMeasureCodeCoverage && ($mustNotReportAllTests==0) )
	{
	    $feedbackStr .=
		"<tr><td><b>Code coverage from your tests:</b></td>\n"
		. "<td class=\"n\">$codeCoveragePercent%</td></tr>\n";
	    $feedbackStr2 .= " * $codeCoveragePercent%";
	}
    }
    if( $mustNotReportAllTests )
    {
        $feedbackStr .= 
	  "<tr><td><b>No other tests attempted</b></td>\n"
	  . "<td class=\"n\">0%</td></tr>\n";
        $feedbackStr2 .= " * 0%";
    }
    else
    {
	$feedbackStr .=
	"<tr><td><b>Results from running your instructor's tests:</b></td>\n"
	. "<td class=\"n\">$instructorCasesPercent%</td></tr>\n";
	$feedbackStr2 .= " * $instructorCasesPercent%";
    }
    $feedbackStr2 .= 
        " * $maxCorrectnessScore points possible =\n"
	. "$totalScore</td></tr></table>\n"
	. "<p>Full-precision (unrounded) percentages are used to calculate "
	. "your score, not the rounded numbers shown above.</p>\n";
    $feedbackGenerator->print( $feedbackStr  );
    $feedbackGenerator->print( $feedbackStr2 );
    $feedbackGenerator->endFeedbackSection;
    $feedbackGenerator->close; 
    $reportCount++;
    $cfg->setProperty( "report${reportCount}.file",     $explain_rpt_relative );
    $cfg->setProperty( "report${reportCount}.mimeType", "text/html"       );
}

#=============================================================================
# Phases II and III: Execute the program and produce results
#=============================================================================
my $cmd = "$python_interp";
# FIXME: Run student coverage testing here. See instructor testing
#    for details.

# FIXME: This will need extra cleaning and parameter modification.
# Args to run_test
#    $cmd           command to run,
#    $unitTesterDir path to directory with unittesters
#    $name          name of program
#    $title         fancy name of program
#    $temp_input    redirected input source
#    $outfile       redirected output destination for text
#    $resultReport  absolute place to put the HTML report
#    $resultReportRelative  relative name to output the HTML report
#    $show_details  whether or not to show details -- Equal to $debug?
#                   maybe how much detail to show in report. 
#                   currently not using it, but could easily enough.

my $score = 1.0;
my @stu_eval;
$stu_eval[0] = 0.0;
my @instr_eval;
$instr_eval[0] = 0.0;
my $coverageResults = 0.0;

# To run student tests, need to meet the following conditions:
# (1) Running of student tests has been specified.
if( $doStudentTests ){
    @stu_eval = run_test( $cmd,
                          $working_dir,
			  "Student Testing",
			  "Results From Running Your Tests",
			  $stdinInput,
			  $student_output,
			  $student_rpt, 
			  $student_rpt_relative, 
			  1 );
    if ( !$timeout_occurred )
    {
	$cfg->setProperty( "studentEval", join( " ", @stu_eval   ) );
    }
    elsif ( $timeout_occurred )
    {
	open( SCRIPT_LOG, ">>$script_log" ) ||
	    die "cannot open $script_log: $!";
	print SCRIPT_LOG "\n",
	"Your program exceeded the allowed time limit while running your tests.\n";
	close( SCRIPT_LOG );
    }
}

# In order to do metrics computations, need to meet the following conditions:
# (0) Attempting to run student tests did not result in a blow up.
# (1) Code coverage computation is specified for this assignment.
# (2) Actually be doing student tests.
# (3) $allStudentTestsMustPass is false, or all student tests have passed.
if ( $can_proceed &&
     $doMeasureCodeCoverage &&
     $doStudentTests && 
     (! $allStudentTestsMustPass || $stu_eval[0] > 0.9999 ) )
{
    $coverageResults = run_coverage( 
           $coverage_output_relative,
           $coverage_output,
           $coverage_rpt_relative,
           $coverage_rpt
    );
}
#} # end of comment-out

# To run the instructor tests, need to meet one of the following conditions:
# (1) Only doing instructor tests ($doStudentTests == false), OR
# (2) Can proceed and 
#    (a) not requiring that all students tests must pass, or 
#    (b) they did pass.
# Run if student results not required, or if required but good enough.
if (( ! $doStudentTests ) ||
    (   $can_proceed &&
    ((! $allStudentTestsMustPass) || ($stu_eval[0] > 0.9999))) )
{
    @instr_eval   = run_test( $cmd,
			      $instr_src,
			      "Reference Implementation",
			      "Results From Running Your Instructor's Tests",
			      $stdinInput,
			      $instr_output,
			      $instr_rpt, 
			      $instr_rpt_relative, 
			      1 );
    if ( !$timeout_occurred )
    {
	$cfg->setProperty( "instructorEval", join( " ", @instr_eval   ) );
    }
    elsif ( $timeout_occurred )
    {
	open( SCRIPT_LOG, ">>$script_log" ) ||
	    die "cannot open $script_log: $!";
	print SCRIPT_LOG "\n",
	"Your program exceeded the allowed time limit while running your tests.\n";
	close( SCRIPT_LOG );
    }
}
else {
    # Print message about needing to pass student test cases first?
}

if( $doStudentTests )
{
    $score = $stu_eval[0];
    if( $doMeasureCodeCoverage && $score > 0.01 ) {
        $score *= $coverageResults;
    }
}
if( (! $allStudentTestsMustPass && $score > 0.01) || ($stu_eval[0] > 0.9999) )
{
    $score *= $instr_eval[0];
}

if ( $can_proceed && $doStudentTests )
{
    explain_results( $doStudentTests, 
                     $doMeasureCodeCoverage,
		     $allStudentTestsMustPass,
		     $score * 100.0,
                     $stu_eval[0] * 100.0,
		     $coverageResults * 100.0,
		     $instr_eval[0] * 100.0,
		     $maxCorrectnessScore );
}

# Scale to be out of range of $maxCorrectnessScore
$cfg->setProperty( "score.correctness", $score* $maxCorrectnessScore );
$cfg->setProperty( "numReports",      $reportCount );
adminLog("reportCount = " . $reportCount . "\n" );
$cfg->save();

if ( $debug )
{
    my $props = $cfg->getProperties();
    while ( ( my $key, my $value ) = each %{$props} )
    {
	print $key, " => ", $value, "\n";
    }
}

#-----------------------------------------------------------------------------
exit( 0 );

