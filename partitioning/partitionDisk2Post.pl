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
# Followup script to partitionDisk2.pl to be run after imaging, performing the
# following tasks:
#
#  1. Resizes the Recovery volume on the target disk to the maximum (and
#  original) size, as it may have been resized to 650MB by the OS X
#  installer.
#  2. Creates an /etc/fstab file on the target volume to mount
#  LocalStorage at the required location.
#
# Internal RCS Revision: 9352

use strict;
use warnings;
use File::Spec;

use Config::YAML::Tiny;

use constant {
    DISKUTIL          => '/usr/sbin/diskutil',

    FSTAB_FILE        => '/etc/fstab',
    LS_MOUNT_POINT    => '/Users',

    TMP_FILE_EXPIRY_S => 3600,
    TMP_RECORD_FILE   => '/tmp/partitionDisk2_tmp_record.yml',
};

my $target_mount_point = shift;
die "Target mount point not provided or invalid" 
    unless ((defined($target_mount_point)) and ($target_mount_point =~ m|^/|));


die "Could not read from record file '" . TMP_RECORD_FILE . "'"
    unless (-r TMP_RECORD_FILE);

my $partitioning_record = Config::YAML::Tiny->new( 
    config => TMP_RECORD_FILE,
);

# sanity check data in record file:
die "Invalid values in record file '" . TMP_RECORD_FILE . "'" unless (
    ($partitioning_record->{date} =~ /^\d{10}$/) and
    ($partitioning_record->{recovery_hd_id} =~ /^disk\d{1,2}s\d{1,2}$/) and
    ($partitioning_record->{local_storage_uuid} =~
        /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i)
);
    
# make sure record file is recent:
die "Record file is out of date" if 
    ($partitioning_record->{date} < (time - TMP_FILE_EXPIRY_S));

####
# Followup Task 1: Resize Recovery partition back to maxiumum available size:
####

# mount the Recovery partition. Although we expect this partition to be
# unmounted now, diskutil does not appear to return an error when told to mount
# an already mounted partition, so we aren't checking for that condition:
system(DISKUTIL, 'mount', $partitioning_record->{recovery_hd_id}) == 0 
    or die "Problem encountered while mounting Recovery partition";
    
my @diskutil_resize_args = ('resizeVolume', 
    $partitioning_record->{recovery_hd_id}, 'R');

system(DISKUTIL, @diskutil_resize_args) == 0 
    or die "Problem encountered while attempting to re-grow Recovery partition "
    . "with diskutil arguments @diskutil_resize_args";

# unmount the Recovery partition:
system(DISKUTIL, 'unmount', $partitioning_record->{recovery_hd_id}) == 0 
    or die "Problem encountered while unmounting Recovery partition";

####
# Followup Task 2: Create fstab file on system volume to automount LocalStorage:
####

my $fstab_location = File::Spec->canonpath(File::Spec->catfile(
        $target_mount_point, FSTAB_FILE));

my @fstab_elements = (
    'UUID=' . $partitioning_record->{local_storage_uuid},
    LS_MOUNT_POINT,
    'hfs',
    'rw',
    '0',
    '2'
);

eval {
    open(my $fstab_fh, '>', $fstab_location) or die "$!";
    print $fstab_fh "@fstab_elements", "\n" or die "$!";
    close($fstab_fh) or die "$!";
    chmod 0644, $fstab_location or die "$!";
    chown 0, 0, $fstab_location or die "$!";
};
die "Could not write or set mode or ownership of file '" . FSTAB_FILE . "': $@"
    if $@;

# delete the temporary record file:
unlink TMP_RECORD_FILE;

print "\nPost-imaging followup tasks complete.\n";
