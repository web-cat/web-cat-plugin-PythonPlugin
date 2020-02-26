#!/usr/bin/perl -w
#=============================================================================
#   Web-CAT Grader: plug-in for Jupyter Notebook     submissions
#=============================================================================
# Installation Notes:
# In the neighborhood of line 165, there are several python system-specific
# path settings that must be set to have the plugin work.

use strict;
use Config::Properties::Simple;
use File::Basename;
use File::Copy;
use File::Spec;
use File::stat;
use Proc::Background;
use Web_CAT::Beautifier;    ## Soon, I hope. -sb
use Web_CAT::FeedbackGenerator;
use Web_CAT::Utilities
    qw(confirmExists filePattern copyHere htmlEscape addReportFile scanTo
       scanThrough linesFromFile addReportFileWithStyle $FILE_SEPARATOR
       $PATH_SEPARATOR);

# Plugin-specific modules
use lib dirname(__FILE__) . '/perllib';
use JupyterPlugin::Utilities;
use JSON;

# PyUnitResultsReader: a hoped-for future development
#use Web_CAT::PyUnitResultsReader;

my @beautifierIgnoreFiles = ();

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
#     $scriptData. I.e., "$scriptData/$localFile".
#     E.g., "UOM/sbrandle/CSE101/Python_ReadFile
#  -- $log_dir is where results files get placed
#     E.g., "WebCAT.data/?/SchoolName/..."
#  -- $script_home is where plugin files are.
#     E.g., config.plist, execute.pl
#  -- $working_dir is Tomcat temporary working dir
#     E.g., "/usr/local/tomcat5.5/temp/UOM/submitterWeb-CATName"

my $propfile     = $ARGV[0];   # property file name
my $cfg          = Config::Properties::Simple->new(file => $propfile);

my $pluginHome   = $cfg->getProperty('pluginHome');
my $workingDir   = $cfg->getProperty('workingDir');
my $resultDir    = $cfg->getProperty('resultDir');
my $scriptData   = $cfg->getProperty('scriptData', '.');
$scriptData =~ s,/$,,;

my $timeout      = $cfg->getProperty('timeout', 30   );
# The values coming through don't match up with assignment settings.
# E.g., "15" comes through as "430". So this is a 'temporary' patch.
# And I can't access the timeoutInternalPadding, etc. from config.plist, so
# have to guess as to the adjustment to undo the padding and multiplying done
# by the subsystem..
if ($timeout >  100) { $timeout = ($timeout - 400) / 2; }
if ($timeout <  2) { $timeout = 15; }


#-------------------------------------------------------
# Scoring Settings
#-------------------------------------------------------
#   Notes:
#   -- coverageMetric is Boolean for now. May mess with degree of coverage later.
#   -- allStudentTestsMustPass has apparently had many types of input. Swiped
#      the input tests from C++ tester.
my $maxCorrectnessScore     = $cfg->getProperty('max.score.correctness', 0);
my $instructorNotebook      = confirmExists($scriptData,
    $cfg->getProperty('instructorUnitTest'));
my $isStaff = $cfg->getProperty('user.isStaff', 0);
$isStaff = ($isStaff =~ m/^(true|on|yes|y|1)$/i);



#-------------------------------------------------------
# Python Settings
#-------------------------------------------------------


#-------------------------------------------------------
#   Language (Python) Settings
#-------------------------------------------------------
#   -- None at present
#   Script Developer Settings
my $debug                   = $cfg->getProperty('debug', 0);


#-------------------------------------------------------
#   Other local variables within this script
#-------------------------------------------------------
my $studentNotebook  = "";
my $student_src      = "";
my $can_proceed      = 1;
my $timeout_occurred = 0;
my $score            = 0;
my $python           = $cfg->getProperty('pythonCmd', 'python');


#=============================================================================
# Script Startup
#=============================================================================
# Change to specified working directory and set up log directory
Web_CAT::Utilities::initFromConfig($cfg);
chdir($workingDir);
print "working dir set to $workingDir\n" if $debug;

# localFiles
{
    my $localFiles = $cfg->getProperty('localFiles');
    if (defined $localFiles && $localFiles ne '')
    {
        my $lf = confirmExists($scriptData, $localFiles);
        print "localFiles = $lf\n" if $debug;
        if (-d $lf)
        {
            print "localFiles is a directory\n" if $debug;
            copyHere($lf, $lf, \@beautifierIgnoreFiles);
        }
        else
        {
            print "localFiles is a single file\n" if $debug;
            $lf =~ tr/\\/\//;
            my $base = $lf;
            $base =~ s,/[^/]*$,,;
            copyHere($lf, $base, \@beautifierIgnoreFiles);
        }
    }
}

# Set python path
{
    my $cmdPath = $cfg->getProperty('pythonBinPath', '');
    if ($cmdPath ne '')
    {
        $ENV{'PATH'} = $cmdPath . ':' . $ENV{'PATH'};
    }

    #  Add script home to PYTHONPATH.
    if (! defined($ENV{'PYTHONPATH'}) || $ENV{'PYTHONPATH'} eq "")
    {
       $ENV{'PYTHONPATH'} = "$resultDir/pythonlib:$pluginHome/pythonlib:.:src";
    }
    else
    {
       $ENV{'PYTHONPATH'} = "$resultDir/pythonlib:$pluginHome/pythonlib:"
         . $ENV{'PYTHONPATH'} . ":.:src";
    }
    if ($debug)
    {
        print "PYTHON CMD   = $python\n",
            "PYTHON_HOME  = ",
            (defined $ENV{PYTHON} ? $ENV{PYTHON} : "[undefined]"),
            "\n",
            "PYTHONPATH   = ",
            (defined $ENV{PYTHONPATH} ? $ENV{PYTHONPATH} : "[undefined]"),
            "\n",
            "PATH         = ",
            (defined $ENV{PATH} ? $ENV{PATH} : "[undefined]"),
            "\n";
    }
}


#-----------------------------------------------
# Generate a script warning
my $report_message = '';
sub studentLog { $report_message .= shift; }


#=============================================================================
# Find the student implementation file to use. The file should be named
# name be something like "className.py" (*.py).
#=============================================================================
my $pngCount = 0;
{
    my @sources = (<*.ipynb>);
    if ($#sources < 0 || ! -f $sources[0])
    {
        studentLog( "<p>Cannot identify a Python source file.<br>"
            . "Please let your instructor know that something "
            . "has gone wrong.</p>\n" );
        $can_proceed = 0;
    }
    else
    {
        $studentNotebook = $sources[0];
        if ($#sources > 0)
        {
            studentLog( "<p>Multiple Python source files present.  Using ",
                "$student_src.\nIgnoring other Python files.",
                "</p>\n");
            $can_proceed = 0;
        }
        else
        {
            $student_src = $studentNotebook;
            $student_src =~ s/.ipynb$/.py/io;
            my $notebook = load_notebook($studentNotebook);
            my $lines = extract_solution($notebook);

            open(SRC, ">$student_src") ||
                die "Cannot open file for output '$student_src': $!";
            for my $line (@{$lines})
            {
                print SRC $line;
            }
            close(SRC);
            
            mkdir("$resultDir/public");
            $pngCount = extract_images($notebook, $cfg);
        }
    }

    if ($debug > 0)
    {
        print "Student source = $student_src\n";
    }
}


#=============================================================================
my $contents = load_notebook($instructorNotebook);
mkdir("$resultDir/pythonlib");
my $testFile = "$resultDir/pythonlib/instructor_tests.py";

# Generate test class
if (1)
{
    my $imports = extract_imports($contents);
    my $lines = extract_tests($contents);
    open(TESTS, ">$testFile") ||
        die "Cannot open file for output '$testFile': $!";
    print TESTS<<END;
import sys
import pythy
import nose.tools
$imports

# =============================================================================
class JupyterInstructorTests(pythy.TestCase):
  #~ Public methods ...........................................................

  # -------------------------------------------------------------
  def student_file_name(self):
    return '$student_src'


END
    for my $line (@{$lines})
    {
        print TESTS $line;
    }
    close(TESTS);
}


# Generate student template
if ($isStaff)
{
    my $skeleton = extract_starter($contents);
    unshift(@{$skeleton->{'cells'}}, {
        'cell_type' => 'code',
        'execution_count' => 0,
        'metadata' => {
          'collapsed' => JSON::true,
          'nbgrader' => {
            'grade' => JSON::false,
            'locked' => JSON::true,
            'schema_version' => 1,
            'solution' => JSON::false
          }
        },
        'outputs' => [],
        'source' => [
          "# Do not edit this cell\n",
          "\n",
          "# course: " . $cfg->getProperty('course.number') . "\n",
          "# a: " . $cfg->getProperty('assignment') . "\n",
          "# d: " . $cfg->getProperty('institution')
        ]
    });
    my $outName = "$resultDir/student_notebook.ipynb";
    
    open(SKELETON, ">$outName") ||
        die "Cannot open file for output '$outName': $!";
    print SKELETON to_json($skeleton, {'pretty' => 1});
    close(SKELETON);
}


# Run instructor tests
if ($can_proceed)
{
    my $outfile = $resultDir . "/instr-out.txt";
    my $cmdline = "$Web_CAT::Utilities::SHELL"
        . "$python -m pythy.runner > \"$outfile\"  2>&1";

    print "cmdline = ", $cmdline, "\n" if $debug;

    # Exec program and collect output
    my ($exitcode, $timeout_status) =
        Proc::Background::timeout_system($timeout, $cmdline);

    $exitcode = $exitcode>>8;    # Std UNIX exit code extraction.

    print "timeout status = $timeout_status\n" if $debug;

    if ($timeout_status)
    {
        $timeout_occurred = 1;
        $can_proceed = 0;
        studentLog(
            "<p><b class=\"warn\">Testing your solution exceeded the "
            . "allowable time limit for this assignment.</b></p>"
            . "<p>Most frequently, this is the result of <b>infinite "
            . "recursion</b>--when a recursive method fails to stop "
            . "calling itself--or <b>infinite looping</b>--when a while "
            . "loop or for loop fails to stop repeating.</p><p>As a "
            . "result, no time remained for further analysis of your "
            . "code.</p><p>Score = 0%.</p>\n Please fix the errors and "
            . "submit when correct.\n");
    }
}

if ($can_proceed)
{
    if (! -f '_results.json')
    {
        studentLog("<p><b class=\"warn\">No test results found!</b></p>");
        $can_proceed = 0;
    }
    else
    {
        # stash them for staff to see as well
        copy('_results.json', "$resultDir/results.json");
        my $results = load_notebook('_results.json');
        studentLog("<ul class=\"checklist\">\n");
        for my $test (@{$results->{'tests'}})
        {
            print $test->{'name'}, "\n" if $debug;
            if ($test->{'result'} eq 'success')
            {
                $score += $test->{'points'};
                studentLog("<li class=\"complete\">"
                    . nl_expand(htmlEscape($test->{'description'}))
                    . "</li>");
            }
            else
            {
                studentLog("<li class=\"incomplete\">");
                if ($test->{'points'})
                {
                    studentLog("<span class=\"badge badge-danger\">-"
                        . $test->{'points'} . "</span> ")
                }
                studentLog(nl_expand(htmlEscape($test->{'description'})));
                if ($test->{'reason'})
                {
                    my $reason = $test->{'reason'};
                    if (defined $test->{'exception'} || $reason =~ s/^.+ : //os)
                    {
                        studentLog(
                            "\n<blockquote>"
                            . nl_expand(htmlEscape($reason))
                            . "</blockquote>\n");
                    }
                }
                if ($test->{'traceback'} && $#{$test->{'traceback'}} >= 0)
                {
                    studentLog("\n<pre>\n");
                    for my $line (@{$test->{'traceback'}})
                    {
                        studentLog(htmlEscape($line) . "\n");
                    }
                    studentLog("</pre>\n");
                }
                studentLog("</li>");
            }
        }
        studentLog("</ul>\n");
        print "score = $score\n" if $debug;
    }
}


#=============================================================================
# Pretty-print student Code
my $numCodeMarkups = $cfg->getProperty('numCodeMarkups', 0);
my %codeMarkupIds = ();
my $beautifier = new Web_CAT::Beautifier;

$beautifier->setCountLoc(1);
$beautifier->beautify(
    $student_src,
    $resultDir,
    'html',
    \$numCodeMarkups,
    [],
    $cfg);
$cfg->setProperty( 'numCodeMarkups', $numCodeMarkups );

# Pretty-print student notebook
{
    my $cmdline = "$Web_CAT::Utilities::SHELL"
        . "jupyter nbconvert --to html --template full "
        . "\"$studentNotebook\" --output $resultDir/public/notebook.html";
    print $cmdline, "\n" if $debug;
    system($cmdline . " > $resultDir/nbconvert.log 2>&1");
    if (-f "$resultDir/public/notebook.html")
    {
        my $url = "\${publicResourceURL}/notebook.html";
        studentLog('<p><a href="' . $url
            . '">View full submitted notebook</a></p>');
    }
}


#=============================================================================
# Inline any images from student submission in the feedback
if ($pngCount > 0 && 0)
{
    if ($report_message ne '')
    {
        studentLog('</div></div><div class="module">'
            . '<div dojoType="webcat.TitlePane" '
            . 'title="Student-Generated Images">');
    }
    for (my $i = 1; $i <= $pngCount; $i++)
    {
        my $url = "\${publicResourceURL}/$i.png";
        studentLog('<p><img src="' . $url .  '"/></p>');
    }
}


#=============================================================================
if ($report_message ne '')
{
    open REPORT, ">$resultDir/feedback.html"
        or die "Cannot open '$resultDir/feedback.html' for output: $!";
    print REPORT<<END;
<div class="module">
  <div dojoType="webcat.TitlePane" title="Instructor Test Results">
  $report_message
  </div>
</div>
END
    close REPORT;
    addReportFileWithStyle($cfg, 'feedback.html', 'text/html', 1);
}


#=============================================================================
# Scale to be out of range of $maxCorrectnessScore
$cfg->setProperty("score.correctness", $score);
$cfg->save();

if ($debug && 0)
{
    my $props = $cfg->getProperties();
    while ((my $key, my $value) = each %{$props})
    {
        print $key, " => ", $value, "\n";
    }
}

#-----------------------------------------------------------------------------
exit(0);
