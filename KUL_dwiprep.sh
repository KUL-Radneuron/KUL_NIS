#!/bin/bash -e
# Bash shell script to process diffusion & structural 3D-T1w MRI data
#
# Requires Mrtrix3, FSL, ants
#
# @ Stefan Sunaert - UZ/KUL - stefan.sunaert@uzleuven.be
#
# v0.1 - dd 09/11/2018 - alpha version
v="v0.1 - dd 09/11/2018"

# To Do
#  - register dwi to T1 with ants-syn
#  - fod calc msmt-5tt in stead of dhollander


# -----------------------------------  MAIN  ---------------------------------------------
# this script defines a few functions:
#  - Usage (for information to the novice user)
#  - kul_e2cl (for logging)
#
# this script uses "preprocessing control", i.e. if some steps are already processed it will skip these

kul_main_dir=`dirname "$0"`
source $kul_main_dir/KUL_main_functions.sh
cwd=$(pwd)

# FUNCTIONS --------------

# function Usage
function Usage {

cat <<USAGE

`basename $0` performs dMRI preprocessing.

Usage:

  `basename $0` -s subject <OPT_ARGS>

Example:

  `basename $0` -s pat001 -p 6 

Required arguments:

     -s:  subject (anonymised name of the subject)

Optional arguments:

     -p:  number of cpu for parallelisation
     -t:  options to pass to topup
     -e:  options to pass to eddy
     -d:  options to pass to dwipreproc (can be -rpe_header, -rpe_none, -rpe_all)
     -v:  show output from mrtrix commands


USAGE

    exit 1
}


# CHECK COMMAND LINE OPTIONS -------------
# 
# Set defaults
ncpu=6 # default if option -p is not given
silent=1 # default if option -v is not given
# Specify additional options for FSL eddy
eddy_options="--slm=linear --repol"
topup_options=""
dwipreproc_options="-rpe_header"

# Set required options
s_flag=0

if [ "$#" -lt 1 ]; then
    Usage >&2
    exit 1

else

    while getopts "s:p:t:e:d:v" OPT; do

        case $OPT in
        s) #subject
            s_flag=1
            subj=$OPTARG
        ;;
        p) #parallel
            ncpu=$OPTARG
        ;;
        d) #dwipreproc_options
            dwipreproc_options=$OPTARG
        ;;
        t) #topup_options
            topup_options=$OPTARG
        ;;
        e) #eddy_options
            eddy_options=$OPTARG
        ;;
        v) #verbose
            silent=0
        ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            echo
            Usage >&2
            exit 1
        ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            echo
            Usage >&2
            exit 1
        ;;
        esac

    done

fi

# check for required options
if [ $s_flag -eq 0 ] ; then 
    echo 
    echo "Option -s is required: give the anonymised name of a subject (this will create a directory subject_preproc with results)." >&2
    echo
    exit 2 
fi 

# MRTRIX verbose or not?
if [ $silent -eq 1 ] ; then 

    export MRTRIX_QUIET=1

fi

# REST OF SETTINGS ---

# timestamp
start=$(date +%s)

# Some parallelisation
FSLPARALLEL=$ncpu; export FSLPARALLEL
OMP_NUM_THREADS=$ncpu; export OMP_NUM_THREADS

# Directory to write preprocessed data in
preproc=dwiprep/sub-${subj}

# Directory to put raw mif data in
raw=${preproc}/raw

# set up preprocessing & logdirectory
mkdir -p ${preproc}/raw
mkdir -p ${preproc}/log

d=$(date "+%Y-%m-%d_%H-%M-%S")
log=log/log_${d}.txt



# SAY HELLO ---

#kul_e2cl "Welcome to KUL_dwiprep $v - $d" ${preproc}/${log}

bids_subj=BIDS/"sub-$subj"/ses-tp1   #FLAG, bad hard coded session!

# STEP 1 - CONVERSION of BIDS to MIF ---------------------------------------------

# test if conversion has been done
if [ ! -f ${preproc}/dwi_orig.mif ]; then

    kul_e2cl " Preparing datasets from BIDS directory..." ${preproc}/${log}

    # convert dwi
    bids_dwi_search="$bids_subj/dwi/sub-*_dwi.nii.gz"
    bids_dwi_found=$(ls $bids_dwi_search)
    
    number_of_bids_dwi_found=$(echo $bids_dwi_found | wc -w)

    if [ $number_of_bids_dwi_found -eq 1 ]; then #FLAG, if comparing dMRI sequences, they should not be catted

        kul_e2cl "   only 1 dwi dataset, scaling not necessary" ${preproc}/${log}
        dwi_base=${bids_dwi_found%%.*}
        mrconvert ${dwi_base}.nii.gz -fslgrad ${dwi_base}.bvec ${dwi_base}.bval \
        -json_import ${dwi_base}.json ${preproc}/dwi_orig.mif -strides 1:3 -force -clear_property comments -nthreads $ncpu 

    else 
        
        kul_e2cl "   found $number_of_bids_dwi_found dwi datasets, scaling & catting" ${preproc}/${log}
        
        dwi_i=1
        for dwi_file in $bids_dwi_found; do
            dwi_base=${dwi_file%%.*}
        
            mrconvert ${dwi_base}.nii.gz -fslgrad ${dwi_base}.bvec ${dwi_base}.bval \
            -json_import ${dwi_base}.json ${raw}/dwi_p${dwi_i}.mif -strides 1:3 -force -clear_property comments -nthreads $ncpu

            dwiextract -quiet -bzero ${raw}/dwi_p${dwi_i}.mif - | mrmath -axis 3 - mean ${raw}/b0s_p${dwi_i}.mif -force
        
            # read the median b0 values
            scale[dwi_i]=$(mrstats ${raw}/b0s_p1.mif -mask `dwi2mask ${raw}/dwi_p${dwi_i}.mif - -quiet` -output median)
            kul_e2cl "   dataset p${dwi_i} has ${scale[dwi_i]} as mean b0 intensity" ${preproc}/${log}

            #echo "scaling ${raw}/dwi_p${dwi_i}_scaled.mif"
            mrcalc -quiet ${scale[1]} ${scale[dwi_i]} -divide ${raw}/dwi_p${dwi_i}.mif -mult ${raw}/dwi_p${dwi_i}_scaled.mif -force

            ((dwi_i++))

        done 

        #echo "catting dwi_orig"
        mrcat ${raw}/dwi_p*_scaled.mif ${preproc}/dwi_orig.mif

    fi


else

    echo " Conversion has been done already... skipping to next step"

fi


# STEP 2 - DWI Preprocessing ---------------------------------------------

cd ${preproc}
mkdir -p dwi

# check if first 2 steps of dwi preprocessing are done 
if [ ! -f dwi/degibbs.mif ]; then

    kul_e2cl " Start part 1 of preprocessing: dwidenoise & mrdegibbs" ${log}

    # dwidenoise
    kul_e2cl "   dwidenoise..." ${log}
    dwidenoise dwi_orig.mif dwi/denoise.mif -noise dwi/noiselevel.mif -nthreads $ncpu -force

    # mrdegibbs
    kul_e2cl "   mrdegibbs..." ${log}
    mrdegibbs dwi/denoise.mif dwi/degibbs.mif -nthreads $ncpu -force
    rm dwi/denoise.mif

else

    echo "   part 1 of preprocessing has been done already... skipping to next step"

fi


# check if step 3 of dwi preprocessing is done (dwipreproc, i.e. motion and distortion correction takes very long)
if [ ! -f dwi/geomcorr.mif ]; then

    # motion and distortion correction using rpe_header
    kul_e2cl "   Start part 2 of preprocessing: dwipreproc using rpe_header (this takes time!)..." ${log}

    # Make the directory for the output of eddy_qc
    mkdir -p eddy_qc/raw

    # prepare eddy_options
    # 
    echo "eddy_options: $eddy_options"
    full_eddy_options="--cnr_maps --residuals "${eddy_options}
    echo "full_eddy_options: $full_eddy_options"

    # NOT RELEVANT YET (not yet implemented)
    #if [ -z "$topup_options" ]; then
    #    dwipreproc_topup_options=""
    #else
    #    dwipreproc_topup_options="-topup_options $topup_options "
    #fi

    # PREPARE FOR TOPUP and EDDY, but allways use rpe_header, since we start from BIDS format
    # 
    # Check whether:
    #  - is there only 1 b0?
    #      -> do regular mrtrix-dwiprep (topup will not be called)
    #  - are there less than 5 b0s?
    #      -> do regular mrtrix-dwiprep (topup will be called if necessary)
    #  - when equal to or more than 5 b0s, are there different pe_schemes (i.e. reversed phase)?
    #    - if not: continue with regular mrtrix-dwipreproc (topup will not be called)
    #    - if so, only keep one of each pe_scheme and call mrtrix-dwipreproc with -se_epi option

    regular_dwipreproc=1
    
    # read the pe table of the b0s of dwi_orig.mif
    IFS=$'\n' 
    pe=($(dwiextract dwi_orig.mif -bzero - | mrinfo -petable -))
    #echo $pe
    # count how many b0s there are
    n_pe=$(echo ${#pe[@]})
    #echo $n_pe
    
    
    # in case there is only 1 b0
    if [ $n_pe -eq 1 ]; then 
        
        info_dwipreproc="only 1 b0"
    
    elif [ $n_pe -lt 5 ]; then

        info_dwipreproc="less than 5 b0s"

    else

        info_dwipreproc="more than or equal to 5 b0s, but all same pe_scheme"

        # extract first b0
        dwiextract dwi_orig.mif -bzero - | mrconvert - -coord 3 0 raw/b0s_pe0.mif -force
        # get the pe_scheme of the first b0
        previous_pe=$(echo ${pe[0]})

        # read over the following b0s, and only keep 1 with a new b0 scheme

        for i in `seq 1 $(($n_pe-1))`; do
        
            current_pe=$(echo ${pe[$i]})
        
            if [ $previous_pe = $current_pe ]; then
                echo previous_pe=$previous_pe, current_pe=$current_pe
                echo "same pe scheme, skip"

            else
            
                info_dwipreproc="more than or equal to 5 b0s, but some have different pe_scheme"
                regular_dwipreproc=0
                
                echo previous_pe=$previous_pe, current_pe=$current_pe
                echo "new pe_scheme, convert"
                dwiextract dwi_orig.mif -bzero - | mrconvert - -coord 3 $i raw/b0s_pe${i}.mif -force

            fi

            previous_pe=$current_pe

        done    

    fi

    

    if [ $regular_dwipreproc -eq 1 ]; then

        dwipreproc dwi/degibbs.mif dwi/geomcorr.mif -rpe_header -eddyqc_all eddy_qc/raw -eddy_options "${full_eddy_options} " -force -nthreads $ncpu -nocleanup
	
    else

        # concat all b0 with different pe_schemes
        mrcat raw/b0s_pe*.mif raw/se_epi_for_topup.mif -force    
        
        dwipreproc -se_epi raw/se_epi_for_topup.mif dwi/degibbs.mif dwi/geomcorr.mif -rpe_header -eddyqc_all eddy_qc/raw -eddy_options "${full_eddy_options} " -force -nthreads $ncpu -nocleanup
    
    fi

    # Let's run eddy_quad
    temp_dir=$(ls -d dwipreproc*)
    rm -rf eddy_qc/quad
	kul_e2cl "   running eddy_quad..." ${log}
	eddy_quad $temp_dir/dwi_post_eddy --eddyIdx $temp_dir/eddy_indices.txt \
        --eddyParams $temp_dir/dwi_post_eddy.eddy_parameters --mask $temp_dir/eddy_mask.nii \
        --bvals $temp_dir/bvals --bvecs $temp_dir/bvecs --output-dir eddy_qc/quad --verbose 
    # make an mriqc/fmriprep style report (i.e. just link qc.pdf into main dwiprep directory)
    ln -s eddy_qc/quad/qc.pdf $cwd/${preproc}.pdf &

else

    echo "   part 2 of preprocessing has been done already... skipping to next step"

fi        



# check if next 4 steps of dwi preprocessing are done
if [ ! -f dwi_preproced.mif ]; then

    kul_e2cl " Start part 3 of preprocessing: dwibiascorrect, upsampling & creation of dwi_mask" ${log}

    # bias field correction
    kul_e2cl "    dwibiascorrect" ${log}
    dwibiascorrect -ants dwi/geomcorr.mif dwi/biascorr.mif -bias dwi/biasfield.mif -nthreads $ncpu -force 

    # upsample the images
    kul_e2cl "    upsampling resolution..." ${log}
    mrresize dwi/biascorr.mif -vox 1.3 dwi/upsampled.mif -nthreads $ncpu -force 
    rm dwi/biascorr.mif

    # copy to main directory for subsequent processing
    kul_e2cl "    saving..." ${log}
    mrconvert dwi/upsampled.mif dwi_preproced.mif -set_property comments "Preprocessed dMRI data." -nthreads $ncpu -force 
    rm dwi/upsampled.mif

    # create mask of the dwi data 
    kul_e2cl "    creating mask of the dwi data..." ${log}
    dwi2mask dwi_preproced.mif dwi_mask.nii.gz -nthreads $ncpu -force

    # create mean b0 of the dwi data
    kul_e2cl "    creating mean b0 of the dwi data ..." ${log}
    dwiextract -quiet dwi_preproced.mif -bzero - | mrmath -axis 3 - mean dwi_b0.nii.gz -force 

else

    echo "   part 3 of preprocessing has been done already... skipping to next step"

fi



# STEP 3 - RESPONSE ---------------------------------------------
mkdir -p response
# response function estimation
if [ ! -f response/wm_response.txt ]; then
    kul_e2cl "   Calculating dwi2response..." ${log}
    dwi2response dhollander dwi_preproced.mif response/wm_response.txt response/gm_response.txt response/csf_response.txt -nthreads $ncpu -force 

else

    echo " dwi2response already done, skipping..."

fi

if [ ! -f response/wmfod.mif ]; then
    kul_e2cl "   Calculating dwi2fod..." ${log}
    dwi2fod msmt_csd dwi_preproced.mif response/wm_response.txt response/wmfod.mif response/gm_response.txt response/gm.mif \
        response/csf_response.txt response/csf.mif -mask dwi_mask.nii.gz -force -nthreads $ncpu 

else

    echo " dwi2fod already done, skipping..."

fi


# STEP 4 - DO QA ---------------------------------------------
# Make an FA/dec image

mkdir -p qa

if [ ! -f qa/dec.mif ]; then
    kul_e2cl "   Calculating FA/dec..." ${log}
    dwi2tensor dwi_preproced.mif dwi_dt.mif -force
    tensor2metric dwi_dt.mif -fa qa/fa.nii.gz -mask dwi_mask.nii.gz -force
    fod2dec response/wmfod.mif qa/dec.mif -force

    #mrconvert dwi/noiselevel.mif qa/noiselevel.nii.gz

fi

kul_e2cl "Finished " ${log}