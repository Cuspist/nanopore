#!/bin/bash

#Usage
helpFunction()
{
   echo ""
   echo "Pipeline for analysis of Nanopore runs."
   echo ""
   echo "Usage: $0 -h display help -n run_name -d run_dir -o output_dir -b bed_file"
   echo "Required arguments:"
   echo -e "\t-n Name of Nanopore run"
   echo -e "\t-d Path to directory containing Nanopore run data. Should be the experiment level directory if several runs need to be analysed together."
   echo -e "\t-b BED file for adaptive sampling analysis" 
   echo -e "\t-o Output directory path"
   echo -e "\t-m Path to reference genome mmi index"
   echo -e "\t-r Path to reference genome fa file"
   echo -e "\t-a Adaptive sampling analysis is enabled by default. Set this flag to skip this analysis"
   exit 1 # Exit script after printing help
}

#set defaults
adaptive_sampling=1

#parse arguments
#TODO change this from getopts
while getopts n:d:b:o:m:r:s:l:q:v:ha opt; do
  case "$opt" in
    n) run_name="$OPTARG";;
    d) run_dir="$OPTARG";;
    b) bed_file="$OPTARG";;
    o) output_dir="$OPTARG";;
    m) mmi_index="$OPTARG";;
    r) ref_index="$OPTARG";;
    #options to skip steps - useful for isolating/debugging specific aspects
    s) skip_basecalling="$OPTARG";;
    l) skip_alignment="$OPTARG";;
    q) skip_qc="$OPTARG";;
    v) skip_SV="$OPTARG";;
    #p) skip_adaptive="$OPTARG";;
    h) helpFunction;;
    a) adaptive_sampling=0;;
  esac
done

#Help if mandatory arguments are empty
if [ -z "$run_name" ] || [ -z "$run_dir" ] || [ -z "$output_dir" ] || \
   [ -z "$mmi_index" ] || [ -z "$bed_file" ] || [ -z "$ref_index" ] 
   
then
   echo ""
   echo "ERROR: Missing one or more required arguments. See help message below.";
   helpFunction
fi

#check for running guppyd service before use and exit if running

pid=$( nvidia-smi | grep dorado | awk '{print $5}' )

if [[ "$pid" =~ ^[0-9]+$ ]]; then
  >&2 echo "EXITING: Running Dorado instance detected. Try: 'sudo service doradod stop' then retry."
  exit 1
  #kill -9 $pid
 else
   >&2 echo $(date)
   >&2 echo "INFO: No running Dorado detected, running new analysis..."
fi

#####MAIN PIPELINE######

#create analysis dirs
#dir variables
pipeline_dir=$(pwd)
work_dir="$output_dir"/"$run_name"
echo $(date)
echo "INFO: Output Directory: $work_dir"

mkdir -p "$work_dir"/alignment
#mkdir -p "$work_dir"/fastq/all
mkdir -p "$work_dir"/NanoPlot
mkdir -p "$work_dir"/pycoQC
mkdir -p "$work_dir"/coverage/mosdepth
mkdir -p "$work_dir"/coverage/bedtools

## BASECALLING ##
#TODO add option for modified bases

if [ -z "$skip_basecalling" ]
then
echo $(date)
echo "INFO: Basecalling..."

#TODO handle errors

# dorado basecalling with integrated alignmnet (minimap2)
dorado basecaller --device cuda:0 --recursive --reference "$mmi_index" hac@v4.3.0 "$run_dir" > "$work_dir"/alignment/"$run_name".raw.bam

# generate sequencing summary file
echo $(date)
echo "INFO: Generating sequencing summary file..."
dorado summary -v "$work_dir"/alignment/"$run_name".raw.bam > "$work_dir"/alignment/"$run_name".summary.tsv

# use samtools to sort, index and generate flagstat file.
# -@ specifies number of threads
# TODO delete raw bam file

echo "INFO: Sorting and indexing bam file..."
samtools sort \
-@ 20 -o "$work_dir"/alignment/"$run_name".bam "$work_dir"/alignment/"$run_name".raw.bam

#index sorted bam file
samtools index -@ 20 "$work_dir"/alignment/"$run_name".bam

#save stats
echo "INFO: Generating flagstats..."
samtools flagstat -@ 20"$work_dir"/alignment/"$run_name".bam > "$work_dir"/alignment/"$run_name"_flagstat.txt

else
echo $(date)
echo "INFO: Skipping basecalling"
fi

##QC ##
if [ -z "$skip_qc" ]
then
echo $(date)
echo "INFO: Creating summary plots"


echo "INFO: NanoPlot all reads..."
#plots of run using sequencing summary
# TODO check where sequencing summary from dorado is stored
NanoPlot \
--summary "$work_dir"/alignment/"$run_name".summary.tsv \
--loglength \
--outdir "$work_dir"/NanoPlot/summary \
--prefix "$run_name" \
--threads 20

#plots of alignment using bam file
echo $(date)
echo "INFO NanoPlot on-target reads..."
NanoPlot \
--bam "$work_dir"/alignment/"$run_name".bam \
--outdir "$work_dir"/NanoPlot/bam \
--loglength \
--N50 \
--prefix "$run_name" \
--threads 20 \
--alength # Use aligned read length not sequence read length
fi

##SV CALLING ##
if [ -z $skip_SV ]
then
echo $(date)
echo "INFO: Calling SVs"
#cuteSV
mkdir "$work_dir"/CuteSV

#cuteSV for fusion gene detection
#TODO make path to ref genome a variable

cuteSV "$work_dir"/alignment/"$run_name".bam \
"$ref_index" \
"$work_dir"/CuteSV/"$run_name"_cuteSV.vcf \
./ \
--max_cluster_bias_DEL 100 \
--diff_ratio_merging_DEL 0.3 \
--max_size -1 #no uppper limit on SV size 

#Sniffles
mkdir "$work_dir"/Sniffles
cd "$work_dir"/Sniffles

sniffles --input "$work_dir"/alignment/"$run_name".bam \
--vcf "$work_dir"/Sniffles/"$run_name"_sniffles.vcf \
--non-germline

#cd "$pipeline_dir"
fi

##ADAPTIVE SAMPLING ##
#change to specify if adaptive when running command?
#check adaptive sampling output file exists, and get adaptiive sampling data if so
echo $(date)
if [ "$adaptive_sampling" -eq 1 ]
then
  echo "INFO: Adaptive sampling output detected. Processing adaptive sampling data..."
  echo "INFO: Combining adaptive summary files"
#combine adaptive sampling summary files
#find all adaptive sampling summary files
#TODO check this works with a single file..
adaptive_files=$(find "$run_dir" -name 'adaptive_sampling*')
# concatenate adaptive summary files with a single header
awk 'FNR==1 && NR!=1 { while (/^batch_time/) getline; }
    1 {print}' $adaptive_files > "$work_dir"/"$run_name"_combined_adaptive_sampling_summary.csv

#run adaptive sampling analysis script
# TODO try and speed this step up - subsetting bam files takes forever, another way?
#samtools view -N takes list of read names to subset by.
bash "$pipeline_dir"/SCRIPTS/adaptive.sh -d "$pipeline_dir" \
-n "$run_name" \
-s "$work_dir"/"$run_name"_combined_adaptive_sampling_summary.csv \
-b "$bed_file" \
-w "$work_dir"

# Nanplot on target reads
NanoPlot \
--bam "$work_dir"/alignment/"$run_name"_stop_receiving.sorted.bam \
--outdir "$work_dir"/NanoPlot/on_target \
--loglength \
--N50 \
--prefix "$run_name" \
--threads 20 \
--alength # Use aligned read length not sequence read length

else
  echo "INFO: Skipping adaptive sampling analysis."
fi

## COVERAGE ##
#is this necessary?
echo $(date)
echo "INFO: Calculating coverage"

cd "$work_dir"/coverage/mosdepth 

#use mosdepth to calculate depth
mosdepth --by "$bed_file" "$run_name" "$work_dir"/alignment/"$run_name".bam

cd ../bedtools
#get off target reads
#bedtools to find reads in bam file that do and do not not overlap regions in bam
#on target
bedtools intersect -a "$work_dir"/alignment/"$run_name".bam -b "$bed_file" > "$run_name"_on_target.bam
#off target with -v
#might cut this out - doesn't seem that necessary
bedtools intersect -a "$work_dir"/alignment/"$run_name".bam -b "$bed_file" -v > "$run_name"_off_target.bam

samtools index "$run_name"_off_target.bam
samtools index "$run_name"_on_target.bam

#get distribution of read lengths
samtools stats "$run_name"_off_target.bam | grep ^RL | cut -f 2- > off_target_len.txt
samtools stats "$run_name"_on_target.bam | grep ^RL | cut -f 2- > on_target_len.txt

#depth and coverage calculations on .tsv output from bedtools
#already done in adaptive.sh??
#Rscript $pipeline_dir/SCRIPTS/coverage_adaptive_panel.r *.tsv $run_name
