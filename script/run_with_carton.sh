#!/bin/bash

## These 3 lines are mandatory.
export PERLBREW_ROOT=/home/dlarochelle/perl5/perlbrew
export PERLBREW_HOME=/tmp/.perlbrew
echo source ${PERLBREW_ROOT}/etc/bashrc

source ${PERLBREW_ROOT}/etc/bashrc

set -u
set -o  errexit


#if [[ -z "$PERLBREW_BASHRD_VERSION" ]]
# then
#   echo "if branch taken"
#   source ~/perl5/perlbrew/etc/bashrc
#fi

perlbrew use perl-5.14.2@mediacloud

cmd_str="$1"
shift
full_path_str=`readlink -m $cmd_str`


working_dir=`dirname $0`

cd $working_dir

cd ..

echo carton exec -- $full_path_str $@
carton exec -- $full_path_str $@