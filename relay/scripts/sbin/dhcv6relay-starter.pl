#!/usr/bin/perl

# Module: dhcv6relay-starter.pl
#
# **** License ****
#
# Copyright (c) 2019 AT&T Intellectual Property.  All rights reserved.
# Copyright (c) 2014-2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Author: Bob Gilligan
# Date: April 2010
# Description: Script to setup DHCPv6 relay agent
#
# **** End License ****

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5/";

use Getopt::Long;
use Vyatta::Config;

# Globals
my $rtinst;		# routing instance name
my $config_action;	# User's configuration action
my $cmd_args = "";	# Args to startup script built up here.
my $listen_set = 0;	# Number of listen interfaces set
my $upstream_set = 0;	# Number of upstream interfaces set
my $init_relay = "dhcv6relay.init";	# Path to init script
my $op_mode_flag;	# Indicates we are running in op mode if set.
my $debug_flag = 0;     # turn off debug by default

GetOptions(
    "rtinst=s"		=> \$rtinst,
    "config_action=s"	=> \$config_action,
    "op_mode"		=> \$op_mode_flag,
);

my $config_prefix;
if ( !defined $rtinst ) {
    $rtinst = "default";
}
if ( $rtinst eq "default" ) {
    $config_prefix = "service";
}
else {
    $config_prefix = "routing routing-instance $rtinst service";
}

my $exists       = ( $op_mode_flag ? 'existsOrig'       : 'exists' );
my $returnValues = ( $op_mode_flag ? 'returnOrigValues' : 'returnValues' );
my $returnValue  = ( $op_mode_flag ? 'returnOrigValue'  : 'returnValue' );
my $listNodes    = ( $op_mode_flag ? "listOrigNodes"    : "listNodes" );

sub log_msg {
    my $message = shift;

    print "DEBUG: $message" if $debug_flag;
}

# Return true if user's param string $param matches
# $match item for item, allowing wild-card string
# in $match.
#
sub param_match {
    my ($match, $param) = @_;

    my @match_array = split(" ", $match);
    my @param_array = split(" ", $param);

    if (scalar(@match_array) != scalar(@param_array)) {
	# match and param arrays don't even have the same number
	# of members.  Can't match.
	return 0;
    }

    my $index = 0;
    foreach my $match_item (@match_array) {
	my $param_item = $param_array[$index];
	$index++;
	if (!($match_item eq "*") &&
	    !($match_item eq $param_item)) {
	    # no wildcard or exact match
	    return 0;
	}
    }
    return 1;
}

# Substitue references of the form $1, $2, etc. in $string with
# values in $param_template string array.  $param_template is the
# Vyatta parameter string that the user configured.
#
sub param_substitute {
    my ($input_string, $param_template) = @_;

    # Turn $param_template into an array of items so that we can
    # reference individual items by number.
    my @param_template_array = split(" ", $param_template);

    my $index = 1;
    foreach my $param (@param_template_array) {
	if ($input_string =~ m/VAR-${index}/) {
	    log_msg("param_substitue: substituting $param for VAR-${index} \n");
	    $input_string =~ s/VAR-${index}/$param/;
	}
	$index++;
    }
    return $input_string;
}


#
# Functions that are used in the "action arrays"
#

my $addr_arg = "";

sub save_addr {
    my ($addr) = @_;
    
    $addr_arg = $addr;
}

sub listen_if {
    my ($ifname) = @_;

    if ($addr_arg eq "") {
	$cmd_args .= " -l $ifname";
    } else {
	$cmd_args .= " -l ${addr_arg}\%${ifname}";
    }
    $listen_set++;
    $addr_arg = "";
}

sub upstr_if {
    my ($ifname) = @_;

    if ($addr_arg eq "") {
	$cmd_args .= " -u $ifname";
    } else {
	$cmd_args .= " -u ${addr_arg}\%${ifname}";
    }
    $upstream_set++;
    $addr_arg = "";
}

sub add_arg {
    my ($string) = @_;

    $cmd_args .= $string;
}

# We have one "action array" for each of the three transitions:
# Pushing to a new non-leaf level, reach a leaf node with a value, and 
# poping back to non-leaf level.  Each entry in an action array has
# three elements:  1) a string to match against the parameter string; 
# 2) A function to call if it matches, and 3) a string to pass to that
# function.  The first string supports the use of "*" as a wildcard match.
# The third string supports a variable substitution syntax that
# substitues a value from the user's parameter string into the
# string to be passed into the function.
#


my @push_arr = (
);

my @pop_arr = (
    [ "listen-interface *", \&listen_if, "VAR-2" ],
    [ "upstream-interface *", \&upstr_if, "VAR-2" ],
);

my @leaf_arr = (
    [ "listen-interface * address *", \&save_addr, "VAR-4" ],
    [ "upstream-interface * address *", \&save_addr, "VAR-4" ],
    [ "max-hop-count *", \&add_arg, " -c VAR-2" ],
    [ "listen-port *",  \&add_arg, " -p VAR-2" ],
    [ "use-interface-id-option", \&add_arg, " -I" ],
);


#
# Walk through the action array passed in by reference. If an entry is
# found in that array whose first string passes the users's parameter
# string passed in, then perform parameter substitution on the third
# string in the entry, and call the function identified by the second
# element of the entry.
#
sub action_func {
    my ($action_arr_ref, $param) = @_;

    my @action_arr = @$action_arr_ref;

    foreach my $row (0 .. scalar(@action_arr) - 1) {
	my $match = $action_arr[$row][0];

	if (param_match ($match, $param)) {
	    my $func = $action_arr[$row][1];
	    my $arg = $action_arr[$row][2];

	    my $action_string = param_substitute($arg, $param);
	    &$func($action_string);
	}
    }
}

# 
# Recursive walk of the config tree starting at $level. $vc is the
# config pointer.  $depth records the current tree depth, primarily
# for debugging.  The final three args are references to the three
# "action arrays" discussed above.
#
sub walk_tree {
    my ($vc, $level, $depth, $push_arr_ref, $pop_arr_ref, $leaf_arr_ref) = @_;
    
    log_msg("in walk_tree at depth $depth level is: $level \n");

    my @values ;
    @values = $vc->$returnValues($level);
    my $num_values = scalar(@values);
    if ( $num_values == 0 ) {

        # We don't know if leaf nodes are single or multi-valued.
        # The returnOrigValues and returnValues functions only
        # return values if a leaf node is multi-valued.  So we need
        # to check here to see if this is a leaf single-valued node.
        #
        my $val = $vc->$returnValue($level);

        if ( defined $val ) {
            @values     = ($val);
            $num_values = 1;
        }
    }
    if ($num_values > 0) {
	foreach my $value (sort (@values)) {
	    my $leaf_value = $level . " " . $value;
	    log_msg("Leaf: $leaf_value\n");

	    action_func($leaf_arr_ref, $leaf_value);
	}
    } else {
	log_msg("Push to: $level\n");
	action_func($push_arr_ref, $level);

	my @node_array;
	@node_array = $vc->$listNodes($level);
	foreach my $node (sort (@node_array)) {
	    log_msg("node at depth $depth is $node\n");
	    walk_tree ($vc, $level . " " . $node, $depth + 1, 
		       $push_arr_ref, $pop_arr_ref, $leaf_arr_ref);
	}
        log_msg("Pop to: $level\n");
	action_func($pop_arr_ref, $level);
    }
}

#
# Main section
#

if (!defined($config_action)) {
    print STDERR "Must specify --config_action argument.\n";
    exit 1;
}

if ($config_action eq "DELETE") {
    print "Stopping the DHCPv6 Relay Agent...\n";
    my $status = system("$init_relay stop $rtinst");
    if ($status == 0) {
	printf("Done.\n");
    } else {
	printf("Failed.\n");
    }
    # Delete operation never fails...
    exit 0;
}

my $vcDHCP = new Vyatta::Config();

# Walk the config tree
# 
if ($vcDHCP->$exists("$config_prefix dhcpv6-relay")) {
    $vcDHCP->setLevel("$config_prefix dhcpv6-relay");
    log_msg("Initial call to walk_tree.\n");
    walk_tree($vcDHCP, "", 0, \@push_arr, \@pop_arr, \@leaf_arr);
} else {
    printf("DHCPv6 Relay Agent is not configured.\n");
    exit 1;
}

# Start, or re-start the relay agent
#

if (($listen_set == 0) || ($upstream_set == 0)) {
    printf("Error:  Must set at least one listen and upstream interface.\n");
    exit 1;
}

log_msg("cmd_args: $cmd_args \n");

my $status;
if ($config_action eq "SET") {
    printf("Starting the DHCPv6 Relay Agent...\n");
    $status = system("$init_relay start $rtinst $cmd_args");
} elsif ($config_action eq "ACTIVE") {
    printf("Re-Starting the DHCPv6 Relay Agent...\n");
    $status = system("$init_relay restart $rtinst $cmd_args");
} else {
    print STDERR "Invalid --config_action flag: $config_action\n";
    exit 1;
}

if ( (defined $status) && ($status == 0) ) {
    printf("Done.\n");
    exit 0;
} else {
    printf("Failed.\n");
    exit 1;
}

