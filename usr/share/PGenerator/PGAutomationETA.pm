package PGAutomationETA;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use PGAutomation ();

our @PROFILE_KEYS=qw(signal_format picture_mode settings panel_light display_type ccss_override observer refresh_rate delay_ms patch_size low_light patch_insert patch_insert_time_enabled patch_insert_time_frequency_ms patch_insert_time_duration_ms patch_insert_time_level patch_insert_patch_enabled patch_insert_patch_every patch_insert_patch_duration_ms patch_insert_patch_level max_bpc signal_range color_format pre_series post_series);
# Estimates never control execution. Only timings from completed, uninterrupted
# stages are reused; unlike patch counts, a saved duration includes uploads and
# TV checks. Separate profiles prevent mixing SDR, HDR, meter or LUT options.
sub profile {
 my ($item,$device)=@_;
 my %profile=map {$_=>$item->{$_}} @PROFILE_KEYS;
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
   push @samples,{profile=>$key,timing_profile=>timing_profile($item,$c->{name}),stage=>$c->{name},seconds=>0+$c->{duration_seconds},
    completed_at=>$c->{completed_at}||0,curve=>$c->{timing_curve},tail_seconds=>$c->{timing_tail_seconds}};
  }
 }
 return \@samples;
}

sub _cached_samples {
 my ($path)=@_;
 my $saved=(-f $path && -s $path<=1048576) ? PGAutomation::read_json_file($path) : undef;
 return ref($saved) eq 'HASH' && ($saved->{version}||0)==1 && ref($saved->{samples}) eq 'ARRAY'
  ? $saved->{samples} : undef;
}

sub history {
 my ($current_id,$tick)=@_;
 my $dir=PGAutomation::base_dir().'/runs';
 opendir(my $dh,$dir) or return [];
 my @ids=sort {$b cmp $a} grep {$_ ne $current_id && PGAutomation::safe_component($_) && -d "$dir/$_"} readdir($dh);
 closedir($dh);
 # Readiness-only attempts must not evict days of useful calibration history.
 splice(@ids,100) if @ids>100;
 my @samples;
 my $legacy_bytes=0;
 for my $id (@ids) {
  last if ref($tick) eq 'CODE' && !$tick->();
  my $cache="$dir/$id/timing.json";
  my $saved=_cached_samples($cache);
  if (defined($saved)) {
   push @samples,@$saved;next;
  }
  # Legacy manifests have no compact index. Bound both an individual parse
  # and total I/O; factory priors cover work beyond this startup budget.
  my $size=-s "$dir/$id/run.json";
  if (defined($size) && $size<=2097152 && $legacy_bytes+$size<=8388608) {
   $legacy_bytes+=$size;
   my $run=PGAutomation::read_json_file("$dir/$id/run.json");
   if (ref($run) eq 'HASH') {push @samples,@{samples($run)};next;}
  }
  # A failed/interrupted cache handover must not discard known timings when
  # the manifest cannot be read. A readable manifest always takes precedence
  # so its newer checkpoints cannot be hidden by this last-resort copy.
  my $previous=_cached_samples("$cache.previous");
  push @samples,@$previous if defined($previous);
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

# Workflow completion is measured work, not an estimate of elapsed time.
# Each planned stage has equal weight; patch/control counts refine only the
# active stage. Unknown-duration operations never advance merely with time.
sub progress {
 my ($run)=@_;
 my $pre=$run->{preflight_result}||{};
 my $pt=$pre->{progress_total}||1;
 my $pd=$pre->{ready} ? $pt : ($pre->{progress_done}||0);
 my ($done,$total)=($pd/$pt,1);
 my $stage=$run->{active_stage}||'';
 my ($stage_done,$stage_total,$unit)=$stage eq 'queue-preflight' ? ($pd,$pt,'checks') : (0,0,'steps');
 my $index=$run->{active_item};
 if (!$run->{preflight_only}) {
  my $items=$run->{items}||[];
  for my $i (0..$#$items) {
   my $item=$items->[$i];my $plan=plan($item);$total+=@$plan;
   my %finished=map {$_->{name}=>1} grep {($_->{status}||'') =~ /^(?:done|skipped)$/} @{$item->{checkpoints}||[]};
   for my $name (@$plan) {
    my $active=defined($index) && $i==$index && $stage eq $name && ($run->{status}||'')!~/^complete/;
    if (!$active && (($item->{status}||'') =~ /^complete/ || $finished{$name})) {$done++;next;}
    next if !$active;
    my $op=$run->{operation_progress}||{};my $w=$run->{worker_status}||{};
    ($stage_done,$stage_total,$unit)=(0,0,'steps');
    if (($op->{stage}||'') eq $stage && $op->{total}) {
     ($stage_done,$stage_total,$unit)=($op->{completed}||0,$op->{total},$op->{unit}||'steps');
    } elsif ($w->{total_steps}) {
     ($stage_done,$stage_total,$unit)=(($w->{current_step}||1)-1,$w->{total_steps},'patches');
     $stage_done=$stage_total if ($w->{status}||'') =~ /^(?:complete|completed|done)$/;
    }
    if ($stage_total>0) {
     $stage_done=0 if $stage_done<0;$stage_done=$stage_total if $stage_done>$stage_total;
     # Finishing a measurement pass still leaves verification/upload work.
     $done+=.95*$stage_done/$stage_total;
    }
   }
  }
 }
 $done=$total if ($run->{status}||'') =~ /^complete/;
 return {completed=>$done,total=>$total,stage_completed=>$stage_done,stage_total=>$stage_total,unit=>$unit};
}

# Timing compatibility is deliberately broader than calibration identity.
# Picture-mode labels, pinned controls and gamma targets must not prevent us
# learning approximate durations from the same signal path and workload.
# Never borrow another signal family's solver/profile or another device/meter.
sub timing_value {
 my ($value)=@_;
 return {map {$_=>timing_value($value->{$_})} keys %$value} if ref($value) eq 'HASH';
 return [map {timing_value($_)} @$value] if ref($value) eq 'ARRAY';
 return defined($value)?"$value":'';
}

sub timing_profile {
 my ($item,$stage,$device)=@_;
 my %p=map {$_=>timing_value($item->{$_})} qw(signal_format display_type ccss_override observer refresh_rate delay_ms patch_size low_light patch_insert patch_insert_time_enabled patch_insert_time_frequency_ms patch_insert_time_duration_ms patch_insert_time_level patch_insert_patch_enabled patch_insert_patch_every patch_insert_patch_duration_ms patch_insert_patch_level max_bpc signal_range color_format);
 $p{device_identity}=$item->{device_identity}||$device;
 $p{stage}=$stage;
 my $cal=$item->{calibration}||{};
 my @keys=$stage eq 'greyscale-done'
  ? qw(target_delta_e delta_e_formula dark_detail max_iterations headroom_max_iterations max_polish_iterations precision_polish_iterations)
  : $stage eq 'volume-done'
  ? qw(target_delta_e delta_e_formula method profile_source lattice_size solve_cube_size shadow_fix lattice_residuals)
  : ();
 # Copy before stringifying: interpolating the manifest's own scalar caches
 # a string form on it, and the appliance's JSON::PP 2.27 then writes the
 # value back as "17" instead of 17, which changed the job's plan hash.
 $p{calibration}={map {my $v=$cal->{$_};$_=>defined($v)?"$v":''} @keys};
 $p{series}=$item->{$stage eq 'pre-readings-done'?'pre_series':'post_series'}||[] if $stage=~/^(?:pre|post)-readings-done$/;
 return sha256_hex(JSON::PP->new->canonical->encode(\%p));
}

# Factory timings are priors for a workload, not measurements of this TV.
# Keep signal, meter mode and algorithm options separate; runtime history
# still requires the stricter device/meter compatibility above.
our $BASELINES;
sub workload {
 my ($item,$stage,$shape_only)=@_;
 my $cal=$item->{calibration}||{};
 my %p=map {$_=>timing_value($item->{$_})} qw(signal_format display_type);
 $p{stage}=$stage;
 my @keys=$stage eq 'greyscale-done' ? qw(target_delta_e delta_e_formula dark_detail max_iterations headroom_max_iterations max_polish_iterations precision_polish_iterations)
  : $stage eq 'volume-done' ? qw(method profile_source lattice_size solve_cube_size shadow_fix lattice_residuals) : ();
 for my $key (@keys) {
  next if $shape_only && $key eq 'target_delta_e';
  my $v=$cal->{$key};
  $p{$key}=$key=~/^(?:dark_detail|shadow_fix|lattice_residuals)$/ ? ($v?'1':'0') : timing_value($v);
 }
 $p{panel_policy}=($item->{panel_light}||{})->{policy}||'fixed' if $stage eq 'panel-light-settled';
 $p{series}=$item->{$stage eq 'pre-readings-done'?'pre_series':'post_series'}||[] if $stage=~/^(?:pre|post)-readings-done$/;
 return JSON::PP->new->canonical->encode(\%p);
}

sub duration_model {
 my ($samples)=@_;
 my @dated=sort {$b->{completed_at}<=>$a->{completed_at}} grep {$_->{completed_at}} @$samples;
 my @undated=grep {!$_->{completed_at}} @$samples;
 # Bound both groups without pretending that an unknown legacy date is old.
 # Weekly gaps do not expire dated measurements or exclude undated evidence.
 splice(@dated,3) if @dated>3;
 splice(@undated,3) if @undated>3;
 my @s=(@dated,@undated);
 return undef if !@s;
 my @seconds=sort {$a<=>$b} map {$_->{seconds}} @s;
 my $middle=median(@seconds);
 my $model={seconds=>$middle,low=>$seconds[0]*.75,high=>$seconds[-1]*1.5,latest_at=>$s[0]{completed_at}||0};
 my @tails=grep {defined($_) && $_>0} map {$_->{tail_seconds}} @s;
 $model->{tail_seconds}=median(@tails) if @tails;
 my @curves=grep {ref($_) eq 'HASH' && ref($_->{fractions}) eq 'ARRAY' && @{$_->{fractions}}==($_->{total_steps}||0)+1} map {$_->{curve}} @s;
 if (@curves) {
  $model->{curve}=$curves[0];
 }
 return $model;
}

sub history_index {
 my ($samples)=@_;
 my (%exact,%compatible);
 for my $sample (@$samples) {
  push @{$exact{$sample->{profile}}{$sample->{stage}}},$sample;
  push @{$compatible{$sample->{timing_profile}}},$sample if $sample->{timing_profile};
 }
 return {exact=>{map {my $key=$_;$key=>{map {$_=>duration_model($exact{$key}{$_})} keys %{$exact{$key}}}} keys %exact},
  compatible=>{map {$_=>duration_model($compatible{$_})} keys %compatible}};
}

sub baseline {
 my ($item,$stage,$shape_only)=@_;
 $BASELINES=PGAutomation::read_json_file(dirname(__FILE__).'/automation-timing.json')||{} if !defined($BASELINES);
 my $key=workload($item,$stage,$shape_only);
 if (!exists($BASELINES->{index})) {
  my %groups;
  for my $record (@{$BASELINES->{records}||[]}) {
   for my $name (keys %{$record->{stages}||{}}) {
    for my $shape (0,1) {push @{$groups{$shape}{workload($record->{job},$name,$shape)}},$record->{stages}{$name};}
   }
  }
  $BASELINES->{index}={map {my $shape=$_;$shape=>{map {$_=>duration_model($groups{$shape}{$_})} keys %{$groups{$shape}}}} keys %groups};
 }
 return $BASELINES->{index}{$shape_only?1:0}{$key};
}

sub remaining_from_history {
 my ($total,$elapsed)=@_;
 my $remaining=$total-$elapsed;
 # An overdue operation is still work. Keep an explicit residual instead of
 # dropping its estimate, or counting down forever to a fictitious one minute.
 my $residual=$total*.15;
 $residual=60 if $residual<60;
 $residual=($elapsed-$total)*.5 if ($elapsed-$total)*.5>$residual;
 return $remaining>$residual ? $remaining : $residual;
}

# A private in-memory projection lets live ticks recalculate without reading
# or serialising the manifest's measurements and capability evidence.
sub context {
 my ($run,$history)=@_;
 my $copy=PGAutomation::compact_run($run);
 $copy->{worker_timing}=$run->{worker_timing};
 for my $i (0..$#{$run->{items}||[]}) {
  my $item=$run->{items}[$i];
  @{$copy->{items}[$i]}{@PROFILE_KEYS,qw(calibration device_identity)}=@$item{@PROFILE_KEYS,qw(calibration device_identity)};
  $copy->{items}[$i]{checkpoints}=[map {my $c=$_;+{map {$_=>$c->{$_}} qw(name status duration_seconds completed_at timing_interrupted timing_curve timing_tail_seconds)}} @{$item->{checkpoints}||[]}];
 }
 $copy->{eta_history_index}=history_index([@{$history||[]},@{samples($copy)}]);
 return $copy;
}

sub update {
 my ($run,$now,$history)=@_;
 my $preflight=($run->{active_stage}||'') eq 'queue-preflight';
 my $index=$preflight ? 0 : $run->{active_item};
 my $stage=$run->{active_stage}||'';
 my $worker=$run->{worker_status}||{};
 my $worker_finished=($worker->{status}||'') =~ /^(?:complete(?:-with-warnings)?|completed|done|failed|error|stopped|interrupted)$/;
 my $clock=$run->{worker_timing}||{};
 my $items=$run->{items}||[];
 # Recalculate immediately after queue edits, stage/pass changes or a resume.
 my $identity=JSON::PP->new->canonical->encode([$index,$stage,$run->{stage_started_at},$run->{resumed_at},$worker->{status},$worker->{current_step},$worker->{total_steps},$clock,($run->{preflight_result}||{})->{progress_done},
  [map {[profile($_),$_->{stages},$_->{status},$_->{checkpoint}]} @$items]]);
 my $old=$run->{time_estimate}||{};
 if (($run->{status}||'') ne 'running' || !defined($index) || $index!~/^\d+$/ || $index>=@$items) {
  delete $run->{time_estimate};return;
 }
 return if ($old->{identity}||'') eq $identity && $now-($old->{calculated_at}||0)<15;
 my $result={identity=>$identity,calculated_at=>$now,active_item=>0+$index,stage=>$stage,scope=>'unknown'};
 my $indexed=$run->{eta_history_index}||history_index([@{$history||[]},@{samples($run)}]);
 my $item=$items->[$index];
 my $approximate=0;
 my $seeded=0;
 my $live_stage_total;
 my %models;
 my $duration_for=sub {
  my ($job,$next)=@_;
  my $key=profile($job,$item->{device_identity}).':'.$next;
  if (exists($models{$key})) {return $models{$key}{seconds};}
  my $model=$indexed->{exact}{profile($job,$item->{device_identity})}{$next};
  if (!$model) {
   $model=$indexed->{compatible}{timing_profile($job,$next,$item->{device_identity})};
   $approximate=1 if $model;
  }
  $model={%$model} if $model;
  my $prior=baseline($job,$next);
  if ($prior && !$model) {$model={%$prior};$seeded=1;}
  $model->{curve}=$prior->{curve} if $model && !$model->{curve} && $prior && $prior->{curve};
  $model->{tail_seconds}=$prior->{tail_seconds} if $model && !defined($model->{tail_seconds}) && $prior && defined($prior->{tail_seconds});
  if (!$model && defined($live_stage_total) && $next eq $stage
      && timing_profile($job,$next,$item->{device_identity}) eq timing_profile($item,$stage)) {
   $model={seconds=>$live_stage_total,low=>$live_stage_total*.75,high=>$live_stage_total*1.5};$approximate=1;
  }
  $models{$key}=$model if $model;
  return $model ? $model->{seconds} : undef;
 };
 my $same=$duration_for->($item,$stage);
 my $current_model=$models{profile($item,$item->{device_identity}).':'.$stage};
 my $current;
 my $pass;
 if ($preflight) {
  my $p=$run->{preflight_result}||{};
  my $elapsed=$now-($p->{started_at}||$now);
  my $done=$p->{progress_done}||0;my $total=$p->{progress_total}||0;
  $current=$elapsed/$done*($total-$done) if $elapsed>=30 && $done>=2 && $total>$done;
 }
 # Iterative calibration is non-linear: this is deliberately a rough estimate
 # based on completed points, never a promise that each iteration costs alike.
 my $total=$worker->{total_steps}||0;
 my $done=($worker->{current_step}||0)-1;
 my $completed=$done-($clock->{start_step}||0);
 my $elapsed=$now-($clock->{started_at}||$now);
 my $valid_clock=($clock->{stage}||'') eq $stage
     && ($clock->{started_at}||0)>=($run->{stage_started_at}||0) && ($clock->{started_at}||0)>=($run->{resumed_at}||0);
 if (($clock->{kind}||'') =~ /^(?:grey|series|3d|dv)$/ && ($clock->{stage}||'') eq $stage
     && ($clock->{started_at}||0)>=($run->{stage_started_at}||0) && ($clock->{started_at}||0)>=($run->{resumed_at}||0)
     && !(($clock->{kind}||'') eq '3d' && ($worker->{phase}||'') ne '' && ($worker->{phase}||'')!~/^(?:profile|drift_anchor)$/)
     && ($worker->{status}||'') eq 'running' && $elapsed>=120 && $completed>=3 && $done<$total) {
  my $pace=$elapsed/$completed;
  my @recent=grep {defined($_) && !ref($_) && /^\d+(?:\.\d+)?$/ && $_>0} @{$clock->{recent_point_seconds}||[]};
  # Near-black points include more samples/iterations. Do not project the
  # bright-point average across them once a slower recent pace is observed.
  my $recent=@recent>=3 ? median(@recent) : undef;
  $pace=$recent if defined($recent) && $recent>$pace;
  $pass=$pace*($total-$done);
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
   $current=$pass+$extra*$pace if $found && !$unknown;
  }
  # Profiling still has solve/upload work after its last measured patch.
  if ($stage eq 'volume-done' && defined($same)) {
   my $tail=$current_model && defined($current_model->{tail_seconds}) ? $current_model->{tail_seconds} : $same*.08;
   $tail=60 if $tail<60;
   $current=$pass+$tail;
   $result->{adaptive}=JSON::PP::true;
  }
 }
 if ($stage eq 'volume-done' && $valid_clock && ($worker->{status}||'') eq 'running'
     && $clock->{tail_started_at} && $current_model && $current_model->{tail_seconds}) {
  $current=remaining_from_history($current_model->{tail_seconds},$now-$clock->{tail_started_at});
 }
 my $curve=$current_model ? $current_model->{curve} : undef;
 if (!$curve && $stage eq 'greyscale-done' && $valid_clock && ($worker->{status}||'') eq 'running' && $completed>=3 && $elapsed>=120) {
  # A new accuracy target has no measured duration yet. Its identical point
  # order can still supply weights; only this run supplies the elapsed pace.
  my $shape=baseline($item,$stage,1);
  $curve=$shape->{curve} if $shape;
  if ($curve && $total==$curve->{total_steps} && $done>0 && $done<$total && $curve->{fractions}[$done]>0 && !defined($same)) {
   my $completed_elapsed=defined($clock->{point_started_at}) ? $clock->{point_started_at}-$clock->{started_at} : $elapsed;
   if ($completed_elapsed>0) {$same=$completed_elapsed/$curve->{fractions}[$done];$approximate=1;}
  }
 }
 if ($stage eq 'greyscale-done' && $valid_clock && defined($same) && $same>0 && ($worker->{status}||'') eq 'running'
     && $curve && $total==$curve->{total_steps} && $done>=0 && $done<$total && !($clock->{start_step}||0)) {
  # Completed points consume very unequal shares of the job. Compare this
  # run against the same point in the saved trajectory, leaving the slow
  # shadow points and final commit in the remaining budget.
  my $fraction=$curve->{fractions}[$done];
  my $point_age=defined($clock->{point_started_at}) ? $now-$clock->{point_started_at} : 0;
  $point_age=0 if $point_age<0;
  my $observed=$elapsed-$point_age;
  my $weight=$done/($done+5);
  my $scale=$fraction>0 && $observed>0 ? 1-$weight+$weight*$observed/($same*$fraction) : 1;
  my $remaining=$same*(1-$fraction)*$scale-$point_age;
  my $point_budget=$same*($curve->{fractions}[$done+1]-$fraction)*$scale;
  my $floor=$point_budget*.5;$floor=60 if $floor<60;
  if ($point_age>$point_budget && $point_age-$point_budget>$floor) {$floor=$point_age-$point_budget;}
  $current=$remaining>$floor ? $remaining : $floor;
  $pass=$current;
  $result->{adaptive}=JSON::PP::true if $done>0;
 }
 if (!defined($current) && defined($same) && $same>0
     && !($worker_finished && $valid_clock && $stage =~ /^(?:greyscale|volume|pre-readings|post-readings)-done$/)) {
  $current=remaining_from_history($same,$now-($run->{stage_started_at}||$now));
 }
 $live_stage_total=$current+($now-($run->{stage_started_at}||$now)) if defined($pass) && defined($current);
 my ($batch,$unknown,$job_remaining,$job_unknown,$remaining_stages,$known_stages)=(0,0,0,0,0,0);
 if ($preflight) {
  $remaining_stages++;
  if (defined($current)) {$batch+=$current;$known_stages++;} else {$unknown++;}
 }
 my @jobs;
 my ($batch_low,$batch_high,$job_low,$job_high)=(0,0,0,0);
 my $bounds=sub {
  my ($seconds,$model)=@_;
  return ($seconds*.75,$seconds*1.5) if !$model || !$model->{seconds};
  return ($seconds*$model->{low}/$model->{seconds},$seconds*$model->{high}/$model->{seconds});
 };
 ($batch_low,$batch_high)=$bounds->($current,$current_model) if $preflight && defined($current);
 for my $i ($run->{preflight_only} ? () : ($index..$#$items)) {
  my $job=$items->[$i];next if ($job->{status}||'') =~ /^complete/;
  my %done=map {($_->{name}=>1)} grep {($_->{status}||'') =~ /^(?:done|skipped)$/} @{$job->{checkpoints}||[]};
  my ($job_seconds,$missing,$known)=(0,0,0);
  for my $next (@{plan($job)}) {
   # An active stage may be repeating a checkpoint during recovery.
   next if $done{$next} && !($i==$index && $next eq $stage);
   my $duration=$i==$index && $next eq $stage ? $current : $duration_for->($job,$next);
   my $model=$models{profile($job,$item->{device_identity}).':'.$next};
   if ($i>$index && $next eq $stage && $result->{adaptive} && defined($duration) && defined($live_stage_total) && defined($same) && $same>0
       && timing_profile($job,$next,$item->{device_identity}) eq timing_profile($item,$stage)) {
    my $scale=$live_stage_total/$same;
    $duration*=$scale;
    $approximate=1;
   }
   $remaining_stages++;
   if (defined($duration)) {
    $batch+=$duration;$job_seconds+=$duration;$known++;$known_stages++;
    my ($low,$high)=$bounds->($duration,$model);
    $batch_low+=$low;$batch_high+=$high;
    if ($i==$index) {$job_low+=$low;$job_high+=$high;}
   } else {$unknown++;$missing++;}
  }
  ($job_remaining,$job_unknown)=($job_seconds,$missing) if $i==$index;
  push @jobs,{item=>0+$i,remaining_seconds=>int($job_seconds),unknown_stages=>$missing,known_stages=>$known};
 }
 # A profile pass has a measurable duration even before solve/upload history
 # exists. Include that known work without claiming the entire stage is timed.
 if (defined($pass) && !defined($current) && $pass>0) {
  $batch+=$pass;$job_remaining+=$pass;
  $batch_low+=$pass*.75;$job_low+=$pass*.75;$batch_high+=$pass*1.5;$job_high+=$pass*1.5;
 }
 $result->{ranges}={job=>{low=>int($job_low),high=>int($job_high)},batch=>{low=>int($batch_low),high=>int($batch_high)}};
 if (defined($current)) {my ($low,$high)=$bounds->($current,$current_model);$result->{ranges}{stage}={low=>int($low),high=>int($high)};}
 $result->{ranges}{pass}={low=>int($pass*.75),high=>int($pass*1.5)} if defined($pass);
 $result->{seeded_history}=$seeded?JSON::PP::true:JSON::PP::false;
 $result->{jobs}=\@jobs;
 $result->{job_remaining_seconds}=int($job_remaining) if $job_remaining>0;
 $result->{job_unknown_stages}=$job_unknown;
 $result->{batch_known_seconds}=int($batch) if $batch>0;
 $result->{batch_unknown_stages}=$unknown;
 $result->{known_stages}=$known_stages;
 $result->{remaining_stages}=$remaining_stages;
 $result->{approximate_history}=$approximate?JSON::PP::true:JSON::PP::false;
 $result->{pass_remaining_seconds}=int($pass) if defined($pass) && $pass>0;
 $result->{stage_remaining_seconds}=int($current) if defined($current) && $current>0;
 if (!$unknown && $batch>0 && defined($current)) {$result->{scope}='batch';$result->{remaining_seconds}=int($batch);}
 elsif (defined($current) && $current>0) {$result->{scope}='stage';$result->{remaining_seconds}=int($current);}
 elsif (defined($pass) && $pass>0) {$result->{scope}='pass';$result->{remaining_seconds}=int($pass);}
 $run->{time_estimate}=$result;
}
1;
