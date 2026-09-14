package PGAutomationETA;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use PGAutomation ();

# Estimates never control execution. Only timings from completed, uninterrupted
# stages are reused; unlike patch counts, a saved duration includes uploads and
# TV checks. Separate profiles prevent mixing SDR, HDR, meter or LUT options.
sub profile {
 my ($item,$device)=@_;
 my %profile=map {$_=>$item->{$_}} qw(signal_format picture_mode settings panel_light display_type ccss_override observer refresh_rate delay_ms patch_size low_light patch_insert patch_insert_time_enabled patch_insert_time_frequency_ms patch_insert_time_duration_ms patch_insert_time_level patch_insert_patch_enabled patch_insert_patch_every patch_insert_patch_duration_ms patch_insert_patch_level max_bpc signal_range color_format pre_series post_series);
 $profile{device_identity}=$item->{device_identity}||$device;
 my $cal=$item->{calibration}||{};
 $profile{calibration}={map {$_=>$cal->{$_}} qw(target_gamma target_gamut target_white target_delta_e delta_e_formula method profile_source lattice_size solve_cube_size dark_detail shadow_fix lattice_residuals max_iterations headroom_max_iterations max_polish_iterations precision_polish_iterations)};
 return sha256_hex(JSON::PP->new->canonical->encode(\%profile));
}

sub samples {
 my ($run)=@_;
 my @samples;
 for my $item (@{$run->{items}||[]}) {
  my $key=profile($item);
  for my $c (@{$item->{checkpoints}||[]}) {
   next unless ($c->{status}||'') eq 'done' && defined($c->{duration_seconds})
    && $c->{duration_seconds}>0 && $c->{duration_seconds}<86400 && !$c->{timing_interrupted};
   push @samples,{profile=>$key,stage=>$c->{name},seconds=>0+$c->{duration_seconds}};
  }
 }
 return \@samples;
}

sub history {
 my ($current_id)=@_;
 my $dir=PGAutomation::base_dir().'/runs';
 opendir(my $dh,$dir) or return [];
 my @ids=sort {$b cmp $a} grep {$_ ne $current_id && PGAutomation::safe_component($_) && -d "$dir/$_"} readdir($dh);
 closedir($dh);
 splice(@ids,20) if @ids>20;
 my @samples;
 for my $id (@ids) {
  my $run=PGAutomation::read_json_file("$dir/$id/run.json");
  next unless ref($run) eq 'HASH';
  push @samples,@{samples($run)};
 }
 return \@samples;
}

sub plan {
 my ($item)=@_;
 my $s=$item->{stages}||{};
 my @stages=('item-started','tv-setup-verified');
 push @stages,'pre-readings-done' if $s->{pre_readings};
 if (!defined($s->{calibration}) || $s->{calibration}) {
  push @stages,qw(reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed);
  push @stages,'apply-all-done' if !defined($s->{apply_all}) || $s->{apply_all};
 }
 push @stages,'post-readings-done' if $s->{post_readings};
 return \@stages;
}

sub median {
 my @values=sort {$a<=>$b} @_;
 return undef if !@values;
 my $middle=int(@values/2);
 return @values%2 ? $values[$middle] : ($values[$middle-1]+$values[$middle])/2;
}

sub update {
 my ($run,$now,$history)=@_;
 my $index=$run->{active_item};
 my $stage=$run->{active_stage}||'';
 my $worker=$run->{worker_status}||{};
 my $clock=$run->{worker_timing}||{};
 my $items=$run->{items}||[];
 # Recalculate immediately after queue edits, stage/pass changes or a resume.
 my $identity=JSON::PP->new->canonical->encode([$index,$stage,$run->{stage_started_at},$run->{resumed_at},$worker->{status},$clock,
  [map {[profile($_),$_->{stages},$_->{status},$_->{checkpoint}]} @$items]]);
 my $old=$run->{time_estimate}||{};
 if (($run->{status}||'') ne 'running' || !defined($index) || $index!~/^\d+$/ || $index>=@$items) {
  delete $run->{time_estimate};return;
 }
 return if ($old->{identity}||'') eq $identity && $now-($old->{calculated_at}||0)<120;
 my $result={identity=>$identity,calculated_at=>$now,active_item=>0+$index,stage=>$stage,scope=>'unknown'};
 my %durations;
 for my $sample (@{$history||[]},@{samples($run)}) {
  push @{$durations{$sample->{profile}}{$sample->{stage}}},$sample->{seconds};
 }
 my $item=$items->[$index];
 my $current;
 my $pass;
 # Iterative calibration is non-linear: this is deliberately a rough estimate
 # based on completed points, never a promise that each iteration costs alike.
 my $total=$worker->{total_steps}||0;
 my $done=($worker->{current_step}||0)-1;
 my $completed=$done-($clock->{start_step}||0);
 my $elapsed=$now-($clock->{started_at}||$now);
 if (($clock->{kind}||'') =~ /^(?:grey|series)$/ && ($clock->{stage}||'') eq $stage
     && ($clock->{started_at}||0)>=($run->{stage_started_at}||0) && ($clock->{started_at}||0)>=($run->{resumed_at}||0)
     && ($worker->{status}||'') eq 'running' && $elapsed>=120 && $completed>=3 && $done<$total) {
  $pass=$elapsed/$completed*($total-$done);
  if ($stage eq 'greyscale-done') {$current=$pass;}
  elsif ($stage =~ /^(?:pre|post)-readings-done$/) {
   my $series=$item->{($stage eq 'pre-readings-done'?'pre':'post').'_series'}||[];
   # Saturation adds a white reference to the 24 colour patches.
   my %count=('greyscale-21'=>21,'colors-30'=>30,'saturations-24'=>25);
   my ($found,$extra,$unknown)=(0,0,0);
   for my $key (@$series) {
    if ($found) {defined($count{$key}) ? ($extra+=$count{$key}) : ($unknown=1);}
    $found=1 if $key eq ($clock->{series_key}||'');
   }
   $current=$pass+$extra*$elapsed/$completed if $found && !$unknown;
  }
 }
 my $same=median(@{$durations{profile($item)}{$stage}||[]});
 if (!defined($current) && defined($same)) {
  my $remaining=$same-($now-($run->{stage_started_at}||$now));
  $current=$remaining if $remaining>60;
 }
 my ($batch,$unknown)=(0,0);
 for my $i ($index..$#$items) {
  my $job=$items->[$i];next if ($job->{status}||'') =~ /^complete/;
  my %done=map {($_->{name}=>1)} grep {($_->{status}||'') =~ /^(?:done|skipped)$/} @{$job->{checkpoints}||[]};
  my $key=profile($job,$item->{device_identity});
  for my $next (@{plan($job)}) {
   # An active stage may be repeating a checkpoint during recovery.
   next if $done{$next} && !($i==$index && $next eq $stage);
   my $duration=$i==$index && $next eq $stage ? $current : median(@{$durations{$key}{$next}||[]});
   if (defined($duration)) {$batch+=$duration;} else {$unknown++;}
  }
 }
 if (!$unknown && $batch>0 && defined($current)) {$result->{scope}='batch';$result->{remaining_seconds}=int($batch);}
 elsif (defined($current) && $current>0) {$result->{scope}='stage';$result->{remaining_seconds}=int($current);}
 elsif (defined($pass) && $pass>0) {$result->{scope}='pass';$result->{remaining_seconds}=int($pass);}
 $run->{time_estimate}=$result;
}
1;
