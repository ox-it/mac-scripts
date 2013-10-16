#!/bin/bash
#
# Copyright (C) 2013 University of Oxford IT Services
#    contact <nsms-mac@it.ox.ac.uk>
#    authors: Robin Miller, Aaron Wilson, Marko Jung
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as
# published by the Free Software Foundation.
#
# Script called after the first reboot of a freshly installed system
#
# Run all policies for system build in the right order
#  * BuildPre        - for preparatory steps
#  * FirstRun        - for stuff that should only run during system build
#  * SoftwareInstall - install all applications scoped to a machine
#  * SoftwareUpdate  - install all updates to all installed apps
#  * PrinterInstall  - install all printers and drivers
#  * BuildPost       - cleanup after system build
#
# Internal RCS Revision: 7675

# Variables
JAMF='/usr/sbin/jamf'
DNSNAME=$(hostname -s)
LOGFILE=/var/tmp/orchard-deployment-$(date +%Y%m%d-%H%M).log
JSSCONTACTTIMEOUT=120
JSSURL='https://jss.acme.org'
ENROLLLAUNCHDAEMON='/Library/LaunchDaemons/com.jamfsoftware.firstrun.enroll.plist'
TIMESERVER='ntp.acme.com'
TIMEZONE='Europe/London'
PORTABLE=0

######################################
# Tasks not requiring JSS connection #
######################################

if [[ ! $OSTYPE =~ darwin12.* ]]; then

    echo "This script runs on Mac OS X 10.8.x only"
    exit 1
fi

# Check if portable or workstation:
echo '--- form factor' >> $LOGFILE
MODEL=$(system_profiler SPHardwareDataType | grep 'Model Name:' | awk -F': ' '{print $2;}')
[[ $MODEL =~ MacBook ]] && PORTABLE=1
echo "Is portable: $PORTABLE" >> $LOGFILE

# Set computer name to match DNS name
echo '--- computer name' >> $LOGFILE
systemsetup -setcomputername ${DNSNAME} | tee -a ${LOGFILE}

# Set time zone, NTP use, and NTP server. These are later enforced with MCX but
# the MCX setting is not applied until the first console user logs in. Also, we
# may in future want to drop MCX enforcement of the time zone setting.
echo '--- date and time' >> $LOGFILE
systemsetup -setnetworktimeserver $TIMESERVER | tee -a ${LOGFILE}
systemsetup -settimezone "$TIMEZONE" | tee -a ${LOGFILE}
systemsetup -setusingnetworktime on | tee -a ${LOGFILE} 

# if not a portable, turn Airport off:
echo '--- airport power status' >> $LOGFILE
if [ $PORTABLE -eq 1 ]; then
    echo 'Portable hardware. No change to Airport power status.' >> $LOGFILE
else 
    AIRPORT=$(networksetup -listallhardwareports | grep -A 1 'Hardware Port: Wi-Fi' | grep 'Device:' | awk '{ print $2 }')
    echo "Desktop hardware. Turning AirPort ($AIRPORT) power off." >> $LOGFILE
    networksetup -setairportpower $AIRPORT off
    echo "Command exit code: $?" >> $LOGFILE
fi

# Power settings (-c = AC power, -b = battery power)
echo '--- power settings' >> $LOGFILE
pmset -c displaysleep 20 sleep 0 halfdim 10 womp 1 autorestart 1 powerbutton 0 | tee -a ${LOGFILE}
echo "Command exit code for AC settings: $?" >> $LOGFILE
pmset -b displaysleep 10 sleep 30 halfdim 1 womp 1 autorestart 1 | tee -a ${LOGFILE}
echo "Command exit code for battery settings: $?" >> $LOGFILE

# Enable SSH, as StartupScript.sh which normally does this isn't created early enough
echo '--- starting ssh daemon' >> $LOGFILE
${JAMF} startSSH
echo "Command exit code: $?" >> $LOGFILE

# Enables ARD for the hidden casadmin account after reimage
echo '--- ARD' >> $LOGFILE
/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -users casadmin \
    -privs -all -restart -agent | tee -a ${LOGFILE}

# Disable automatic Apple Software Update checks:
echo '--- disabling automatic apple software update checks' >> $LOGFILE

SU_INI_RESULT=$(launchctl unload -w /System/Library/LaunchDaemons/com.apple.softwareupdatecheck.initial.plist 2>&1)
SU_PER_RESULT=$(launchctl unload -w /System/Library/LaunchDaemons/com.apple.softwareupdatecheck.periodic.plist 2>&1)

if [ "$SU_INI_RESULT" ] || [ "$SU_PER_RESULT" ]; then
    # If these weren't empty strings, there were errors
    echo "$SU_INI_RESULT" >> ${LOGFILE}
    echo "$SU_PER_RESULT" >> ${LOGFILE}
else
    echo "Automatic Apple Software Update check launchd jobs unloaded and disabled-key set." >> $LOGFILE
fi

# Create /Users/Shared if non-existent
echo '--- /Users/Shared' >> $LOGFILE
if [ ! -d /Users/Shared ]; then
    mkdir -p /Users/Shared | tee -a ${LOGFILE}
    chown root /Users/Shared | tee -a ${LOGFILE}
    chgrp wheel /Users/Shared | tee -a ${LOGFILE}
    chmod 1777 /Users/Shared | tee -a ${LOGFILE}
fi

# Clean up JAMF Imaging's Spotlight disabling files:
echo '--- cleaning up spotlight-disabling files and restarting indexing' >> $LOGFILE

TARGETFILES=("/.fseventsd/no_log" "/.metadata_never_index")
FIXNEEDED=0
RESULT=0

for FILE in "${TARGETFILES[@]}"; do
    if [ -e $FILE ]; then
        (( FIXNEEDED += 1 ))
        rm -f "$FILE" 
        (( RESULT += $? ))
    fi
done

if [ $FIXNEEDED -gt 0 ]; then
    echo 'Leftover files found. Cleanup required.' >> $LOGFILE

    if [ $RESULT -eq 0 ]; then
        echo 'Cleanup was successful.' >> $LOGFILE
    else
        echo 'There were problems cleaning up the files.' >> $LOGFILE
    fi

    # clear index and start Spotlight
    mdutil -E -i on /
else
    echo 'No cleanup required!' >> $LOGFILE
fi

# Wait a certain number of minutes for JAMF enroll.sh script to complete. We do
# this because the enroll script put in place during the JAMF Imaging process
# uses the 'jamf manage' command which seems to often fail (with a 401
# (authentication) error), so we want to run 'jamf enroll' as well before we
# start to do things that require communication with the JSS. However, we also
# don't want to have a conflict if both happen to be run at the same time,
# which has occasionally happened. The enroll.sh script will try to run, but if
# it cannot contact the JSS, will wait 5 minutes and then try only once more,
# hence the 8 minute wait. 

WAITLIMIT=$(( 8 * 60 ))
WAITINCREMENT=30
echo "--- checking to see if JAMF enroll.sh is still running" >> $LOGFILE
while [ -e "$ENROLLLAUNCHDAEMON" ]; do
    if [ $WAITLIMIT -le 0 ]; then
        echo "Reached wait timeout of ${WAITLIMIT} seconds!" >> $LOGFILE
        break
    fi

    echo "Still not complete. Waiting another ${WAITINCREMENT} seconds..." >> $LOGFILE
    sleep $WAITINCREMENT 
    (( WAITLIMIT -= $WAITINCREMENT ))

done
echo 'Continuing now...' >> $LOGFILE



##################################
# Tasks requiring JSS connection #
##################################

# Test for JSS connection
echo '--- testing jss connection' >> $LOGFILE
loop_ctr=1
while ! curl --silent -o /dev/null --insecure ${JSSURL} ; do
    sleep 1;
    loop_ctr=$((loop_ctr+1))
    if [ $((loop_ctr % 10 )) -eq 0 ]; then
        echo "${loop_ctr} attempts" >> $LOGFILE
    fi

    if [ ${loop_ctr} -eq ${JSSCONTACTTIMEOUT} ]; then
        echo "I'm bored ... giving up after ${loop_ctr} attempts" >> $LOGFILE
        exit 1
    fi
done	
echo "Contacted JSS (${loop_ctr} attempts)" >>$LOGFILE ;

# Enroll 10.8 machines to allow certificate-based authentication
echo '--- enroll' >> $LOGFILE
${JAMF} enroll | tee -a ${LOGFILE}

# Flush policy history
echo '--- flushPolicyHistory' >> $LOGFILE
${JAMF} flushPolicyHistory | tee -a ${LOGFILE}

# Call some triggers
echo '--- JAMF triggers' >> $LOGFILE
${JAMF} policy -action BuildPre | tee -a ${LOGFILE}
${JAMF} policy -action FirstRun | tee -a ${LOGFILE}
${JAMF} policy -action SoftwareInstall | tee -a ${LOGFILE}
${JAMF} recon | tee -a ${LOGFILE}
${JAMF} policy -action SoftwareUpdate | tee -a ${LOGFILE}
${JAMF} policy -action PrinterInstall | tee -a ${LOGFILE}
${JAMF} policy -action BuildPost | tee -a ${LOGFILE}
${JAMF} recon | tee -a ${LOGFILE}

# Done!
echo '--- Done!' >> $LOGFILE
