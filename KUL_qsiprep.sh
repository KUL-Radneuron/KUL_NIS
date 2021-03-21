#!/bin/bash -e
# Bash shell script to run qsiprep
#
# Requires docker
#
# @ Stefan Sunaert - UZ/KUL - stefan.sunaert@uzleuven.be
# 19/03/2021
version="0.1"

kul_main_dir=`dirname "$0"`
source $kul_main_dir/KUL_main_functions.sh
cwd=$(pwd)

# FUNCTIONS --------------

# function Usage
function Usage {

cat <<USAGE

`basename $0` runs qsiprep tuned for KUL/UZLeuven data

Usage:

  `basename $0` <OPT_ARGS>

Example:

  `basename $0` -p JohnDoe 

Required arguments:

     -p:  participant name

Optional arguments:

	 -g:  use gpu (does not work an MacOs)
     -n:  number of cpu to use (default 15)
     -v:  show output from commands

USAGE

	exit 1
}


# CHECK COMMAND LINE OPTIONS -------------
#
# Set defaults
silent=1 # default if option -v is not given
ncpu=15
gpu=0

# Set required options
p_flag=0

if [ "$#" -lt 1 ]; then
	Usage >&2
	exit 1

else

	while getopts "p:n:gv" OPT; do

		case $OPT in
		p) #participant
			participant=$OPTARG
            p_flag=1
		;;
        n) #ncpu
			ncpu=$OPTARG
		;;
		g) #verbose
			gpu=1
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
if [ $p_flag -eq 0 ] ; then
	echo
	echo "Option -p is required: give the BIDS name of the participant." >&2
	echo
	exit 2
fi

#echo $participant

qsi_data="${cwd}/BIDS"
qsi_scratch="${cwd}/qsiprep_work_${participant}"
qsi_out="${cwd}/qsiprep"

if [ $gpu -eq 1 ]; then
	gpu_cmd="--gpus all"
else
	gpu_cmd=""
fi

docker run --rm -it \
    -v $FS_LICENSE:/opt/freesurfer/license.txt:ro \
    -v $qsi_data:/data:ro \
    -v $qsi_out:/out \
    -v $qsi_scratch:/scratch \
    $gpu_cmd \
    pennbbl/qsiprep:0.12.2 \
    /data /out participant \
    -w /scratch \
    --output-resolution 1.2 


    #--nthreads $ncpu \
    #--omp-nthreads $ncpu

  #  --participant_label "$participant" \