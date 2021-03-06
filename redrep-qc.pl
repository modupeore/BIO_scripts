#!/usr/bin/perl

# MANUAL FOR redrep-qc.pl

=pod

=head1 NAME

redrep-qc.pl -- Illumina QC, trimming, filtering for Reduced Representation Analysis

=head1 SYNOPSIS

 redrep-qc.pl --in FILENAME [--in2 FILENAME]--out DIRNAME --meta FILENAME [PARAMETERS]
                     [--help] [--manual]
=head1 DESCRIPTION

Performs quality evaluation, trimming, and filtering of Illumina sequenced reduced representation libraries.
 
=head1 OPTIONS

=over 3

=item B<-1, -i, --in, --in1>=FILENAME

Input file (single file or first read) in fastq format. (Required) 

=item B<-2, --in2>=FILENAME

Input file (second read) in fastq format. (Required) 

=item B<-o, --out>=DIRECTORY_NAME

Output directory. (Required) 

=item B<-c, --meta>=FILENAME

Metadata file in tab delimited format.  Must contain header row with at least the following column headings:  unique_id,p1_recog_site,p1_hang_seq,p1_index_seq,p2_recog_site,p2_hang_seq,[p2_index_seq]

=item B<-l, --log>=FILENAME

Log file output path. [ Default output-dir/log.txt ]

=item B<-s, --stats>=FILENAME

Stats file output path. [ Default output-dir/stats.txt ]

=item B<-f, --force>

If output directory exists, force overwrite of previous directory contents.

=item B<-k, --keep_temp>

Retain temporary intermediate files.

=item B<-a, --no_pre_qc>

Skip pre-trimming quality report.

=item B<-z, --no_post_qc>

Skip post-trimming quality report.

=item B<-b, --per_barcode_qc>

Run post-trimming quality reports on each barcode instead of on the full dataset.

=item B<-5, --5p_adapt>

Specify 5' sequencing adapter.  Default 'AATGATACGGCGACCACCGAGATCTACACTCTTTCCCTACACGACGCTCTTCCGATC'.

=item B<-3, --3p_adapt>

Specify 3' sequencing adapter.  Default 'GATCGGAAGAGCACACGTCTGAACTCCAGTCAC'.

=item B<-x, --maxLen>=integer

Maximum sequence length cutoff.  default=9999999

=item B<-m, --minLen>=integer

Minimum sequence length cutoff.  default=35

=item B<-n, --max_N_run>=integer

Maximum number of consecutive N's to allow in middle of trimmed sequence.  default=2

=item B<-p, --part>=integer

Allow barcode to be -p bp shorter than the specified barcode.  -m parameter must be greater than or equal to -p.  default=1

=item B<-e, --mismatch>=integer

Allow barcode to have -m mismatches from the specified barcode.  default=1

=item B<-q, --qual>=integer(0-93)

Quality cut-off for end-trimming.  Performed using the BWA algorithm.  default=30

=item B<-t, --threads, ==ncpu>=integer

Number of cpu's to use for threadable operations.



=item B<-d, --debug>

Produce detailed log.

=item B<-v, --ver, --version>

Displays the current version.

=item B<-h, --help>

Displays the usage message.

=item B<-m, --man, --manual>

Displays full manual.

=back

=head1 VERSION HISTORY

=over 3

=item 1.0 - 10/10/2012: Stable base functionality for single end reads

=item 2.0 - 10/29/2012: Major overhaul adding paired end read handling, improved statistics, file handling, logging

=item 2.1 - 10/31/2012: Added capability for gzipped input files, fixed fastq header bug, added TOTAL row to barcode statistics

=item 2.2 - 10/31/2012: Added basic multi-threading for filtering

=item 2.3 - 11/1/2012: Added sort to stats to compensate for multithreading

=item 2.4 - 11/2/2012: Bugfix, -1 and -2 full file path handled

=item 2.5 - 11/5/2012: Bugfix, reworked wait on children for threads

=back

=head1 DEPENDENCIES

=head2 Requires the following Perl libraries:

=over 3

=item strict

=item Getopt::Long

=item File::Basename

=item Pod::Usage

=item File::Basename

=item POSIX

=item Parallel::ForkManager

=item

=back

=head2 Requires the following external programs be in the system PATH:

=over 3

=item fastqc v0.10.1

=item cutadapt v1.1

=item fastx_barcode_splitter.pl v0.0.13

=back

=head1 AUTHOR

Written by Shawn Polson, University of Delaware

=head1 REPORTING BUGS

Report bugs to polson@udel.edu

=head1 COPYRIGHT

Copyright 2012 Shawn Polson.  
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.  
This is free software: you are free to change and redistribute it.  
There is NO WARRANTY, to the extent permitted by law.  

Please acknowledge author and affiliation in published work arising from this script's 
usage <http://bioinformatics.udel.edu/Core/Acknowledge>.

=cut

my $script=join(' ',@ARGV);

use strict;
use Getopt::Long;
use File::Basename;
use Pod::Usage;
use POSIX;
use Parallel::ForkManager;

sub avgQual;
sub BC_File;
sub BCStats;
sub cmd;
sub concat;
sub countFastq;
sub fastq_pair_repair;
sub filter;
sub logentry;
sub round;


### ARGUMENTS WITH NO DEFAULT
my($inFile,$inFile2,$outDir,$help,$manual,$force,$sepQC,$no_preQC,$no_postQC,$metaFile,$intermed,$debug,$version);


### ARGUMENTS WITH DEFAULT
my $fpAdapt		=	"AATGATACGGCGACCACCGAGATCTACACTCTTTCCCTACACGACGCTCTTCCGATC";
my $tpAdapt		=	"GATCGGAAGAGCACACGTCTGAACTCCAGTCAC";
my $logOut;									# default post-processed
my $statsOut;								# default post-processed
our $maxLen		=	9999999;
our $minLen		=	35;
my $qual		=	30;
our $maxN		=	2;
my $part		=	1;						#  Partial alignment max for BC deconv
my $mismatch	=	1;
my $ncpu		=	1;

GetOptions (	
				"1|i|in|in1=s"				=>	\$inFile,
				"2|in2=s"					=>	\$inFile2,
				"o|out=s"					=>	\$outDir,
				"c|meta=s"					=>	\$metaFile,
				"l|log=s"					=>	\$logOut,
				"s|stats=s"					=>	\$statsOut,

				"f|force"					=>	\$force,
				"d|debug"					=>	\$debug,
				"k|keep_temp"				=>	\$intermed,
				"a|no_pre_qc"				=>	\$no_preQC,
				"z|no_post_qc"				=>	\$no_postQC,
				
				"b|per_barcode_qc"			=>	\$sepQC,
				
				"5|5p_adapt=s"				=>	\$fpAdapt,    	# 5' sequencing adapter
				"3|3p_adapt=s"				=>	\$tpAdapt,		# 3' sequencing adapter

				"x|maxLen=i"				=>	\$maxLen,
				"m|minLen=i"				=>	\$minLen,
				"n|max_N_run=i"				=>	\$maxN,
				"p|part=i"					=>	\$part,
				"e|mismatch=i"				=>	\$mismatch,
				"q|qual=i"					=>	\$qual,
				
				"t|threads|ncpu=i"			=>	\$ncpu,
				
				"v|ver|version"				=>	\$version,
				"h|help"					=>	\$help,
				"m|man|manual"				=>	\$manual);


### VALIDATE ARGS
pod2usage(-verbose => 2)  if ($manual);
pod2usage(-verbose => 1)  if ($help);
die "\nredrep-qc.pl\nCurrent version is 2.5 (11/5/2012 rev).\n\n" if ($version);
pod2usage( -msg  => "ERROR!  Required argument -i (input file 1) not found.\n", -exitval => 2) if (! $inFile);
pod2usage( -msg  => "ERROR!  Required argument -o (output directory) not found.\n", -exitval => 2)  if (! $outDir);
pod2usage( -msg  => "ERROR!  Required argument -m (metadata file) not found.\n", -exitval => 2)  if (! $metaFile);

if($debug)
{	require warnings; import warnings;
	require Data::Dumper; import Data::Dumper;
}

### DECLARE OTHER GLOBALS
my $sys;												# system call variable
#(my $stub) = $inFile=~/^(.+)\.f.+/;					# inFile1 base filename
#(my $stub2) = $inFile2=~/^(.+)\.f.+/ if ($inFile2);	# inFile2 base filename
my $stub=fileparse($inFile, qr/\.[^.]*(\.gz)?$/);
my $stub2=fileparse($inFile2, qr/\.[^.]*(\.gz)?$/) if $inFile2;


our $manager = new Parallel::ForkManager( $ncpu );

### THROW ERROR IF OUTPUT DIRECTORY ALREADY EXISTS (unless $force is set)
if(-d $outDir)
{	if(! $force)
	{	pod2usage( -msg  => "ERROR!  Output directory $outDir already exists.  Use --force flag to overwrite.", -exitval => 2);
	}
	else
	{	$sys=`rm -R $outDir`;
	}
}


### CREATE OUTPUT DIR
mkdir($outDir);


### CREATE STAT & LOG FILES
$logOut="$outDir/log.txt" if (! $logOut);
$statsOut="$outDir/stats.txt" if (! $statsOut);

open(our $LOG, "> $logOut");
open(our $STAT, "> $statsOut");
print $LOG "$0 $script\n";
logentry("SCRIPT STARTED");


### CHECK FOR EXTERNAL DEPENDENCIES
$sys=cmd('which cutadapt',"External dependency 'cutadapt v1.1' (http://code.google.com/p/cutadapt/) not installed in system PATH\n");
$sys=cmd('which fastqc',"External dependency 'fastqc v0.10.1' (http://www.bioinformatics.babraham.ac.uk/projects/fastqc/) not installed in system PATH\n");
$sys=cmd('which fastx_barcode_splitter.pl',"External dependency 'fastx_barcode_splitter.pl v0.0.13' (http://hannonlab.cshl.edu/fastx_toolkit/commandline.html) not installed in system PATH\n");


### FILE LOCATIONS
my $BCFile_p1=$outDir."/barcodes_p1.txt";
my $BCFile_p2=$outDir."/barcodes_p2.txt";
my $file_concat_paired_p1="final.paired_p1.fastq";
my $file_concat_paired_p2="final.paired_p2.fastq";
my $file_concat_single_p1="final.single_p1.fastq";
my $file_concat_single_p2="final.single_p2.fastq";
my $file_concat_single="final.single.fastq";

my $dir_preQC=$outDir."/pre-fastqc";
my $dir_trim1=$outDir."/5-trim";
my $dir_deconv_p1=$outDir."/6-deconv_p1";
my $dir_deconv_p2=$outDir."/6-deconv_p2" if ($inFile2);
my $dir_recomb=$outDir."/7-recomb-mates";
my $dir_filter=$outDir."/8-filter";
my $dir_final_deconv=$outDir."/final-trimmed-deconv";
my $dir_final_concat=$outDir."/final-trimmed-concat";
my $dir_postQC=$outDir."/post-fastqc";


### STEP 1 -- READ METADATA FILE
# Reads in metadata file and parses out informative fields into a hash called %meta

logentry("BEGIN STEP 1: PROCESS METADATA FILE");

my %meta;		# metadata hash of hashes with unique_id as primary key, @ targetfields as secondary keys
my %index;		# hash with p1_index_seq,p2_index_seq as key, unique_id as value
my %p1_p2_ind;	# hash of arrays mapping p1_index_seq (key) to p2_index_seq (value array);

{	
	open(META, $metaFile) or pod2usage( -msg  => "ERROR!  Metadata File $metaFile not found.\n", -exitval => 2);
	my @fieldnames;
	my @targetfields=("unique_id","p1_recog_site","p1_hang_seq","p1_index_seq","p2_recog_site","p2_hang_seq","p2_index_seq");
	my @excludes=("none","None","NONE","NA","na","N/A","n/a");
	while(<META>)
	{	if(@fieldnames)
		{	chomp;
			my @fields=split(/\t/,$_);
			my %temp;
			for(my $i=0; $i<scalar(@fieldnames); $i++)
			{	if(grep(/^$fieldnames[$i]$/,@targetfields) && ! grep(/$fields[$i]/,@excludes))
				{	$temp{$fieldnames[$i]}=$fields[$i];
				}
			}
			
			# Assign %meta
			%{$meta{$temp{'unique_id'}}}=%temp;
			
			# Assign %index and # p1_p2_ind.  Needed for 2 barcode deconvolution.
			my $temp_index;
			if($temp{p2_index_seq})
			{	$temp_index=$temp{p1_index_seq}.",".$temp{p2_index_seq};
				push(@{$p1_p2_ind{$temp{p1_index_seq}}},$temp{p2_index_seq});
			}
			else
			{	$temp_index=$temp{p1_index_seq}.",no_p2_index";
			}
			$index{$temp_index}=$temp{unique_id};
		}
		else
		{	chomp;
			@fieldnames=split(/\t/,$_);
		}
	}
	close(META);
}


### STEP 2 -- MAKE BARCODE FILES
# Uses metadata file to produce barcode file(s) required by fastx_barcode_splitter.pl

logentry("BEGIN STEP 2: CREATE BARCODE FILES");

my $BCLen_p1;
my $BCLen_p2;
my $BC_p1;
my $BC_p2;

($BC_p1,$BCLen_p1)=BC_File($BCFile_p1,"p1",\%meta);
($BC_p2,$BCLen_p2)=BC_File($BCFile_p2,"p2",\%meta);
$sys=cmd("rm $BCFile_p2","Cleanup barcode file") if($BC_p2==0);


### STEP 3 -- INITIAL STATS
logentry("BEGIN STEP 3: PRODUCE INITIAL STATISTICS");
print $STAT "INITIAL STATISTICS\n";
$sys=countFastq("$inFile", "Count input file 1 fastq file");
print $STAT "Sequence count in input file 1: $sys";
if($inFile2)
{	$sys=countFastq("$inFile2", "Count input file 2 fastq file");
	print $STAT "Sequence count in input file 2: $sys";
}
print $STAT "\n";


### STEP 4 -- PRE-FASTQC
unless($no_preQC)
{	logentry("BEGIN STEP 4: PRE-FASTQC");
	mkdir($dir_preQC);
	$sys=cmd("fastqc --outdir $dir_preQC --format fastq --threads $ncpu --extract --quiet $inFile", "Run Pre-fastqc File 1 (P1)");
	$sys=cmd("fastqc --outdir $dir_preQC --format fastq --threads $ncpu --extract --quiet $inFile2", "Run Pre-fastqc File 2 (P2)") if ($inFile2);
}
else
{	logentry("OMITTING STEP 4: PRE-FASTQC");
}


### STEP 5 -- TRIMMING
	logentry("BEGIN STEP 5: TRIMMING");
	mkdir($dir_trim1);
	$sys=cmd("cutadapt --quality-base 33 -q ${qual} -a $tpAdapt -m 1 -o '$dir_trim1/$stub.trim1.fastq' $inFile","Trim1 (qual/3' seq adapter)");
	$sys=countFastq("$dir_trim1/$stub.trim1.fastq", "Trim1 count fastq");
	print $STAT "=================================================\nSTATISTICS AFTER TRIMMING (step 5)\n";
	print $STAT "File1 sequence count after trimming/filter step (quality/3'adapter trim): $sys";
	if($inFile2)
	{	$sys=cmd("cutadapt --quality-base 33 -q ${qual} -a $tpAdapt -m 1 -o '$dir_trim1/$stub2.trim1.fastq' $inFile2","Trim1 (qual/3' seq adapter)");
		$sys=countFastq("$dir_trim1/$stub2.trim1.fastq", "Trim1 count fastq");
		print $STAT "File2 sequence count after trimming/filter step (quality/3'adapter trim): $sys";
	}
	print $STAT "\n";
	
	
### STEP 6 -- BARCODE DECONVOLUTION
	logentry("BEGIN STEP 6: BARCODE DECONVOLUTION");
	mkdir($dir_deconv_p1);
	my $temp="cat $dir_trim1/$stub.trim1.fastq | fastx_barcode_splitter.pl --bol --bcfile $BCFile_p1 --mismatches $mismatch --prefix '$dir_deconv_p1/' ";
	$temp.="--partial $part" if ($part);
	$sys=cmd("$temp","BC deconvolution read1");
	if($inFile2)
	{	mkdir($dir_deconv_p2);
		if($BC_p2)
		{	$temp="cat $dir_trim1/$stub2.trim1.fastq | fastx_barcode_splitter.pl --bol --bcfile $BCFile_p2 --mismatches $mismatch --prefix '$dir_deconv_p2/' ";
			$temp.="--partial $part" if ($part);
			$sys=cmd("$temp","BC deconvolution read2");
		}
		else
		{	$sys=cmd("cp $dir_trim1/$stub2.trim1.fastq $dir_deconv_p2/no_p2_index","Copy p2 file");
		}
	}
	
	print $STAT "=================================================\nSTATISTICS AFTER BARCODE DECONVOLUTION (step 6)\n";
	BCStats($dir_deconv_p1);
	BCStats($dir_deconv_p2) if($inFile2);
	print $STAT "\n";
	
	
### STEP 7 -- MERGE BARCODES
logentry("BEGIN STEP 7: MERGE BARCODES");


{	mkdir($dir_recomb);
	opendir(DIR,"$dir_deconv_p1");
	my @files=grep { (!/^\./) } readdir DIR;
	close(DIR);
	
	foreach my $file_p1 (@files)
	{	unless($file_p1 eq "unmatched")
		{
			if(! $inFile2)  # not paired end
			{	$sys=cmd("cp $dir_deconv_p1/$file_p1 $dir_recomb/".$index{"$file_p1,no_p2_index"}.".singles","Copy file $file_p1 to $dir_recomb/".$index{"$file_p1,no_p2_index"});
			}
			elsif($p1_p2_ind{$file_p1})   # paired end with two sided barcodes
			{	foreach my $file_p2 (@{$p1_p2_ind{$file_p1}})
				{	if(-e "$dir_deconv_p2/$file_p2.single_p2")
					{	fastq_pair_repair("$dir_deconv_p1/$file_p1","$dir_deconv_p2/$file_p2.single_p2",$dir_recomb,$index{"$file_p1,$file_p2"},0);
						$sys=cmd("mv $dir_recomb/$file_p2.single_p2 $dir_deconv_p2/","Move temp singles file $file_p2");
					}
					else
					{	fastq_pair_repair("$dir_deconv_p1/$file_p1","$dir_deconv_p2/$file_p2",$dir_recomb,$index{"$file_p1,$file_p2"},0);
						$sys=cmd("mv $dir_recomb/$file_p2.single_p2 $dir_deconv_p2/","Move temp singles file $file_p2");
					}
				}
			}
			else     #paired end with one sided barcodes
			{	if(-e "$dir_deconv_p2/no_p2_index.single_p2")
				{	fastq_pair_repair("$dir_deconv_p1/$file_p1","$dir_deconv_p2/no_p2_index.single_p2",$dir_recomb,$index{"$file_p1,no_p2_index"},0);
					$sys=cmd("mv $dir_recomb/$file_p1.single_p1 $dir_recomb/$index{$file_p1.',no_p2_index'}.single_p1","Rename p1 singles");
					$sys=cmd("mv $dir_recomb/no_p2_index.single_p2 $dir_deconv_p2/","Move temp singles file");
				}
				else
				{	fastq_pair_repair("$dir_deconv_p1/$file_p1","$dir_deconv_p2/no_p2_index",$dir_recomb,$index{"$file_p1,no_p2_index"},0);
					$sys=cmd("mv $dir_recomb/$file_p1.single_p1 $dir_recomb/$index{$file_p1.',no_p2_index'}.single_p1","Rename p1 singles");
					$sys=cmd("mv $dir_recomb/no_p2_index.single_p2 $dir_deconv_p2/","Move temp p2 singles file");
				}
			}
		}
	}
	mkdir("$dir_recomb/singles");
	$sys=cmd("mv $dir_recomb/*.single* $dir_recomb/singles/","Move broken pairs");
	if($inFile2)
	{	mkdir("$dir_recomb/paired_p1");
		#$sys=cmd("mv $dir_deconv_p2/*.single_p2* $dir_recomb/singles","Move singles files to recomb directory");
		mkdir("$dir_recomb/paired_p2");
		$sys=cmd("mv $dir_recomb/*.paired_p1 $dir_recomb/paired_p1/","Move p1 pairs");
		$sys=cmd("mv $dir_recomb/*.paired_p2 $dir_recomb/paired_p2/","Move p2 pairs");
	}
}


### STEP 8 -- FILTER
# TRIM BARCODE AND FILTER SEQUENCES WITHOUT 5' HANG OR WITH INTERNAL RESTRICTION SITE

logentry("BEGIN STEP 8: FILTER");

print $STAT "=================================================\nSTATISTICS AFTER FILTERS\n";

{	mkdir("$dir_filter");
	
	if(! $inFile2)		# not paired end
	{	mkdir("$dir_filter/singles");
		filter("p1","$dir_recomb/singles","$dir_filter/singles",$BCLen_p1,"single",\%meta);
	}
	elsif($inFile2)		# paired end
	{	mkdir("$dir_filter/paired_p1");
		filter("p1","$dir_recomb/paired_p1","$dir_filter/paired_p1",$BCLen_p1,"paired_p1",\%meta);
		mkdir("$dir_filter/paired_p2");
		filter("p2","$dir_recomb/paired_p2","$dir_filter/paired_p2",$BCLen_p2,"paired_p2",\%meta);
	}
	if($inFile2 && ! $BC_p2)	# collect paired end singles if resolvable (i.e. one barcode system)
	{	mkdir("$dir_filter/singles");
		filter("p1","$dir_recomb/singles","$dir_filter/singles",$BCLen_p1,"single_p1",\%meta);
	}
}
	

### STEP 9 -- FINAL RECONCILE PAIRS

logentry("BEGIN STEP 9: RECONCILE PAIRS");

{	mkdir($dir_final_deconv);
	mkdir($dir_final_concat);
	if($inFile2)
	{	opendir(DIR,"$dir_filter/paired_p1");
		my @files=grep { (!/^\./) } readdir DIR;
		close(DIR);
		foreach my $file_p1 (@files)
		{	#$manager->start and next;
			unless($file_p1 eq "discarded")
			{	if($inFile2)
				{	my $stub=fileparse($file_p1, qr/\.[^.]*(\.gz)?$/);
					fastq_pair_repair("$dir_filter/paired_p1/$file_p1","$dir_filter/paired_p2/$stub.paired_p2",$dir_final_deconv,$stub,0);
					cmd("cat $dir_filter/singles/$stub.single_p1 $dir_final_deconv/$stub.single_p1 > $dir_final_deconv/$stub.single_p1_new","Merge filter/final singles") if(-e "$dir_filter/singles/$stub.single_p1");
					cmd("rm $dir_final_deconv/$stub.single_p1","Delete temporary singles") if(-e "$dir_filter/singles/$stub.single_p1");
					cmd("mv $dir_final_deconv/$stub.single_p1_new $dir_final_deconv/$stub.single_p1","Rename single file $dir_final_deconv/$stub.single_p1_new") if(-e "$dir_filter/singles/$stub.single_p1");
				}
			}
			#$manager->finish;
		}
	}
	else
	{	cmd("cp $dir_filter/singles/*single $dir_final_deconv/","Copy filter/final singles");
	}
	print $STAT "=================================================\nFINAL STATISTICS\n";
	BCStats($dir_final_deconv);
}
{	opendir(DIR,"$dir_final_deconv");
	my @files=grep { (!/^\./) } readdir DIR;
	close(DIR);
	foreach my $file (@files)
	{	$sys=cmd("mv $dir_final_deconv/$file $dir_final_deconv/$file.fastq","Add fastq extensions");
	}
}


### STEP 10 -- FINAL CONCATENATE

logentry("BEGIN STEP 10: PRODUCE CONCATENATED FASTQs");

{	opendir(DIR,"$dir_final_deconv");
	my @files=grep { (!/^\./) } readdir DIR;
	close(DIR);
		
	if($inFile2)
	{	my @files_paired_p1 = grep(/paired_p1/,@files);
		concat("$dir_final_deconv","$dir_final_concat","$file_concat_paired_p1",\@files_paired_p1);
		my @files_paired_p2 = grep(/paired_p2/,@files);
		concat("$dir_final_deconv","$dir_final_concat","$file_concat_paired_p2",\@files_paired_p2);
		my @files_single_p1 = grep(/single_p1/,@files);
		concat("$dir_final_deconv","$dir_final_concat","$file_concat_single_p1",\@files_single_p1);
		my @files_single_p2 = grep(/single_p2/,@files);
		concat("$dir_final_deconv","$dir_final_concat","$file_concat_single_p2",\@files_single_p2);
	}
	if(! $BC_p2 || ! $inFile2)
	{	my @files_single = grep(/single/,@files);
		concat("$dir_final_deconv","$dir_final_concat","$file_concat_single",\@files_single);
	}
}

	
### STEP 11 -- POST-fastqc

unless($no_postQC)
{	logentry("BEGIN STEP 11: POST-FASTQC");
	
	my @files;	
	
	mkdir($dir_postQC);
	if($sepQC)
	{	opendir(DIR,"$dir_final_deconv");
		@files=grep { (!/^\./) } readdir DIR;
		close(DIR);
		foreach my $file (@files)
		{	$sys=cmd("fastqc --outdir $dir_postQC --format fastq --threads $ncpu --noextract --quiet $dir_final_deconv/$file", "Run Post-fastqc $dir_final_deconv/$file");
		}
	}
	else
	{	opendir(DIR,"$dir_final_concat");
		@files=grep { (!/^\./) } readdir DIR;
		close(DIR);
		foreach my $file (@files)
		{	$sys=cmd("fastqc --outdir $dir_postQC --format fastq --threads $ncpu --noextract --quiet $dir_final_concat/$file", "Run Post-fastqc $dir_final_concat/$file");
		}
		
	}	
}
else
{	logentry("OMITTING STEP 11: POST-FASTQC");
}


### STEP 12 -- CLEAN UP

logentry("BEGIN STEP 12: CLEAN UP");

if(! $intermed)
{	$sys=cmd("rm $BCFile_p1","Remove Fastx Barcode File 1 directory");
	$sys=cmd("rm -R $dir_trim1","Remove trim1 directory");
	$sys=cmd("rm -R $dir_deconv_p1","Remove deconv_p1 directory");
	$sys=cmd("rm -R $dir_recomb","Remove recomb directory");
	$sys=cmd("rm -R $dir_filter","Remove fitler directory");
	if ($inFile2)
	{	$sys=cmd("rm -R $dir_deconv_p2","Remove deconv_p2 directory");
		$sys=cmd("rm $BCFile_p2","Remove Fastx Barcode File 2") if(-e $BCFile_p2);
	}	
}

logentry("SCRIPT COMPLETE");
close($LOG);
close($STAT);

exit 0;


#######################################
############### SUBS ##################


#######################################
### avgQual
# determine mean quality score for a fastq quality string
sub avgQual
{	my $qstr=shift;
	chomp($qstr);
	my $qstr_sum;
	$qstr_sum += (ord $_)-33 foreach split //, $qstr;
	my $len=length($qstr);
	my $qavg=round($qstr_sum/$len,1);
	return ($qavg,$len);
}


#######################################
### BC_File
# make fastx_barcode_splitter.pl compatible barcode file
sub BC_File	
{	my $file=shift;
	my $direction=shift;
	my %meta=%{(shift)};
	my $BC=0;
	my $BCLen;
	my %seen;
	my @uniq_bc;
	logentry("Processing $direction barcode file") if($debug);
	open(BC,"> $file");
	foreach my $sample (sort {$a <=> $b} keys %meta)
	{	if ($meta{$sample}{$direction."_index_seq"})
		{	$BC=1;
			push(@uniq_bc, $meta{$sample}{$direction."_index_seq"}) unless $seen{$meta{$sample}{$direction."_index_seq"}}++;
			if($BCLen && $BCLen != length($meta{$sample}{$direction."_index_seq"}))
			{	pod2usage( -msg  => "ERROR!  All index sequences must be the same length (at $direction sample $sample)\n", -exitval => 2);
			}
			else
			{	$BCLen=length($meta{$sample}{$direction."_index_seq"});
			}
		}
		elsif($BC==1)
		{	pod2usage( -msg  => "ERROR!  If ".$direction."_index_seq is set for one sample, it must be set for all samples.  No ".$direction."_index_seq for sample $sample.\n", -exitval => 2);
		}
	}
	foreach my $bc (@uniq_bc)
	{	print BC $bc."\t".$bc."\n";
	}
	close(BC);
	return ($BC,$BCLen);
}


#######################################
### BCStats
# Count and record per barcode sequence counts from a directory of deconvoluted fastq files
sub BCStats
{	my $inDir=shift;
	my $sys;
	my $total;
	logentry("Processing Sequence Count Stats for $inDir") if($debug);
	
	opendir(DIR,"$inDir");
	my @files=grep { (!/^\./) } readdir DIR;
	close(DIR);
	
	print $STAT "Sequence count ($inDir):\n";
	foreach my $file (sort @files)
	{	if(-s $inDir."/".$file)
		{	$sys=countFastq("$inDir/$file","File count $inDir/$file");
		}
		else
		{	$sys="0\n";
		}
		print $STAT "$file\t$sys";
		$total+=$sys;
	}
	print $STAT "TOTAL\t$total\n";
	print $STAT "\n";
}


#######################################
### cmd
# run system command and collect output and error states
sub cmd
{	my $cmd=shift;
	my $message=shift;
	
	logentry("System call: $cmd") if($debug);
	
	my $sys=`$cmd 2>&1`;
	my $err=$?;
	if ($err)
	{	print $LOG "$message\n$cmd\nERROR $err\n$sys\n" if($LOG);
		pod2usage( -msg  => "ERROR $err!  $message\n", -exitval => 2);
		return 1;
	}
	else
	{	return $sys;
	}
}


#######################################
### concat
# concatenate multiple files splified in array
sub concat
{	my $inDir=shift;		# input directory
	my $outDir=shift;		# output directory
	my $outFile=shift;		# output filename
	my @files=@{(shift)};	# array of filenames
	
	my $file_str=join(' ',map { "$inDir/$_" } @files);
	my $sys=cmd("cat $file_str > $outDir/$outFile","Make concatenated fastq file $outFile");
}


#######################################
### countFastq
# count sequences in fastq file
sub countFastq
{	my $path=shift;
	my $message=shift;
	my $sys;
	if($path =~ /gz$/)
	{	$sys=cmd('expr $(zcat '.$path.'| wc -l) / 4',$message);
	}
	else
	{	$sys=cmd('expr $(cat '.$path.'| wc -l) / 4',$message);
	}
	return $sys;
}


#######################################
### fastq_pair_repair
# matches pairs and segregated broken pair sequences from a pair of input fastq files
sub fastq_pair_repair
{	my $PE1=shift;
	my $PE2=shift;
	my $outDir=shift;
	my $outName=shift;
	my $no_singles=shift;
	
	logentry("Merging paired end mates: $PE1 $PE2") if($debug);
	
	# PARSE OUTPUT FILEBASE
	my $out1=fileparse($PE1, qr/\.[^.]*(\.gz)?$/);
	my $out2=fileparse($PE2, qr/\.[^.]*(\.gz)?$/);
	
	# FILE HANDLES
	my($DATA,$PAIR1,$PAIR2,$SNGL1,$SNGL2);
	
	# OPEN PE1
	open ($DATA,$PE1) || die $!;
	
	my %seqs;
	
	# REG EXP FOR FASTQ HEADERS
	my $hdr_ptrn;
	# Illumina 1-1.7:	@HWUSI-EAS100R:6:73:941:1973#0/1
	# Illumina 1.8+:	@EAS139:136:FC706VJ:2:2104:15343:197393 1:Y:18:ATCACG
	$hdr_ptrn='^\@(\S+)[\/ ][12]';
	
	# PROCESS PE1
	while(<$DATA>)
	{
		if (/$hdr_ptrn/)
		{	$seqs{$1}=$_;
			$seqs{$1}.=<$DATA>.<$DATA>.<$DATA>;
		}
		else
		{	die "ERROR! File format error in $PE1 near line ".$..".\n$_\n";
		}
	}
	close $DATA;
	
	open ($DATA,$PE2) or die $PE2.$!;
	open ($PAIR1,"> $outDir/$outName.paired_p1") or die $!;
	open ($PAIR2,"> $outDir/$outName.paired_p2") or die $!;
	if (! $no_singles)
	{	open ($SNGL1,"> $outDir/$out1.single_p1") or die $!;
		open ($SNGL2,"> $outDir/$out2.single_p2") or die $!;
	}
	
	
	# PROCESS PE2 AND OUTPUT PAIRS/SINGLES FROM PE2
	while(<$DATA>)
	{	if (/$hdr_ptrn/)
		{
			if ($seqs{$1})
			{	print $PAIR1 $seqs{$1};
				undef $seqs{$1};
				$_.=<$DATA>.<$DATA>.<$DATA>;
				print $PAIR2 $_;
			}
			else
			{	$_.=<$DATA>.<$DATA>.<$DATA>;
				print $SNGL2 $_ if (! $no_singles);
			}
		}
		else
		{	die "ERROR! File format error in $PE2 near line ".$..".\n$_\n";
		}
	}
	
	# PRINT SINGLES FROM PE1
	if(! $no_singles)
	{	foreach my $key(keys %seqs)
		{
			if (($seqs{$key})&&($seqs{$key} ne ""))
			{
				print $SNGL1 $seqs{$key};
			}
		}
		close $SNGL1;
		close $SNGL2;
		my $sys
	}
		
	close $DATA;
	close $PAIR1;
	close $PAIR2;
}


#######################################
### filter
# perform step 4 filtering on sequences
sub filter
{	my $direction=shift;  #p1 or p2
	my $in_dir=shift;
	my $out_dir=shift;
	my $BCLen=shift;
	my $suffix=shift;
	my %meta=%{(shift)};

	logentry("Filtering $suffix") if($debug);
	
	opendir(DIR,"$in_dir");
	my @files=grep { (!/^\./) } readdir DIR;
	close(DIR);
	mkdir("$out_dir/discarded");
	mkdir("$out_dir/tmp");
	
	
	print $STAT "Per sample sequence counts ($suffix):\n";
	print $STAT "sample\tafter_deconv\tinternal_RS\tmissing_hang_seq\tN_run\tmax_length\tmin_length\ttotal_removed\tfinal_total\n";
	
#	my $stat_all_cnt=0;
#	my $stat_all_intRS=0;
#	my $stat_all_fphang_miss=0;
#	my $stat_all_Nrun=0;
#	my $stat_all_maxLen=0;
#	my $stat_all_minLen=0;
#	my $stat_all_tot=0;
#	my $stat_all_disc=0;	

	
	
	foreach my $file (sort @files)
	{	$manager->start and next;	
		open(TMP,"> $out_dir/tmp/$file.stats.tmp");
		unless($file eq "unmatched" || $file eq "discarded")
		{	
			my $stub=fileparse($file, qr/\.[^.]*(\.gz)?$/);
			
			open(DAT, "$in_dir/$file");
			open(OUT, ">$out_dir/$stub.$suffix");
			open(DISC, ">$out_dir/discarded/$stub.discard_$suffix");
			
			my $count=0;
			my $keep=0;
			my $trimLen=0;
			my $seq="";
			my $hang=$meta{$stub}{$direction.'_hang_seq'};
			my $hang2=$hang;
			$hang2=~s/^./N/;
			my $stat_cnt=0;
			my $stat_intRS=0;
			my $stat_fphang_miss=0;
			my $stat_Nrun=0;
			my $stat_maxLen=0;
			my $stat_minLen=0;
			my $stat_tot=0;
			my $stat_disc=0;
			my $max_N_run=$maxN+1;
			
			
			while(<DAT>)
			{	$count++;
				my $BCLen_2=$BCLen-1 if($BCLen);
				if($count==2)
				{						
					# missing hang seq
					if($BCLen && $_=~ /^.{$BCLen_2,$BCLen}$hang/)
					{	$_=~ s/^(.{$BCLen_2,$BCLen})$hang/$hang/;
						chomp($seq);
						$trimLen=length($1);
						$seq .= " EXPECT_BC=".$meta{$stub}{$direction."_index_seq"}." FOUND_BC=$1  SAMPLE=$stub\n";
						$keep=1;
					}
					elsif(! $BCLen && ($_=~/^$hang/ || $_=~/^$hang2/))
					{	#if($_=~ s/^N//)
						#{	$trimLen=1;
						#}
						chomp($seq);
						$seq .= " EXPECT_BC=NONE FOUND_BC=NONE SAMPLE=$stub\n";
						$keep=1;
					}
					else
					{	$stat_fphang_miss++;
					}
					
					my $tmp=$_;
					
					# internal restriction site
					my @RS = ($meta{$stub}{p1_recog_site},$meta{$stub}{p2_recog_site});
					foreach my $r (@RS)
					{	if($tmp =~ /$r/)
						{	$stat_intRS++ if($keep==1);
							$keep=0;
						}
					}

					# internal runs of N's
					if($tmp =~ /N{$max_N_run}/)
					{	$stat_Nrun++;
						$keep=0;
					}
					
					# too long
					if(length($tmp)>$maxLen)
					{	$stat_maxLen++;
						$keep=0;
					}
					
					# too short
					if(length($tmp)<$minLen)
					{	$stat_minLen++;
						$keep=0;
					}
					
				}
				if($count==4 && $trimLen)
				{	$_ =~ s/^.{$trimLen}//;
				}
				$seq.=$_;
				if($count==4)
				{	$stat_cnt++;
					my ($qavg,$len)=avgQual($_);
					$seq =~ s/(SAMPLE=\S+)/$1 LENGTH=$len MEAN_QUAL=$qavg/;
					
					if($keep==1)
					{	print OUT $seq;
						$stat_tot++;
					}
					else
					{	print DISC $seq;
						$stat_disc++;
					}
					$keep=0;
					$count=0;
					$trimLen=0;
					$seq="";
				}
			}
			print TMP "$stub\t$stat_cnt\t$stat_intRS\t$stat_fphang_miss\t$stat_Nrun\t$stat_maxLen\t$stat_minLen\t$stat_disc\t$stat_tot\n";
#			$stat_all_cnt+=$stat_cnt;
#			$stat_all_intRS+=$stat_intRS;
#			$stat_all_fphang_miss+=$stat_fphang_miss;
#			$stat_all_Nrun+=$stat_Nrun;
#			$stat_all_maxLen+=$stat_maxLen;
#			$stat_all_minLen+=$stat_minLen;
#			$stat_all_tot+=$stat_tot;
#			$stat_all_disc+=$stat_disc;	
			close(OUT);
			close(DAT);
			close(DISC);
		}
		close(TMP);
		$manager->finish;
	}
	$manager->wait_all_children;
	sleep 1;
	$sys=cmd("cat $out_dir/tmp/*.stats.tmp > $out_dir/tmp/all.stats.tmp");
	my $counts=cmd("awk 'BEGIN {FS=OFS=".'"\t"'."} NR == 1 { n2 =\$2; n3 = \$3; n4 = \$4; n5 = \$5; n6 = \$6; n7 = \$7; n8 = \$8; n9 = \$9; next } { n2 += \$2; n3 += \$3; n4 += \$4; n5 += \$5; n6 +=\$6; n7 += \$7; n8 += \$8; n9 += \$9 } END { print n2, n3, n4, n5, n6, n7, n8, n9 }' $out_dir/tmp/all.stats.tmp");
	$sys=cmd("sort -k1,1 $out_dir/tmp/all.stats.tmp","Sort temp stats file");
	print $STAT $sys;
#	print $STAT "TOTAL\t$stat_all_cnt\t$stat_all_intRS\t$stat_all_fphang_miss\t$stat_all_Nrun\t$stat_all_maxLen\t$stat_all_minLen\t$stat_all_disc\t$stat_all_tot\n";
	print $STAT "TOTAL\t$counts\n";
	print $STAT "\n";
	cmd("rm -R $out_dir/tmp");
	
}


#######################################
### logentry
# Enter time stamped log entry
sub logentry
{	my $message=shift;
	print $LOG POSIX::strftime("%m/%d/%Y %H:%M:%S > $message\n", localtime);
}


#######################################
### round
# Round float ($number) to $dec digits
sub round 
{	my $number = shift || 0;
	my $dec = 10 ** (shift || 0);
	return int( $dec * $number + .5 * ($number <=> 0)) / $dec;
}

__END__
