#!/bin/bash
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
# Script intended to be used as Extension Attribute for the JAMF Casper
# Suite to collect the version and status of a installed Java 7 browser
# plug-in.

PLUGINS_DIR='/Library/Internet Plug-Ins'
DISABLED_PLUGINS_DIR="${PLUGINS_DIR}/disabled"
JAVA_PLUGIN='JavaAppletPlugin.plugin'
PLIST_PATH='Contents/Enabled.plist'
PLISTBUDDY='/usr/libexec/PlistBuddy'

if [ -e "${PLUGINS_DIR}/${JAVA_PLUGIN}/${PLIST_PATH}" ]; then
    VERSION=$( ${PLISTBUDDY} "${PLUGINS_DIR}/${JAVA_PLUGIN}/${PLIST_PATH}" \
      -c 'print CFBundleVersion' 2>/dev/null )

    if [ $? -eq 0 ]; then
        RETURN_VAL="${VERSION} (Enabled)"
    else
        RETURN_VAL="Error finding version (plugin in Enabled location)"
    fi

elif [ -e "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}/${PLIST_PATH}" ]; then
    VERSION=$( ${PLISTBUDDY} "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}/${PLIST_PATH}" \
      -c 'print CFBundleVersion' 2>/dev/null )

    if [ $? -eq 0 ]; then
        RETURN_VAL="${VERSION} (Disabled)"
    else
        RETURN_VAL="Error finding version (plugin in Disabled location)"
    fi

else
    RETURN_VAL="No Oracle Java plugin found"
fi

echo "<result>${RETURN_VAL}</result>"
