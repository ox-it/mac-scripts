#!/usr/bin/perl
#
# Copyright (C) 2013 University of Oxford IT Services
#    contact <nsms-mac@it.ox.ac.uk>
#    authors: Robin Miller, Aaron Wilson, Marko Jung
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as
# published by the Free Software Foundation.
#
# First part of the partitioning to create volumes (Macintosh HD,
# Recovery HD, LocalStorage for user data) before other Casper Imaging
# tasks. It uses only the first command line argument provided by
# Casper, the target volume mount point, and obtains other information
# from extension attributes in the computer's JSS record.
#
# Due to the way in which Casper Imaging identifies volumes, the target
# volume must be the first non-EFI volume on the disk (slice 2), or the
# script will exit with an error.
#
# If the script does have to exit with an error, it will attempt to halt
# the imaging sequence by killing the parent Casper Imaging process.
# This appears to be necessary as Casper Imaging will otherwise attempt
# to proceed with imaging even if partitioning has failed.
#
# The script checks two input type "text field" extension attributes of 
# the host:
#  * "Commissioning: Custom LocalStorage UUID" to query an UUID for a
#     manually set up LocalStorage volume (i.e. manual softare RAID)
#  * "Commissioning: Custom System Volume Size" to override the 
#     computed default sizes for Macintosh HD
#    
# A followup script, partitionDisk2Post.pl, should be run post-imaging,
# and uses YAML formatted data left by this script in order to resize
# the Recovery partition and create an fstab file to mount LocalStorage
# on the target volume.
#
# Internal RCS Revision: 11469

use strict;
use warnings;

use LWP::UserAgent;
use XML::Simple qw(:strict);

use Config::YAML::Tiny;
use Mac::PropertyList qw(parse_plist_fh);

use constant {
    ASR             => '/usr/sbin/asr',
    COCOA_DIALOG    => '/Applications/Utilities/cocoadialog.app/Contents/MacOS/CocoaDialog',
    DISKUTIL        => '/usr/sbin/diskutil',
    KILLALL         => '/usr/bin/killall',
    NETWORKSETUP    => '/usr/sbin/networksetup',
    SYSCTL          => '/usr/sbin/sysctl',
    SWVERS          => '/usr/bin/sw_vers',
    
    CASPER_IMAGING  => 'Casper Imaging',
    LOCK_SCREEN     => 'LockScreen',

    JAMF_API_USER   => 'readonlyuser',
    JAMF_API_PASS   => 'cocacola',
    JSS_WEBLOC      => 'jss.acme.com',
    JSS_REALM       => 'Restful JSS Access -- Please supply your credentials',
    REST_START      => '/JSSResource/computers/macaddress/',
    REST_END        => '/subset/extension_attributes',

    LS_UUID_EA      => 'Commissioning: Custom LocalStorage UUID',
    TARGET_SIZE_EA  => 'Commissioning: Custom System Volume Size',

    LS_VOL_NAME     => 'LocalStorage',
    REC_VOL_NAME    => 'Recovery HD',
    REC_VOL_SIZE_M  => '1500',
    
    TMP_RECORD_FILE => '/tmp/partitionDisk2_tmp_record.yml',
};


# declare variables outside the eval block:
my (    
    $partitioning_record,
    $target_mount_point,
    $target_volume_info,
    $target_parent_info,
    $jss_params_ar,
    $local_storage_location
);

eval { # eval block to catch exceptions and first bring down Casper Imaging

    # Check that we are running on 10.8. Script will definitely fail on 10.6
    # due to differences in the diskutil program. It will probably work on 10.7
    # and later, but it has only been tested on 10.8:
    die "This script must be run on Mac OS X 10.8, but other version detected" 
        unless simple_os_check('10.8');

    # Replace any existing temp info file with an empty one, if one is found:
    eval {
        open(my $tmp_fh, '>', TMP_RECORD_FILE) or die "$!";
        close($tmp_fh) or die "$!";
        chmod 0755, TMP_RECORD_FILE or die "$!";
    };
    die "Could not overwrite or set mode of file '" . TMP_RECORD_FILE . "': $@"
        if $@;

    $partitioning_record = Config::YAML::Tiny->new( 
        config => TMP_RECORD_FILE,
        output => TMP_RECORD_FILE,
    );

    die "Systems using CoreStorage LVM are not yet supported. " . 
        "CoreStorage detected" 
        if check_for_CoreStorage();

    $target_mount_point = shift;

    die "Target mount point unusable or not given" 
        unless ((defined($target_mount_point)) and 
            ($target_mount_point =~ m|^/|));

    # make info object for target device:
    $target_volume_info = get_disk_info($target_mount_point);

    # make sure that target is already the first HFS+ partition (slice 2) on
    # the disk, since that is what it will be when we are done, and Casper
    # Imaging will blithely image to that slice even if the name and mount
    # point have changed.
    die "'$target_mount_point' is not the first HFS+ partition on the device" 
        unless ($target_volume_info->{DeviceIdentifier} =~ /^disk\d{1,2}s2$/);

    # get parent device info object (still works if target already appears as a
    # 'whole disk', eg.  CoreStorage logical volume - it will just contain
    # redundant info)
    $target_parent_info = get_disk_info($target_volume_info->{ParentWholeDisk});

    # get custom parameters, if any, from JSS:
    $jss_params_ar = get_JSS_ext_attrs();


    # Look for LocalStorage on the target disk (sub returns 0 if not found):
    $local_storage_location = 
        locate_local_storage_on_disk($target_volume_info->{ParentWholeDisk});

    if ($local_storage_location) {
        # LocalStorage was found on the target disk, and will be preserved...

        # record existing LocalStorage UUID:
        my $local_storage_info = get_disk_info($local_storage_location);
        $partitioning_record->set_local_storage_uuid(
            $local_storage_info->{VolumeUUID});

        repartition_preserving_local_storage(
            $target_volume_info->{ParentWholeDisk}, $local_storage_location);

    } else {
        # no LocalStorage found on the target disk...

        # check for custom LocalStorage volume UUID from JSS
        if (defined($jss_params_ar->{&LS_UUID_EA})) { 
                
            die "Malformed UUID '$jss_params_ar->{&LS_UUID_EA}' for " . 
                "LocalStorage found on JSS" 
                unless ($jss_params_ar->{&LS_UUID_EA} =~ 
                    /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i);

            # get info object for the UUID, and by not dying, confirm that it
            # exists on the system (the sub dies if UUID nonexistent):
            my $custom_local_storage_info = 
                get_disk_info($jss_params_ar->{&LS_UUID_EA}); 

            # make sure it is not on the target disk itself:
            if ($custom_local_storage_info->{ParentWholeDisk} eq 
                $target_volume_info->{ParentWholeDisk}) {
                die "Custom LocalStorage UUID from JSS, 
                    '$jss_params_ar->{&LS_UUID_EA}', was on the target volume";
            }

            # record this LocalStorage UUID:
            $partitioning_record->set_local_storage_uuid(
                $jss_params_ar->{&LS_UUID_EA});

            # repartition target disk, without a LocalStorage partition
            repartition_whole_disk($target_volume_info->{ParentWholeDisk}, 
                'no_LocalStorage');
            
        } else {
            
            # repartition and create default LocalStorage partition, as slice 4
            repartition_whole_disk($target_volume_info->{ParentWholeDisk});
           
            # record resultant LocalStorage UUID:
            my $new_local_storage_location = locate_local_storage_on_disk(
                $target_volume_info->{ParentWholeDisk});
            my $new_local_storage_info = get_disk_info(
                $new_local_storage_location);
            $partitioning_record->set_local_storage_uuid(
                $new_local_storage_info->{VolumeUUID});

        }
    }

    # Record Recovery HD identifier (which should be slice 3), and epoch date:
    $partitioning_record->set_recovery_hd_id(
        $target_volume_info->{ParentWholeDisk} . 's3');
    $partitioning_record->set_date(time);

    # Write out partitioning record to a YAML file to be picked up by an
    # 'after' script, which will create the fstab file to mount LocalStorage,
    # and resize the Recovery HD partition.
    $partitioning_record->write or die "Could not write to file '" . 
        TMP_RECORD_FILE . "'";


}; # end giant eval block

if ($@) {

    my @cocoa_dialog_args = qw(
        ok-msgbox
        --title
        'Disk Partitioning Failure'
        --icon
        stop
        --text
        'Disk Partitioning Failure - Installation Aborted'
        --no-cancel
        --float
        --no-newline
        --informative-text
        );

    my $cocoa_dialog_message =
        "Please notify your technical support contact.\n\nError: $@"; 

    # display dialog on screen, as background process:
    system(join ' ', COCOA_DIALOG, @cocoa_dialog_args, 
        "\"$cocoa_dialog_message\"",'&');

    print "Error occurred: $@\n";
    print "Killing Casper Imaging process...\n";
   
    # kill getppid does not work as the Jamf binary, not Casper Imaging, is the
    # parent of the script, so we do it this way:
    system(KILLALL, LOCK_SCREEN); # unlock the screen first...
    system(KILLALL, CASPER_IMAGING);

    exit 1;
}


print "\nPre-imaging partitionDisk2 tasks complete.\n";

###################
#   Subroutines   #
###################

# Matches a single OS X major version (eg. 10.8) against the OS it is being run
# on:
sub simple_os_check {

    my $version = shift;
    die "No version to match against given" unless defined($version);
    open (my $swvers_fh, '-|', SWVERS, '-productVersion') or 
        die "Could not open '" . SWVERS;
    my $os_match = 0;
    while (<$swvers_fh>) {
        $os_match = 1 if ((index $_, $version) == 0);
    }
    close $swvers_fh;
    return $os_match
}

# Checks for presence of CoreStorage LVM on machine.
# Returns 0 if not found, or a non-zero value if CS is found.
#
sub check_for_CoreStorage {

    my $cs_present = 1;

    open (my $du_fh, '-|', DISKUTIL, 'coreStorage', 'list')
        or die "Could not open filehandle for '" . DISKUTIL . "': $!";

    my $counter = -1; # just to ensure we are only seeing one line of output
    while (<$du_fh>) {
        $counter ++;
        $cs_present = 0 if /^No CoreStorage logical volume groups found/;
    }

    close $du_fh;

    return $counter + $cs_present;
}

# Returns a reference to a hash containing the diskutil info output for a given
# device. Note that keys are those in diskutil's XML output, not the default
# output (spaces are ommitted).
#
sub get_disk_info {

    my $device = shift; 
    my $plist_obj;

    open (my $du_fh, '-|', DISKUTIL, 'info', '-plist', $device)
        or die "Could not open filehandle for '" . DISKUTIL . "': $!";

    eval {
        $plist_obj = parse_plist_fh($du_fh);
    };
    die "Unexpected disktutil output for device '$device'. This is probably "
        . "because the specified device was not found on the system" if $@;

    close $du_fh;

    return $plist_obj->as_perl; # returns hash reference
}

# Returns a reference to a hash containing the diskutil list output for a given
# device. 
#
sub get_disks_list {

    my $device = shift; 
    my $plist_obj;

    open (my $du_fh, '-|', DISKUTIL, 'list', '-plist', $device)
        or die "Could not open filehandle for '" . DISKUTIL . "': $!";

    eval {
        $plist_obj = parse_plist_fh($du_fh);
    };
    die "Could not parse " . DISKUTIL . "'s output for device '$device'. "
        . "The device may not have been found on the system" if $@;

    close $du_fh;

    return $plist_obj->as_perl; # returns hash reference
}

# Returns the MAC address of the 'primary' built in network interface, or an
# empty string if no such MAC address exists. The 'primary' built in network
# interface is the 1st built in Ethernet interface on machines that have one,
# or the WiFi interface for those without wired networking built in.
#
# Optionally, you can specify an alternative octet separator to the default
# colon separator (':').
#
# Arg 1 (optional): octet separator (eg. '.' or '-')
# 
sub get_primary_MAC {

    my $separator = shift;

    open (my $nws_fh, '-|', NETWORKSETUP, '-listallhardwareports') 
        or die 'Could not open filehandle for ' . NETWORKSETUP;

    my $hw_address = ''; 

    while (<$nws_fh>) {

        # Look for 'Ethernet' or 'Ethernet 1':
        if (/^Hardware Port: Ethernet(\s1)?\s*$/) {
            
            # Get hardware address from subsequent lines. Interface entries are
            # separated by blank lines, so we exit this loop when we reach one:
            while (<$nws_fh>) {
                last if (/^\s*$/);
                $hw_address = $1 if /^Ethernet Address:\s+(([0-9a-f]{2}:?){6})/i;

            }

            # Exit loop if we have found built-in wired MAC:
            last if $hw_address;
        }

        # Look for WiFi: 
        if (/^Hardware Port: Wi-Fi\s*$/) {
            
            while (<$nws_fh>) {
                last if (/^\s*$/);
                $hw_address = $1 if /^Ethernet Address:\s+(([0-9a-f]{2}:?){6})/i;

            }
        }
    }

    close $nws_fh or die "Nonzero exit status from '" . NETWORKSETUP . "'";
   
    $hw_address =~ s/:/$separator/g if defined($separator);

    return $hw_address;
}

# Get custom parameters from Extension Attributes in the host's JSS record.
# Returns a hash reference containing the custom parameters, if any.
#
sub get_JSS_ext_attrs {

    my $user_agent = LWP::UserAgent->new;
    
    $user_agent->credentials(JSS_WEBLOC . ':443', JSS_REALM, JAMF_API_USER, 
        JAMF_API_PASS);

    my $ext_attrs_request = HTTP::Request->new(GET => 'https://' . JSS_WEBLOC . 
        REST_START . get_primary_MAC('.') . REST_END);

    my $result = $user_agent->request($ext_attrs_request);

    die "Failed to retrieve data from JSS using REST API: " . 
        $result->status_line unless $result->is_success;

    # makes the <name> element act as the key, and unnecessary 'value'
    # keys are replaced with their values so the resulting hash is
    # convenient to use. Also, empty values become undef rather than
    # empty hashes:
    my $xml_ref = XMLin($result->content, ForceArray => 0, KeyAttr => 'name', 
        ContentKey => '-value', SuppressEmpty => undef);
    
    # return reference to the part of the multi-level hash that contains the
    # useful data:
    return $xml_ref->{extension_attributes}->{attribute};
}


# Returns size for system partition.
#
sub get_system_partition_size {

    my $new_target_size;

    # check for custom size on JSS:
    if (defined($jss_params_ar->{+TARGET_SIZE_EA})) {

        # assume GB if no units, or G or GB given:
        $new_target_size = $1 if $jss_params_ar->{+TARGET_SIZE_EA} =~ 
            /^(\d+)\s*(GB?)?$/i;

        # understand M or MB and T or TB:
        $new_target_size = $1 / 1000 if $jss_params_ar->{+TARGET_SIZE_EA} =~ 
            /^(\d+)\s*(MB?)$/i;
        $new_target_size = $1 * 1000 if $jss_params_ar->{+TARGET_SIZE_EA} =~ 
            /^(\d+)\s*(TB?)$/i;

        # die if nothing has matched so far:
        die "Invalid value '$jss_params_ar->{+TARGET_SIZE_EA}' for target disk "
        . 'size received from JSS' unless defined($new_target_size);

    } else {
        
        # Calculate system partition size from disk size according to
        # internal policy
        my $ram_size = get_ram_size();
        my $parent_disk_size = $target_parent_info->{TotalSize}/10**9;

        if ($parent_disk_size < 65) {
            $new_target_size = 25 + $ram_size;
        } elsif ($parent_disk_size < 256) {
            $new_target_size = 50 + $ram_size;
        } else {
            $new_target_size = 60 + $ram_size;
        }
    }
    return $new_target_size;
}

# Return RAM size in GB. Note that the units are GB, not GiB, because
# Apple/diskutil use powers of 10, not 2, and that's where this number is
# going:
#
sub get_ram_size {
    open (my $sc_fh, '-|', SYSCTL, '-a') or die 
        "Could not open filehandle for '" . SYSCTL . "'";

    my $ram_bytes;

    while (<$sc_fh>) {
        $ram_bytes = $1 if /^hw\.memsize:\s+(\d+)$/;
    }

    close $sc_fh;

    die "Could not find 'hw.memsize' in '" . SYSCTL . "' output" 
        unless defined($ram_bytes);

    return $ram_bytes/10**9; # in (decimal) GB
}

# Returns Device Identifier for LocalStorage on the given Whole Disk, or 0 if
# not found.  Takes a Whole Disk identifier as an argument (eg. 'disk0').
#
sub locate_local_storage_on_disk {
  
    my $whole_disk = shift;
    die "No disk identifier given" unless defined($whole_disk);

    my $disk_info_hr = get_disks_list($whole_disk);

    # drill down (in output from diskutil list -plist 'parent_device') to array
    # of hashrefs each with info on a particular slice:
    my @slice_infos = 
        @{$disk_info_hr->{AllDisksAndPartitions}->[0]->{Partitions}};
   
    my $local_storage_location = 0;
    
    foreach my $slice_info_hr (@slice_infos) {

        if ((defined($slice_info_hr->{VolumeName})) 
                and ($slice_info_hr->{VolumeName} eq LS_VOL_NAME)) {

            $local_storage_location = $slice_info_hr->{DeviceIdentifier};
            last;
        }
    }
    return $local_storage_location;
}

# Repartitions the given disk into 2 or 3 slices (ignoring slice 1 for EFI)
# with JHFS+ formatting: 
#
# slice 2: (re-)creates the Apple_HFS typed target volume, with size determined
# by policy if no custom size specified in JSS record for machine, or to fill
# available disk space if no slice 4 to be created.
#
# slice 3: creates a volume of type Apple_Boot and specified size
#
# slice 4 (created by default, but optional): 'LocalStorage' (Apple_HFS),
# unless the 'no_LocalStorage' argument is given, in which case slice 2 is
# allowed to use all avaliable space not taken by slice 3.
#
# Arg 1 (required):  disk identifier (eg. 'disk0')
# Arg 2 (optional):  'no_LocalStorage' to prevent slice 4 from being created
#
sub repartition_whole_disk {

    my $disk_id = shift;

    die "No valid disk identifier given" 
        unless (defined($disk_id) and ($disk_id =~ /^disk\d{1,2}$/));

    my $make_ls = 1;
    my $arg2 = shift;
    $make_ls = 0 if (defined($arg2) and (lc($arg2) eq 'no_localstorage'));

    my @diskutil_args = ('partitionDisk', $disk_id);
    my (@s2_args, @s3_args, @s4_args);

    if ($make_ls == 1) {
        
        my $s2_size = get_system_partition_size();

        @s2_args = ('jhfs+', $target_volume_info->{VolumeName}, $s2_size . 'G');
        @s3_args = ('jhfs+', REC_VOL_NAME, REC_VOL_SIZE_M . 'M'); 
        @s4_args = ('jhfs+', LS_VOL_NAME, 'R'); 

        push @diskutil_args, ('3', 'GPT', @s2_args, @s3_args, @s4_args); 

    } else {
        
        @s2_args = ('jhfs+', $target_volume_info->{VolumeName}, 'R');

        # The extra 210MB here is due to an issue with diskutil where the size
        # of the EFI partition created as slice 1 gets taken always from the
        # last partition, rather than the partition with requested size 'R'. So
        # we anticipate this and request 210MB extra space for the last
        # partition to make up for it. Bug has been filed with Apple and on
        # Open Radar: http://openradar.appspot.com/13244804 
        # If it gets fixed and we don't notice, we'll just end up with a
        # slightly larger Recovery HD, which should not be a problem.
        @s3_args = ('jhfs+', REC_VOL_NAME, REC_VOL_SIZE_M + 210 . 'M'); 

        push @diskutil_args, ('2', 'GPT', @s2_args, @s3_args); 

    }
    # perform the repartitioning 
    system(DISKUTIL, @diskutil_args) == 0 
        or die "Problem encountered while attempting to " 
            . "repartition '$disk_id' with the arguments @diskutil_args";
   
    # adjust partition type of slice 3 from the default of Apple_HFS to
    # Apple_Boot
    set_recovery_partition_type($disk_id . 's3');

}

# Merges all partitions from slice 2 up to but not including the LocalStorage
# partition, and then splits them into new target volume and Recovery HD (of
# type 'Apple_Boot'), all while preserving the LocalStorage partition. The size
# of the resulting system volume is determined by the amount of space before
# the LocalStorage partition, and the size of the Recovery partition to be
# created. Custom system volume size from the JSS or size based on physical
# disk capacity and RAM size do not apply when existing LocalStorage on the
# same disk is preserved.
#
# Arg 1 (required): Target disk identifier (eg. 'disk0')
# Arg 2 (required): Valid LocalStorage volume identifier (eg. 'disk0s4')
#
sub repartition_preserving_local_storage {

    my ($disk_id, $local_storage_id) = @_;

    die "Invalid disk identifier given" 
        unless (defined($disk_id) and ($disk_id =~ /^disk\d{1,2}$/));

    # make sure that LocalStorage is a volume on the same disk at slice 3 or
    # greater:
    die "Invalid LocalStorage volume given" unless 
        (defined($local_storage_id) and 
            ($local_storage_id =~ /^($disk_id)s([3-9]|(\d{2}))$/));

    # start slice is always slice 2:
    my $start_slice = $disk_id . 's2';

    # make $end_slice one slice below LocalStorage:
    my $end_slice = $local_storage_id;
    $end_slice =~ s/s(\d+)$/'s' . ($1 - 1)/e;    

    # merge partitions if there are any to merge:
    unless ($start_slice eq $end_slice) {
        
        # 3rd argument is required but not used ($start_slice name is kept):
        my @diskutil_merge_args = 
            ('mergePartitions', 'jhfs+', 'tmp_vol', $start_slice, $end_slice);

        system(DISKUTIL, @diskutil_merge_args) == 0 
            or die "Problem encountered while attempting to merge partitions " 
            . "on '$disk_id' with diskutil arguments @diskutil_merge_args";
    }

    # split slice 2 into the Target volume and a Recovery volume:
    my @diskutil_split_args = ('splitPartition', $start_slice, '2');

    # diskutil's splitPartition verb doesn't accept 'R' as a partition size (as
    # the partitionDisk verb does), and '0B' as an alternatative size argument
    # indicating 'all remaining space' only works for the last specified
    # partition. So, we have to calculate the required size for slice 2
    # ourselves, so that we will end up with the desired size for slice 3:
    my $tmp_vol_info = get_disk_info($start_slice);
    my $s2_size_B = $tmp_vol_info->{TotalSize} - (REC_VOL_SIZE_M * 1000**2);
    my @s2_args = 
        ('jhfs+', $target_volume_info->{VolumeName}, $s2_size_B . 'B'); 

    # '0B' should thus give us the size REC_VOL_SIZE_M:
    my @s3_args = ('jhfs+', REC_VOL_NAME, '0B'); 

    push @diskutil_split_args, (@s2_args, @s3_args);

    system(DISKUTIL, @diskutil_split_args) == 0 
        or die "Problem encountered while attempting to split partition " 
        . "'$start_slice' with diskutil arguments @diskutil_split_args";

    # Test to make sure LocalStorage is now slice 4, as we would expect. This
    # test was put in place after seeing one instance of unexpected behavior by
    # diskutil when splitting a partition, where slice 2 became not slices 2
    # and 3 with LocalStorage as slice 4, as expected, but instead became
    # slices 2 and 5, followed by (in 'diskutil list' output) LocalStorage
    # still as slice 3:

    my $expected_local_storage_location = $target_volume_info->{ParentWholeDisk}
        . 's4';
        
    my $new_local_storage_location = 
        locate_local_storage_on_disk($target_volume_info->{ParentWholeDisk});
   
    die "Expected to find LocalStorage at '$expected_local_storage_location' " .
        "after partition split, but instead found it at " .
        "'$new_local_storage_location'" 
        unless 
            ($new_local_storage_location eq $expected_local_storage_location);


    # adjust partition type of slice 3 from the default of Apple_HFS to
    # Apple_Boot:
    set_recovery_partition_type($disk_id . 's3');
}


# Sets the given device ID's partition type to 'Apple_Boot' and leaves it
# unmounted
# 
# One argument required: valid partition device ID (eg. 'disk0s3')
#
sub set_recovery_partition_type {
    
    my $device_id = shift;
    die "Invalid device identifier given" 
        unless (defined($device_id) and 
            ($device_id =~ /^disk\d{1,2}s\d{1,2}$/));

    # create info object for the device
    my $partition_info = get_disk_info($device_id);

    # unmount if mounted
    if ($partition_info->{MountPoint}) {
        system(DISKUTIL, 'unmount', 'force', $device_id) == 0
            or die "Problem unmounting $device_id";
    }
    
    # modify partition type
    system(ASR, 'adjust', '--target', $partition_info->{DeviceNode}, 
        '--settype', 'Apple_Boot') == 0
        or die "Problem changing type of '$device_id' to Apple_Boot with" . ASR;
    
}
