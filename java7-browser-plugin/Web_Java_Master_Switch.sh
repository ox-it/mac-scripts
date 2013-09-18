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
# Script to enable or disable the Oracle Java 7 Web Plugin by moving it
# between the /Library/Internet Plug-Ins/ folder and a 'disabled/'
# folder therein, intended to be made available via Casper Self Service. 
#
# Leaves a breadcrumb file to indicate enabled status (the default for
# MMP systems is disabled), for use by other scripts including the
# post-install script for Oracle Java 7 installs/updates, so that the
# current state of the plugin can be maintained. 
#
# Also creates/updates a symlink in /Library/Java/JavaVirtualMachines/
# to the Java 7 plugin, since the plugin bundle contains the Oracle Java
# 7 JRE. This provides users with a stable location to place in their
# PATH, while the plugin itself may move.

BREADCRUMB_PATH='/etc/orchard'
BREADCRUMB='java_master_switch_web_java_enabled'
PLUGINS_DIR='/Library/Internet Plug-Ins'
DISABLED_PLUGINS_DIR="${PLUGINS_DIR}/disabled"
JAVA_PLUGIN='JavaAppletPlugin.plugin'
JRE_7_LINK_PATH='/Library/Java/JavaVirtualMachines'
JRE_7_LINK_FILE='1.7.x.jre'
PLIST_PATH='Contents/Enabled.plist'
PLISTBUDDY='/usr/libexec/PlistBuddy'
COCOA_DIALOG='/Applications/Utilities/cocoaDialog.app/Contents/MacOS/cocoadialog'

PLUGIN_ENABLED=0

VERSION=$( ${PLISTBUDDY} "${PLUGINS_DIR}/${JAVA_PLUGIN}/${PLIST_PATH}" \
    -c 'print CFBundleVersion' 2>/dev/null )

if [ $? -eq 0 ] && [[ $VERSION == 1.7.* ]]; then
    PLUGIN_ENABLED=1
    echo "Oracle Java 7 Plugin detected in active location."
fi

if [ $PLUGIN_ENABLED -eq 0 ]; then
    VERSION=$( ${PLISTBUDDY} "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}/${PLIST_PATH}" \
        -c 'print CFBundleVersion' 2>/dev/null )
    
    if [ $? -eq 0 ] && [[ $VERSION == 1.7.* ]]; then
        echo "Oracle Java 7 Plugin detected in disabled folder."
    else
        ERROR_MSG="No Oracle Java 7 plugins found in expected locations."
        echo $ERROR_MSG
        $COCOA_DIALOG ok-msgbox \
            --title "Error: Plug-In Missing" \
            --text "Plug-In Missing" \
            --informative-text "The Oracle Java 7 Plug-In could not be found" \
            --button1 "OK" \
            --no-cancel
        exit 1
    fi
fi

if [ $PLUGIN_ENABLED -eq 0 ]; then
    CHOICE=$( $COCOA_DIALOG msgbox \
        --title "Java Web Plug-In Master Switch" \
        --text "Java Web Plug-In Current Status: Disabled" \
        --informative-text "Enabling the Java Web Plug-In will allow use of Java web applications in Safari or Firefox, but represents a security risk. The Plug-In should only be enabled when needed, and disabled otherwise." \
        --button1 "Enable Java Web Plug-In" \
        --button2 "Cancel" )

    if [ $CHOICE -eq 1 ]; then
        echo "Moving plugin to active location."

        # delete any existing item in the destination to control /bin/mv behavior
        [ -e "${PLUGINS_DIR}/${JAVA_PLUGIN}" ] && \
            /bin/rm -rf "${PLUGINS_DIR}/${JAVA_PLUGIN}"
        /bin/mv "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}" "${PLUGINS_DIR}/${JAVA_PLUGIN}"

        # drop the breadcrumb
        [ -d "$BREADCRUMB_PATH" ] || /bin/mkdir "$BREADCRUMB_PATH"
        /usr/bin/touch "${BREADCRUMB_PATH}/${BREADCRUMB}"

        # update Java 7 JRE symlink
        [ -d "$JRE_7_LINK_PATH" ] || \
            /bin/mkdir -p "$JRE_7_LINK_PATH"
        /bin/ln -sf "${PLUGINS_DIR}/${JAVA_PLUGIN}" \
            "${JRE_7_LINK_PATH}/${JRE_7_LINK_FILE}"

        exit 0

    elif [ $CHOICE -eq 2 ]; then
        echo "User chose to cancel."
        exit 0
    fi
fi

if [ $PLUGIN_ENABLED -eq 1 ]; then
    CHOICE=$( $COCOA_DIALOG msgbox \
        --title "Java Web Plug-In Master Switch" \
        --text "Java Web Plug-In Current Status: Enabled" \
        --informative-text "Disabling the Java Web Plug-In will prevent Java web applications from running in any web browser, and is a good security practice. Desktop Java applications are generally unaffected by this change." \
        --button1 "Disable Java Web Plug-In" \
        --button2 "Cancel" )

    if [ $CHOICE -eq 1 ]; then
        echo "Moving plugin to disabled location."
        [ -e  "${DISABLED_PLUGINS_DIR}" ] || \
            /bin/mkdir "${DISABLED_PLUGINS_DIR}" 
        [ -e "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}" ] && \
            /bin/rm -rf "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}"
        /bin/mv "${PLUGINS_DIR}/${JAVA_PLUGIN}" "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}"

        # hoover the breadcrumb
        [ -x "${BREADCRUMB_PATH}/${BREADCRUMB}" ] && \
            /bin/rm "${BREADCRUMB_PATH}/${BREADCRUMB}"
       
        # update Java 7 JRE symlink
        [ -d "$JRE_7_LINK_PATH" ] || \
            /bin/mkdir -p "$JRE_7_LINK_PATH"
        /bin/ln -sf "${DISABLED_PLUGINS_DIR}/${JAVA_PLUGIN}" \
            "${JRE_7_LINK_PATH}/${JRE_7_LINK_FILE}"

        exit 0

    elif [ $CHOICE -eq 2 ]; then
        echo "User chose to cancel."
        exit 0
    fi
fi
