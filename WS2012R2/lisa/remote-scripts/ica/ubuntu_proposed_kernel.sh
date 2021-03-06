#!/bin/bash

########################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
########################################################################

########################################################################
#
# Description:
#     This script was created to automate the installation and validation
#     of an Ubuntu proposed kernel.
#
#     The following steps are performed:
#		1. Adds the proposed repository source for the detected release.
#		2. Installs the newest proposed kernel version or newest proposed
#          azure kernel.
#		3. Matching LIS daemons packages are also installed.
#		4. Modifies grub configuration to boot the installed kernel.
#
# Note: Flags must alternate - if azure_kernel_edge is set to "yes",
#     then azure_kernel must be set to "no".
#
########################################################################

DEBUG_LEVEL=3
release=$(lsb_release -c | cut -f2)
export DEBIAN_FRONTEND=noninteractive

#
# Adds a timestamp to the log file
#
function LogMsg() {
    echo $(date "+%a %b %d %T %Y") : ${1}
}

dbgprint() {
    if [ "$1" -le $DEBUG_LEVEL ]; then
        echo "$2"
    fi
}

UpdateTestState() {
    echo "$1" > ~/state.txt
}

UpdateSummary() {
    echo "$1" >> ~/summary.log
}

#Source constans file
if [ -e $HOME/constants.sh ]; then
    . $HOME/constants.sh
else
    echo "ERROR: Unable to source the config file."
    exit 1
fi

apply_proposed_kernel() {
    candidate_kernel=$(apt-cache policy linux-image-generic | grep "Candidate")
    apt install -y -qq linux-image-generic/$release-proposed
    if [[ $? -ne 0 ]]; then
        UpdateSummary "Error: Unable to install the proposed kernel!"
        UpdateTestState $ICA_TESTABORTED
        exit 1
    fi

    apt install -y -qq linux-tools-generic/$release-proposed
    apt install -y -qq linux-cloud-tools-generic/$release-proposed
    apt install -y -qq linux-cloud-tools-common/$release-proposed
    if [[ $? -ne 0 ]]; then
        UpdateSummary "Error: Unable to install the proposed LIS daemons packages!"
        UpdateTestState $ICA_TESTABORTED
        exit 1
    fi
}

apply_proposed_kernel_azure() {
    candidate_kernel=$(apt-cache policy linux-azure | grep "Candidate")
    apt install -y -qq linux-azure/$release
    if [[ $? -ne 0 ]]; then
        UpdateSummary "Error: Unable to install the proposed kernel azure!"
        UpdateTestState $ICA_TESTABORTED
        exit 1
    fi
}

apply_proposed_kernel_azure_edge() {
    candidate_kernel=$(apt-cache policy linux-azure-edge | grep "Candidate")
    apt install -y -qq linux-azure-edge/$release
    if [[ $? -ne 0 ]]; then
        UpdateSummary "Error: Unable to install the proposed kernel azure-edge!"
        UpdateTestState $ICA_TESTABORTED
        exit 1
    fi
}

modify_grub() {
    #
    # Due to Ubuntu inconsistencies in the naming conventions,
    # we must slightly change the kernel version and parse it further
    #
    version=$(echo $candidate_kernel | awk  '{print $2}' | cut -c 1-9 | sed 's/\.\([^.]*\)$/-\1/')
    if [[ $version == *- ]]; then
        version=${version::-1}
    fi

    # Grub will boot the installed kernel as a permanent change
    sed -i.bak 's/GRUB_DEFAULT=.*/GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux '$version'-generic"/g' /etc/default/grub
    update-grub
}

#
# Create the state.txt file so the ICA script knows we are running
#
UpdateTestState "TestRunning"

# Check for summary.log
if [ -e ~/summary.log ]; then
    rm -rf ~/summary.log
fi

# Check if script is running on primary vm or secondary vm
# If constants.sh is present, means that script is running on 1st vm
# Otherwise it's running on secondary vm
willInstall=$(cat constants.sh | grep VM2NAME)

#
# Start the setup
#
echo "deb http://archive.ubuntu.com/ubuntu/ $release-proposed restricted main multiverse universe" >> /etc/apt/sources.list

# Cleaning up repos cache
echo "Updating apt cache..."
apt clean all
apt -qq update

#
# Installing the proposed kernel
#
if [ $azure_kernel_edge == "yes" ]; then
    apply_proposed_kernel_azure_edge
    if [ 0 -ne $? ]; then
        dbgprint 1 "Error: Couldn't install the proposed kernel: ${candidate_kernel}"
        UpdateTestState $ICA_TESTABORTED
        exit 1
    fi
    dbgprint 3 ""
    dbgprint 3 "Proposed kernel azure_edge = ${candidate_kernel}"
    dbgprint 3 ""

    UpdateSummary "Proposed kernel azure_edge = ${candidate_kernel}"
    UpdateSummary "Proposed kernel azure_edge has been successfully installed."


elif [ $azure_kernel == "yes" ] && [ $azure_kernel_edge == "no" ]; then
    apply_proposed_kernel_azure
    if [ 0 -ne $? ]; then
        dbgprint 1 "Error: Couldn't install the proposed kernel: ${candidate_kernel}"
        UpdateTestState $ICA_TESTABORTED
        exit 1
    fi

    dbgprint 3 ""
    dbgprint 3 "Proposed kernel azure = ${candidate_kernel}"
    dbgprint 3 ""

    UpdateSummary "Proposed kernel azure = ${candidate_kernel}"
    UpdateSummary "Proposed kernel azure has been successfully installed."

else
    apply_proposed_kernel
    if [ 0 -ne $? ]; then
        dbgprint 1 "Error: Couldn't install the proposed kernel: ${sts}"
        UpdateTestState $ICA_TESTABORTED
        exit 1
    fi

    dbgprint 3 ""
    dbgprint 3 "Proposed kernel = ${candidate_kernel}"
    dbgprint 3 ""

    UpdateSummary "Proposed kernel = ${candidate_kernel}"
    UpdateSummary "Proposed kernel has been successfully installed."
fi

#
# Changing grub config to boot the proposed kernel
#
modify_grub
if [ 0 -ne $? ]; then
    dbgprint 1 "Error: Couldn't modify the grub config: ${sts}"
    UpdateTestState $ICA_TESTABORTED
    exit 1
fi

echo "Grub configuration has been successfully modified."

# Send the script on the secondary vm if it's the case
if [ "$willInstall" -eq 0 ]; then
    . ~/constants.sh || {
    echo "ERROR: unable to source constants.sh!"
    echo "TestAborted" > state.txt
    exit 2
    }

    scp -i ~/.ssh/"$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=no ~/ubuntu_proposed_kernel.sh "$SERVER_OS_USERNAME"@"$STATIC_IP2":/tmp/ubuntu_proposed_kernel.sh
    if [ 0 -ne $? ]; then
        msg="ERROR: Unable to send the file from VM1 to VM2"
        LogMsg "$msg"
        UpdateSummary "$msg"
        UpdateTestState $ICA_TESTFAILED
        exit 10
    fi

    ssh -i ~/.ssh/"$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=no "$SERVER_OS_USERNAME"@"$STATIC_IP2" bash /tmp/ubuntu_proposed_kernel.sh
    if [ $? -ne 0 ]; then
        msg="ERROR: Script failed on secondary vm"
        LogMsg "$msg"
        UpdateSummary "$msg"
        UpdateTestState $ICA_TESTFAILED
        exit 10
    fi

    ssh -i ~/.ssh/"$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=no "$SERVER_OS_USERNAME"@"$STATIC_IP2" init 0
    LogMsg "Kernel install completed successfully on VM2"
fi

#
# Let the caller know everything worked
#
dbgprint 1 "Exiting with state: TestCompleted."
UpdateTestState "TestCompleted"
exit 0
