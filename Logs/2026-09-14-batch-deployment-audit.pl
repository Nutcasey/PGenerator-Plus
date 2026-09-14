use strict;
use warnings;
use JSON::PP;
use File::Basename qw(basename);
my $base='/var/lib/PGenerator/automation/runs/20260914-112315-470e19';
sub read_json {
 my ($path)=@_;open my $fh,'<',$path or return {};
 return decode_json(do {local $/;<$fh>});
}
my $run=read_json("$base/run.json");
my @jobs;
for my $n (0..$#{$run->{items}||[]}) {
 my $item=$run->{items}[$n];my $dir="$base/items/$n";
 my $grey=read_json("$dir/calibration/grey-state.json");
 my $volume=read_json("$dir/calibration/3d-state.json");
 my $all=read_json("$dir/apply-all.json");
 my $hist=$grey->{sdr_1d_dpg_anchor_history}||$grey->{hdr20_1d_dpg_anchor_history}||{};
 my @anchors;
 for my $label (keys %$hist) {
  my @de=sort {$a<=>$b} map {0+$_->{de}} grep {defined($_->{de}) && $_->{de}=~/^\d+(?:\.\d+)?$/} @{$hist->{$label}||[]};
  push @anchors,{point=>$label,best_observed_de=>$de[0]} if @de;
 }
 @anchors=sort {$b->{best_observed_de}<=>$a->{best_observed_de}} @anchors;
 splice(@anchors,3) if @anchors>3;
 my @series;
 for my $phase (qw(pre post)) {
  for my $key (@{$item->{"${phase}_series"}||[]}) {
   my $s=read_json("$dir/$phase/$key.json");
   push @series,{phase=>$phase,key=>$key,status=>$s->{status},readings=>scalar @{$s->{readings}||[]}};
  }
 }
 my (%results,@issues,@worker_errors);
 if(open my $fh,'<',"$dir/settings-checks.ndjson") {
  while(my $line=<$fh>) {
   my $c=eval {decode_json($line)};next if ref($c) ne 'HASH';
   $results{$c->{result}||'unknown'}++;
   push @issues,{checkpoint=>$c->{checkpoint},key=>$c->{key},result=>$c->{result},reason=>$c->{reason}}
    if ($c->{result}||'') =~ /(?:mismatch|failed)/;
  }
 }
 for my $kind (qw(grey 3d)) {
  if(open my $fh,'<',"$dir/calibration/$kind-log.txt") {
   while(my $line=<$fh>) {
    next unless $line =~ /(?:FATAL|panic|uncaught|upload FAILED|upload failed after retries|Can't |Use of uninitialized|not confirmed|measurement failed|Illegal division)/i;
    $line=~s/(client[_-]?key|token|password)\s*[=:]\s*\S+/$1=[redacted]/ig;
    push @worker_errors,{worker=>$kind,line=>substr($line,0,400)};
   }
  }
 }
 push @jobs,{job=>$n+1,name=>$item->{name},status=>$item->{status},warnings=>$item->{warnings},failure=>$item->{failure},
  checkpoints=>[map {{name=>$_->{name},status=>$_->{status},verified=>$_->{verified}}} @{$item->{checkpoints}||[]}],
  grey=>{map {$_=>$grey->{$_}} qw(status final_1d_lut_upload_verified ddc_upload_verified calibration_mode calibration_end_ok sdr_1d_dpg_final_de hdr20_1d_dpg_final_de)},
  volume=>{map {$_=>$volume->{$_}} qw(status upload_verified terminal_commit_verified calibration_mode)},
  exports=>{map {$_=>!!($volume->{export}{$_} && -s "$dir/calibration/".basename($volume->{export}{$_}))} qw(cube_path payload_path)},
  apply_all=>{map {$_=>$all->{$_}} qw(status outcome confirmed acknowledged transport readback_error)},
  highest_best_observed_anchors=>\@anchors,series=>\@series,setting_results=>\%results,setting_issues=>\@issues,worker_errors=>\@worker_errors};
}
print JSON::PP->new->canonical->pretty->encode({run=>$run->{id},status=>$run->{status},failure=>$run->{failure},jobs=>\@jobs});
