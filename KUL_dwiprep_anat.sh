#!/bin/bash
# Bash shell script to process diffusion & structural 3D-T1w MRI data
#
# Requires Mrtrix3, FSL, ants
#
# @ Stefan Sunaert - UZ/KUL - stefan.sunaert@uzleuven.be
#
# v0.1 - dd 09/11/2018 - alpha version
v="v0.2 - dd 19/12/2018"

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

`basename $0` performs dMRI anatomical preprocessing.

Usage:

  `basename $0` -p subject <OPT_ARGS>

Example:

  `basename $0` -p pat001 -n 6 

Required arguments:

     -p:  participant (anonymised name of the subject)

Optional arguments:

     -s:  session (of the participant)
     -n:  number of cpu for parallelisation
     -v:  show output from mrtrix commands


USAGE

    exit 1
}


# CHECK COMMAND LINE OPTIONS -------------
# 
# Set defaults
ncpu=6
silent=1

# Set required options
p_flag=0
s_flag=0

if [ "$#" -lt 1 ]; then
    Usage >&2
    exit 1

else

    while getopts "p:n:s:vh" OPT; do

        case $OPT in
        p) #participant
            p_flag=1
            subj=$OPTARG
        ;;
        s) #session
            s_flag=1
            ses=$OPTARG
        ;;
        n) #parallel
            ncpu=$OPTARG
        ;;
        v) #verbose
            silent=0
        ;;
        h) #help
            Usage >&2
            exit 0
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
if [ $p_flag -eq 0 ] ; then 
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

d=$(date "+%Y-%m-%d_%H-%M-%S")
log=log/log_${d}.txt

# --- MAIN ----------------

bids_subj=BIDS/sub-${subj}

# Either a session is given on the command line
# If not the session(s) need to be determined.
if [ $s_flag -eq 1 ]; then

    # session is given on the command line
    search_sessions=BIDS/sub-${subj}/ses-${ses}

else

    # search if any sessions exist
    search_sessions=($(find BIDS/sub-${subj} -type d | grep dwi))

fi    
 
num_sessions=${#search_sessions[@]}
    
echo "  Number of BIDS sessions: $num_sessions"
echo "    notably: ${search_sessions[@]}"


# ---- BIG LOOP for processing each session
for i in `seq 0 $(($num_sessions-1))`; do

# set up directories 
cd $cwd
long_bids_subj=${search_sessions[$i]}
#echo $long_bids_subj
bids_subj=${long_bids_subj%dwi}

# Create the Directory to write preprocessed data in
preproc=dwiprep/sub-${subj}/$(basename $bids_subj) 
#echo $preproc

# Directory to put raw mif data in
raw=${preproc}/raw

# set up preprocessing & logdirectory
#mkdir -p ${preproc}/raw
#mkdir -p ${preproc}/log

kul_e2cl " Start processing $bids_subj" ${preproc}/${log}


cd ${preproc}

kul_e2cl "Welcome to KUL_dwiprep_anat $v - $d" ${log}



# STEP 1 - Anatomical Processing ---------------------------------------------
# Brain_extraction, Registration of dmri to T1, MNI Warping, 5tt
mkdir -p T1w
mkdir -p dwi_reg

fmriprep_subj=fmriprep/"sub-${subj}"
fmriprep_anat="${cwd}/${fmriprep_subj}/anat/sub-${subj}_desc-preproc_T1w.nii.gz"
fmriprep_anat_mask="${cwd}/${fmriprep_subj}/anat/sub-${subj}_desc-brain_mask.nii.gz"
ants_anat_tmp=T1w/tmp.nii.gz
ants_anat=T1w/T1w_BrainExtractionBrain.nii.gz


# bet the T1w using fmriprep data
if [ ! -f T1w/T1w_BrainExtractionBrain.nii.gz ]; then
    kul_e2cl " skull stripping the T1w from fmriprep..." $log

    fslmaths $fmriprep_anat -mas $fmriprep_anat_mask $ants_anat_tmp

    # Transforming the T1w to fmriprep space
    xfm_search=($(find ${cwd}/${fmriprep_subj} -type f | grep from-orig_to-T1w_mode-image_xfm))
    num_xfm=${#xfm_search[@]}
    echo "  Xfm files: number : $num_xfm"
    echo "    notably: ${xfm_search[@]}"

    if [ $num_xfm -ge 1 ]; then

        antsApplyTransforms -i $ants_anat_tmp -o $ants_anat -r $ants_anat_tmp -n NearestNeighbor -t ${xfm_search[$i]} --float
        rm -rf $ants_anat_tmp

    else

        mv $ants_anat_tmp $ants_anat

    fi

else

    echo " skull stripping of the T1w already done, skipping..."

fi

# register mean b0 to betted T1w (rigid) 
ants_b0=dwi_b0.nii.gz
ants_type=dwi_reg/rigid

if [ ! -f dwi_reg/rigid_outWarped.nii.gz ]; then

    kul_e2cl " registering the the dmri b0 to the betted T1w image (rigid)..." ${log}
    antsRegistration --verbose 1 --dimensionality 3 \
        --output [${ants_type}_out,${ants_type}_outWarped.nii.gz,${ants_type}_outInverseWarped.nii.gz] \
        --interpolation Linear \
        --use-histogram-matching 0 --winsorize-image-intensities [0.005,0.995] \
        --initial-moving-transform [$ants_anat,$ants_b0,1] \
        --transform Rigid[0.1] \
        --metric MI[$ants_anat,$ants_b0,1,32,Regular,0.25] --convergence [1000x500x250x100,1e-6,10] \
        --shrink-factors 8x4x2x1 --smoothing-sigmas 3x2x1x0vox

else

    echo " registering the T1w image to  (rigid) already done, skipping..."

fi
 

# Apply the rigid transformation of the dMRI to T1 
#  to the wmfod and the preprocessed dMRI data
if [ ! -f dwi_preproced_reg2T1w_mask.nii.gz ]; then

    ConvertTransformFile 3 dwi_reg/rigid_out0GenericAffine.mat dwi_reg/rigid_out0GenericAffine.txt

    transformconvert dwi_reg/rigid_out0GenericAffine.txt itk_import \
        dwi_reg/rigid_out0GenericAffine_mrtrix.txt -force

    mrtransform dwi_preproced.mif -linear dwi_reg/rigid_out0GenericAffine_mrtrix.txt \
        dwi_preproced_reg2T1w.mif -nthreads $ncpu -force 

    if [ -f response/dhollander_wmfod.mif ]; then    
        mrtransform response/dhollander_wmfod.mif -linear dwi_reg/rigid_out0GenericAffine_mrtrix.txt \
            response/dhollander_wmfod_reg2T1w.mif -nthreads $ncpu -force 
        mrtransform response/dhollander_wmfod_norm.mif -linear dwi_reg/rigid_out0GenericAffine_mrtrix.txt \
            response/dhollander_wmfod_norm_reg2T1w.mif -nthreads $ncpu -force
        mrtransform response/dhollander_wmfod_noGM.mif -linear dwi_reg/rigid_out0GenericAffine_mrtrix.txt \
            response/dhollander_wmfod_noGM_reg2T1w.mif -nthreads $ncpu -force 
        mrtransform response/dhollander_wmfod_norm_noGM.mif -linear dwi_reg/rigid_out0GenericAffine_mrtrix.txt \
            response/dhollander_wmfod_norm_noGM_reg2T1w.mif -nthreads $ncpu -force
    fi
    if [ -f response/tax_wmfod.mif ]; then 
        mrtransform response/tax_wmfod.mif -linear dwi_reg/rigid_out0GenericAffine_mrtrix.txt \
            response/tax_wmfod_reg2T1w.mif -nthreads $ncpu -force 
    fi
    if [ -f response/tournier_wmfod.mif ]; then 
        mrtransform response/tournier_wmfod.mif -linear dwi_reg/rigid_out0GenericAffine_mrtrix.txt \
            response/tournier_wmfod_reg2T1w.mif -nthreads $ncpu -force         
    fi



    # create mask of the dwi data (that is registered to the T1w)
    kul_e2cl "    creating mask of the dwi_preproces_reg2T1w data..." ${log}
    dwi2mask dwi_preproced_reg2T1w.mif dwi_preproced_reg2T1w_mask.nii.gz -nthreads $ncpu -force

fi

# DO QA ---------------------------------------------
# Make an FA/dec image
mkdir -p qa

if [ ! -f qa/dhollander_dec_reg2T1w.mif ]; then

    kul_e2cl "   Calculating FA/dec..." ${log}
    dwi2tensor dwi_preproced_reg2T1w.mif dwi_dt_reg2T1w.mif -force
    tensor2metric dwi_dt_reg2T1w.mif -fa qa/fa_reg2T1w.nii.gz -mask dwi_preproced_reg2T1w_mask.nii.gz -force -nthreads $ncpu
    tensor2metric dwi_dt_reg2T1w.mif -adc qa/adc_reg2T1w.nii.gz -mask dwi_preproced_reg2T1w_mask.nii.gz -force -nthreads $ncpu

    if [ -f response/tournier_wmfod_reg2T1w.mif ]; then  
        fod2dec response/tax_wmfod_reg2T1w.mif qa/tax_dec_reg2T1w.mif -force -nthreads $ncpu
        fod2dec response/tax_wmfod_reg2T1w.mif qa/tax_dec_reg2T1w_on_t1w.mif -contrast $ants_anat -force -nthreads $ncpu
    fi
    if [ -f response/tax_wmfod_reg2T1w.mif ]; then  
        fod2dec response/tournier_wmfod_reg2T1w.mif qa/tournier_dec_reg2T1w.mif -force -nthreads $ncpu
        fod2dec response/tournier_wmfod_reg2T1w.mif qa/tournier_dec_reg2T1w_on_t1w.mif -contrast $ants_anat -force -nthreads $ncpu
    fi
    if [ -f response/dhollander_wmfod_reg2T1w.mif ]; then  
        fod2dec response/dhollander_wmfod_reg2T1w.mif qa/dhollander_dec_reg2T1w.mif -force -nthreads $ncpu
        fod2dec response/dhollander_wmfod_reg2T1w.mif qa/dhollander_dec_reg2T1w_on_t1w.mif -contrast $ants_anat -force -nthreads $ncpu
        fod2dec response/dhollander_wmfod_noGM_reg2T1w.mif qa/dhollander_noGM_dec_reg2T1w_on_t1w.mif -contrast $ants_anat -force -nthreads $ncpu
        fod2dec response/dhollander_wmfod_norm_reg2T1w.mif qa/dhollander_norm_dec_reg2T1w.mif -force -nthreads $ncpu
        fod2dec response/dhollander_wmfod_norm_reg2T1w.mif qa/dhollander_norm_dec_reg2T1w_on_t1w.mif -contrast $ants_anat -force -nthreads $ncpu
        fod2dec response/dhollander_wmfod_norm_noGM_reg2T1w.mif qa/dhollander_norm_noGM_dec_reg2T1w_on_t1w.mif -contrast $ants_anat -force -nthreads $ncpu

    fi

fi

# register ADC to betted T1w (non-linear) 
ants_adc=qa/adc_reg2T1w.nii.gz
ants_type=dwi_reg/nonlinear
ADC_nii_brain_mask=dwi_preproced_reg2T1w_mask.nii.gz
T1_brain_nii=T1w/T1w_BrainExtractionBrain.nii.gz
T1_brain_mask=$fmriprep_anat_mask


if [ ! -f dwi_reg/nonlinear_outWarped.nii.gz ]; then

    kul_e2cl " registering the the dmri ADC to the betted T1w image (non-linear)..." ${log}
    antsRegistration --dimensionality 3 \
        --output [${ants_type}_out,${ants_type}_outWarped.nii.gz,${ants_type}_outInverseWarped.nii.gz] \
        -x [${T1_brain_mask},${ADC_nii_brain_mask},NULL] \
        -m MI[${T1_brain_nii},${ants_adc},1,32,Regular,0.5] \
        -c [1000x500x250x0,1e-7,5] -t Affine[0.1] -f 8x4x2x1 -s 4x2x1x0 -u 1 -v 1\
        -m mattes[${T1_brain_nii},${ants_adc},1,64,Regular,0.5] -c [200x200x50,1e-7,5] \
        -t SyN[0.1,3,0] -f 4x2x1 -s 2x1x0mm -u 1 -z 1 --winsorize-image-intensities [0.005, 0.995]

else

    echo " registering the diffusion data to T1w (non-linear) already done, skipping..."

fi


# mrtransform the FODs non-linearly
if [ ! -f dwi_reg/mrtrix_warp_corrected.mif ]; then

    kul_e2cl " converting ants (non-linear) warps to mrtrix format..." ${log}
    input_fod_image=response/dhollander_wmfod_reg2T1w.mif
    template=dwi_preproced_reg2T1w_mask.nii.gz
    ants_warp=dwi_reg/nonlinear_out1Warp.nii.gz
    ants_affine=dwi_reg/nonlinear_out0GenericAffine.mat

    warpinit $input_fod_image dwi_reg/identity_warp[].nii -force

    for i in {0..2}
    do
        echo $i
        WarpImageMultiTransform 3 dwi_reg/identity_warp${i}.nii dwi_reg/mrtrix_warp${i}.nii -R $template $ants_warp $ants_affine   
    done

    warpcorrect dwi_reg/mrtrix_warp[].nii dwi_reg/mrtrix_warp_corrected.mif -force

fi

# Apply the non-linear transformation of the dMRI to T1 
#  to the wmfod 
#mrtransform $input_fod_image -warp dwi_reg/mrtrix_warp_corrected.mif dwi_reg/warped_fod_image.mif -force

if [ ! -f log/status.mrtransformNL.done ]; then

    kul_e2cl " Applying the non-linear transformation of the dMRI to T1..." ${log}

    if [ -f response/dhollander_wmfod_reg2T1w.mif ]; then    
        mrtransform response/dhollander_wmfod_reg2T1w.mif -warp dwi_reg/mrtrix_warp_corrected.mif \
            response/dhollander_wmfod_NLreg2T1w.mif -nthreads $ncpu -force 
        #mrtransform response/dhollander_wmfod_norm_reg2T1w.mif -warp dwi_reg/mrtrix_warp_corrected.mif \
        #    response/dhollander_wmfod_norm_NLreg2T1w.mif -nthreads $ncpu -force
        #mrtransform response/dhollander_wmfod_noGM_reg2T1w.mif -warp dwi_reg/mrtrix_warp_corrected.mif \
        #    response/dhollander_wmfod_noGM_NLreg2T1w.mif -nthreads $ncpu -force 
        #mrtransform response/dhollander_wmfod_norm_noGM_reg2T1w.mif -warp dwi_reg/mrtrix_warp_corrected.mif \
        #    response/dhollander_wmfod_norm_noGM_NLreg2T1w.mif -nthreads $ncpu -force
    fi
    if [ -f response/tax_wmfod_NLreg2T1w.mif ]; then 
        mrtransform response/tax_wmfod_reg2T1w.mif -warp dwi_reg/mrtrix_warp_corrected.mif \
            response/tax_wmfod_NLreg2T1w.mif -nthreads $ncpu -force 
    fi
    if [ -f response/tournier_wmfod_NLreg2T1w.mif ]; then 
        mrtransform response/tournier_wmfod_reg2T1w.mif -warp dwi_reg/mrtrix_warp_corrected.mif \
            response/tournier_wmfod_NLreg2T1w.mif -nthreads $ncpu -force         
    fi

    echo "done" > log/status.mrtransformNL.done

fi



# Create and transform extra freesurfer data ---------------------------------
mkdir -p roi
fs_labels=roi/labels_from_FS.nii.gz
fs_wmlabels=roi/labels_wm_from_FS.nii.gz
if [ ! -f log/status.freesurfer.done ]; then

    kul_e2cl " Starting with additional freesurfer processing..." ${log}

    # create the subcortical wm segmentations
    source $FREESURFER_HOME/SetUpFreeSurfer.sh
    mri_annotation2label --subject ${subj} --sd ${cwd}/freesurfer/sub-${subj} --hemi lh --lobesStrict lobes
    mri_annotation2label --subject ${subj} --sd ${cwd}/freesurfer/sub-${subj} --hemi rh --lobesStrict lobes
    mri_aparc2aseg --s ${subj} --sd ${cwd}/freesurfer/sub-${subj}  --labelwm --hypo-as-wm --rip-unknown \
     --volmask --o ${cwd}/freesurfer/sub-${subj}/${subj}/mri/wmparc.lobes.mgz --ctxseg aparc+aseg.mgz \
     --annot lobes --base-offset 200


    # Where is the freesurfer parcellation? 
    fs_aparc=${cwd}/freesurfer/sub-${subj}/${subj}/mri/aparc+aseg.mgz
    fs_wmparc=${cwd}/freesurfer/sub-${subj}/${subj}/mri/wmparc.mgz

    # Convert FS aparc back to original space
    fs_labels_tmp=roi/labels_from_FS_tmp.nii.gz
    fs_wmlabels_tmp=roi/labels_wm_from_FS_tmp.nii.gz
    mri_convert -rl $ants_anat -rt nearest $fs_aparc $fs_labels_tmp
    mri_convert -rl $ants_anat -rt nearest $fs_wmparc $fs_wmlabels_tmp

    # Transforming the FS aparc to fmriprep space
    xfm_search=($(find ${cwd}/${fmriprep_subj} -type f | grep from-orig_to-T1w_mode-image_xfm))
    num_xfm=${#xfm_search[@]}
    echo "  Xfm files: number : $num_xfm"
    echo "    notably: ${xfm_search[@]}"    


    # NEED TO CHANGE: instead of ommiting first, test if xfm file has no tranform in it
    if [ $num_xfm -ge 1 ]; then

        antsApplyTransforms -i $fs_labels_tmp -o $fs_labels -r $fs_labels_tmp -n NearestNeighbor -t ${xfm_search[$i]} --float
        antsApplyTransforms -i $fs_wmlabels_tmp -o $fs_wmlabels -r $fs_wmlabels_tmp -n NearestNeighbor -t ${xfm_search[$i]} --float

    else

        mv $fs_labels_tmp $fs_labels
        mv $fs_wmlabels_tmp $fs_wmlabels

    fi

    echo "done" > log/status.freesurfer.done

fi

# 5tt segmentation & tracking
mkdir -p 5tt
if [ ! -f 5tt/5tt2gmwmi.nii.gz ]; then

    kul_e2cl " Performig 5tt..." ${log}
    #5ttgen fsl $ants_anat 5tt/5ttseg.mif -premasked -nocrop -force -nthreads $ncpu 
    #5ttgen freesurfer $fs_aparc 5tt/5ttseg.mif -nocrop -force -nthreads $ncpu
    5ttgen freesurfer $fs_labels 5tt/5ttseg.mif -nocrop -force -nthreads $ncpu
    
    5ttcheck -masks 5tt/failed_5tt 5tt/5ttseg.mif -force -nthreads $ncpu 
    5tt2gmwmi 5tt/5ttseg.mif 5tt/5tt2gmwmi.nii.gz -force 

else

    echo " 5tt already done, skipping..."

fi

# Perform default mrtrix_fs labelconvert
mkdir -p connectome
if [ ! -f log/status.labelconvert.done ]; then

    kul_e2cl " Performig labelconvert..." ${log}
    labelconvert $fs_labels $FREESURFER_HOME/FreeSurferColorLUT.txt \
        /KUL_apps/mrtrix3/share/mrtrix3/labelconvert/fs_default.txt connectome/labelconvert_fs_default.nii.gz -force
    labelconvert $fs_labels $FREESURFER_HOME/FreeSurferColorLUT.txt \
        /KUL_apps/mrtrix3/share/mrtrix3/labelconvert/fs2lobes_cinginc_convert.txt connectome/labelconvert_fs2lobes_cinginc.nii.gz -force
    labelconvert $fs_labels $FREESURFER_HOME/FreeSurferColorLUT.txt \
        /KUL_apps/KUL_NeuroImaging_Tools/share/fs2thalamus_seg_convert.txt connectome/labelconvert_fs2thalamus_seg.nii.gz -force
    cat "done" > log/status.labelconvert.done

else

    echo " labelconvert already done, skipping..."

fi

# Run labelsgmfix (actually FSL FIRST) on the T1w data (usefull for subcortical segmentation)
if [ ! -f connectome/improved_labels_from_FS.nii.gz ]; then

    kul_e2cl " Performig labelsgmfix (FSL first)..." ${log}

    labelsgmfix -premasked $fs_labels T1w/T1w_BrainExtractionBrain.nii.gz $FREESURFER_HOME/FreeSurferColorLUT.txt connectome/improved_labels_from_FS.nii.gz -nocleanup

    mkdir -p first
    mv labelsgmfix-tmp-*/first* first
    rm -r labelsgmfix-tmp-* 

    mesh2voxel first/first-L_Thal_transformed.vtk dwi_preproced_reg2T1w_mask.nii.gz connectome/L_Thal_tmp.nii.gz
    mrthreshold -abs 0.5 connectome/L_Thal_tmp.nii.gz connectome/L_Thal.nii.gz
    mesh2voxel first/first-R_Thal_transformed.vtk dwi_preproced_reg2T1w_mask.nii.gz connectome/R_Thal_tmp.nii.gz
    mrthreshold -abs 0.5 connectome/R_Thal_tmp.nii.gz connectome/R_Thal.nii.gz
    
    #fslmaths connectome/labelconvert_fs2lobes_cinginc.nii.gz -thr 8 connectome/part2
    #fslmaths connectome/labelconvert_fs2lobes_cinginc.nii.gz -uthr 5 connectome/part1
    #fslmaths connectome/part1.nii.gz -add connectome/part2.nii.gz connectome/connectome_targets
    
else

    echo " labelsgmfix already done, skipping..."

fi

echo " Finished processing $bids_subj" 
# ---- END of the BIG loop over sessions

done

# write a file to indicate that dwiprep_anat runned succesfully
#   this file will be checked by KUL_preproc_all

echo "done" > ../dwiprep_anat_is_done.log

kul_e2cl "Finished " ${log}

