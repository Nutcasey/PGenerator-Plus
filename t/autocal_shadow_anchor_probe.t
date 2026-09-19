#!/usr/bin/perl
# Drives run_hdr20_postcal_shadow_correction in the 3D worker against a
# simulated panel modelled on the G3 HDR10 jobs of 18 and 19 September
# 2026: the panel samples the bound DPG at true indices well below the
# static zone table, averages the correction over a +-3 index window and
# answers lift = baseline * exp(-k * effective_counts). Covers the zone
# probe bracket refinement, the noise-robust dead-anchor guard and the
# early exit of the pass loop.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

my $worker=$ENV{PGEN_AUTOCAL_3D_WORKER} || "$Bin/../usr/bin/meter_lg_3d_autocal.pl";
do $worker;
die "worker failed to load: $@" if($@);

# --- Simulated panel -----------------------------------------------
my @anchor_ire=(5,10,15,20,25,30);
my %true_idx=(5=>26,10=>45,15=>52,20=>70,25=>95,30=>116);
my %job1_baseline=(5=>1.299,10=>1.518,15=>1.199,20=>1.081,25=>1.063,30=>0.978);
# 54 counts take the 5% anchor from 1.30 to about 0.985.
my $K=log(1.30/0.985)/54;
# Identity DPG: value = index * 32 on each channel block.
my @base=map { ($_ % 1024)*32 } (0..3071);
my $tmp=tempdir(CLEANUP=>1);

my %panel;
sub effective_counts {
 my ($ire)=@_;
 my $t=$true_idx{$ire};
 my $sum=0;
 for my $k ($t-3..$t+3) { $sum+=$base[1024+$k]-$panel{bound}->[1024+$k]; }
 return $sum/7;
}
sub panel_lift {
 my ($ire)=@_;
 my $f=defined($panel{sens}{$ire}) ? $panel{sens}{$ire} : 1;
 return $panel{baseline}{$ire}*exp(-$K*$f*effective_counts($ire));
}

*main::write_state=sub { return 1; };
*main::cancelled=sub { return 0; };
*main::log_line=sub { push @{$panel{log}}, $_[0]; };
*main::hdr20_postcal_save_matrix=sub { return 1; };
*main::reading_xyz=sub { my ($reading)=@_; return [0,$reading->{Y},0]; };
*main::api_json=sub {
 my ($method,$path,$payload)=@_;
 if($path eq "/api/lg/1d-dpg/upload") {
  if(!$payload->{keep_calibration_mode}) {
   $panel{bound}=[ @{$payload->{dpg_data}} ];
   $panel{binds}++;
  }
  return { status=>"ok", cal_start_response=>{type=>"response"}, cal_end_response=>{type=>"response"} };
 }
 return { status=>"ok" };
};
*main::read_step=sub {
 my ($config,$step,$state)=@_;
 my $ire=$step->{ire}+0;
 my $lift=panel_lift($ire);
 my $pass=(($state->{current_name}||"") =~ /pass (\d+)/) ? $1 : 0;
 my $noise=$panel{noise};
 $lift+=$noise->{delta} if($noise && $pass == $noise->{pass} && $ire == $noise->{ire});
 $panel{reads}++;
 my $target=main::hdr20_postcal_target5_for_step($step,$panel{peak});
 return ({ Y=>$lift*$target }, undef);
};

sub run_panel {
 my (%opt)=@_;
 %panel=(
  bound=>[ @base ], binds=>0, reads=>0, log=>[], peak=>800,
  sens=>($opt{sens}||{}), noise=>$opt{noise},
  baseline=>($opt{baseline}||{ %job1_baseline }),
 );
 my $config={
  signal_mode=>"hdr10",
  full_workflow=>1,
  picture_mode=>"cinema",
  lg_autocal_hdr20_postcal_shadow_enable=>1,
  lg_autocal_hdr20_postcal_shadow_matrix_path=>"$tmp/matrix.json",
  postcal_shadow_probe_step=>{ r=>108, g=>108, b=>108, input_max=>1023 },
  pattern_signal_range=>"1",
  full_workflow_dpg_data=>[ @base ],
  full_workflow_peak_luminance=>800,
  postcal_shadow_settle_ms=>100,
  %{$opt{config}||{}},
 };
 my $state={ signal_mode=>"hdr10" };
 my $status=main::run_hdr20_postcal_shadow_correction($config,$state,{});
 return ($status,$state);
}
sub zones_of {
 my ($status)=@_;
 my @z=split(/,/,$status->{zone_probe}||"");
 my %by_ire;
 for(my $i=0;$i<@anchor_ire;$i++) { $by_ire{$anchor_ire[$i]}=$z[$i]; }
 return %by_ire;
}
sub pass_series {
 my ($state,$idx,$ire)=@_;
 my @out;
 for(my $p=1;$p<=6;$p++) {
  my $c=$state->{"postcal_shadow_pass_${p}_counts"};
  last if(ref($c) ne "HASH");
  push @out, sprintf("%d:%.1f->%.3f",$p,$c->{$idx},$state->{"postcal_shadow_pass_${p}_IRE_${ire}_lift"});
 }
 return join(", ",@out);
}

# (1) The ladder alone puts 10% and 15% in one bracket: neither is
# crushed by the shelf ending at 39, both by the shelf ending at 53. The
# old assignment clamped both priors into that bracket, two indices
# apart. The refined probe must separate them by at least 4.
{
 %panel=(bound=>[ @base ], baseline=>{ %job1_baseline }, sens=>{});
 my %crushed;
 for my $x (39,53) {
  my $shelf=main::hdr20_postcal_monotone_clamp(main::hdr20_postcal_prefix_shelf(\@base,$x,300));
  $panel{bound}=$shelf;
  for my $ire (10,15) { $crushed{$x}{$ire}=(panel_lift($ire) < 0.88*$job1_baseline{$ire}) ? 1 : 0; }
 }
 ok(!$crushed{39}{10} && !$crushed{39}{15}, 'ladder shelf at 39 leaves 10% and 15% untouched');
 ok($crushed{53}{10} && $crushed{53}{15}, 'ladder shelf at 53 crushes both 10% and 15% (one shared bracket)');

 my ($status,$state)=run_panel();
 my %z=zones_of($status);
 diag("zones: ".$status->{zone_probe}."; refinement shelves: ".($state->{postcal_shadow_zone_probe_refine}||"none"));
 ok(($state->{postcal_shadow_zone_probe_refine}||"") ne "", 'shared bracket triggered refinement shelves');
 cmp_ok($z{10}-$z{5}, '>=', 4, '10% anchor sits at least 4 indices above 5%');
 cmp_ok($z{15}-$z{10}, '>=', 4, '15% anchor sits at least 4 indices above 10%');
 ok($z{5} < $z{10} && $z{10} < $z{15} && $z{15} < $z{20} && $z{20} < $z{25} && $z{25} < $z{30}, 'zones ascend with IRE');
 ok(abs($z{10}-$true_idx{10}) <= 3, "10% zone $z{10} within 3 of the true index $true_idx{10}");
 ok(abs($z{15}-$true_idx{15}) <= 3, "15% zone $z{15} within 3 of the true index $true_idx{15}");
 ok(scalar(grep { /zone probe: refinement shelf X=/ } @{$panel{log}}), 'refinement shelves are logged');
 ok(scalar(grep { /zone probe: zones .* refinement shelves / } @{$panel{log}}), 'final zones line names the refinement shelves');

 # (2) The loop converges inside the pass budget.
 diag(sprintf("baseline worst %.3f, best worst %.3f after %d passes (%s)",
  $status->{baseline_worst},$status->{best_worst},$status->{passes},$status->{status}));
 diag("10% anchor by pass: ".pass_series($state,$z{10},10));
 diag("15% anchor by pass: ".pass_series($state,$z{15},15));
 is($status->{status}, 'converged', 'simulated G3 panel converges');
 ok($status->{within_tolerance}, 'best pass is within tolerance');
 cmp_ok($status->{best_worst}, '<=', $status->{tolerance}, 'worst anchor error is inside the 5% tolerance');
 cmp_ok($status->{passes}, '<=', 6, 'converged inside the pass budget');
 ok(!grep({ /^postcal_shadow_dead_anchor_/ } keys %{$state}), 'no anchor was declared dead');
}

# (3) One noisy read does not freeze a slow anchor. The 10% anchor
# responds weakly (as on the G3), so a +0.03 read after a 60-count move
# flips its two-point secant; the cumulative slope from pass 1 keeps it
# alive and moving.
{
 my ($status,$state)=run_panel(sens=>{10=>0.09}, noise=>{pass=>3, ire=>10, delta=>0.03});
 my %z=zones_of($status);
 my $idx=$z{10};
 diag("noisy run zones: ".$status->{zone_probe});
 diag("10% anchor by pass: ".pass_series($state,$idx,10));
 my $src3=(ref($state->{postcal_shadow_pass_3_slope_src}) eq "HASH") ? $state->{postcal_shadow_pass_3_slope_src}{$idx} : "";
 is($src3, 'cumulative', 'rejected secant on the noisy pass falls back to the cumulative slope');
 ok(!$state->{"postcal_shadow_dead_anchor_$idx"}, '10% anchor is not declared dead after one noisy read');
 cmp_ok($state->{postcal_shadow_pass_4_counts}{$idx}, '>', $state->{postcal_shadow_pass_3_counts}{$idx}, '10% anchor keeps moving after the noisy pass');
 my $src4=(ref($state->{postcal_shadow_pass_4_slope_src}) eq "HASH") ? $state->{postcal_shadow_pass_4_slope_src}{$idx} : "";
 isnt($src4, 'dead', '10% anchor is still live on the pass after the noise');
}

# (4) Early exit. No anchor responds and only 5/10/15 start lifted, so
# the three lifted anchors are declared dead on pass 3 (parked at their
# best pass, counts 0) and pass 4 changes nothing; the loop stops there
# instead of spending the rest of the budget.
{
 my ($status,$state)=run_panel(
  sens=>{ map { $_=>0 } @anchor_ire },
  baseline=>{ 5=>1.299, 10=>1.518, 15=>1.199, 20=>1.0, 25=>1.0, 30=>1.0 },
 );
 my %z=zones_of($status);
 diag("dead panel zones: ".$status->{zone_probe}."; passes ".$status->{passes}."; status ".$status->{status});
 is($status->{passes}, 4, 'loop stops after the first pass with no count change');
 like($status->{note}, qr/early exit after pass 4/, 'early exit is noted');
 ok(scalar(grep { /no anchor counts changed after pass 4/ } @{$panel{log}}), 'early exit is logged');
 for my $ire (5,10,15) {
  ok($state->{"postcal_shadow_dead_anchor_$z{$ire}"}, "$ire% anchor declared dead after two flat passes");
  is($state->{postcal_shadow_pass_4_counts}{$z{$ire}}+0, 0, "$ire% anchor parked at its best pass (counts 0)");
 }
 is($status->{status}, 'reverted', 'no improvement reverts to the base DPG');
}

done_testing();
