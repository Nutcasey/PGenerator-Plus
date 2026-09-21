#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP;
use lib "$Bin/../../usr/share/PGenerator";
# The worker's caller guard prevents its calibration main loop from running.
# Import its actual target, metric and gain functions for numerical parity.
do "$Bin/../../usr/bin/meter_lg_autocal.pl";
die $@ if $@;
our ($LG_AUTOCAL_CONFIG,$LG_AUTOCAL_TARGET_CONTEXT);
my $request=decode_json(do {local $/; <STDIN>});
$LG_AUTOCAL_CONFIG={signal_mode=>'sdr',pattern_signal_range=>1,transport_signal_range=>1,
 color_format=>1,max_bpc=>10,lg_autocal_26=>1,full_workflow=>1,target_gamma=>$request->{gamma}};
$LG_AUTOCAL_TARGET_CONTEXT=autocal_target_context_for($request->{gamma},'sdr',$LG_AUTOCAL_CONFIG);
my ($idx,$stim)=lg_autocal_sdr26_limited_coordinates($request->{code},10);
# Preserve the worker's /109 target domain, including its code-based stimulus.
my $step={ire=>$stim,target_stimulus=>$stim};
my $target=lg_autocal_26_sdr26_dpg_compute_target($request->{white},$step,$request->{black}||0,$request->{gamma});
my $reading=$request->{reading};
my ($x,$y)=(0.3127,0.3290);
my $de=delta_e_itp_gamma($reading,$request->{white},$x,$y,$target);
my @gains=lg_autocal_26_sdr26_dpg_gain($reading,$target,$x,$y,$stim);
print encode_json({index=>$idx,target_y=>$target,delta_e=>$de,gains=>\@gains});
