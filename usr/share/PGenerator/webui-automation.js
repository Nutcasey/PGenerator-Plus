var pgAutomation = {
 loaded:false,recipes:[],queues:[],queue:{name:'TV calibration queue',items:[]},
 current:null,currentHistoryRunId:'',history:[],liveTimer:null,reportBusy:false,
 supportedKeys:[],supportedValues:{},pinnedKeys:[],supportedSignal:'',supportedPictureMode:'',
 editorTarget:'queue',editingQueueIndex:null,editingRecipe:null,editorEpoch:0,
 editingRunId:'',firstPending:0,busy:false,polling:false,tab:'queue'
};
const PG_AUTOMATION_SERIES=[['Grey','greyscale-21','Greyscale'],['Colors','colors-30','ColorChecker'],['Sats','saturations-24','Saturation']];
function pgAutomationEscape(value){return String(value==null?'':value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));}
function pgAutomationClone(value){return value==null?value:JSON.parse(JSON.stringify(value));}
function pgAutomationEl(id){return document.getElementById('pgAutomation'+id);}
function pgAutomationValue(id,fallback){const el=pgAutomationEl(id);return el&&el.value!==''?el.value:fallback;}
function pgAutomationChecked(id){return !!(pgAutomationEl(id)&&pgAutomationEl(id).checked);}
function pgAutomationNotice(message,error){
 const el=pgAutomationEl('Notice');if(!el)return;
 el.textContent=message||'';el.style.display=message?'block':'none';el.style.color=error?'var(--red)':'var(--text2)';
 if(pgAutomationEl('Editor').open)pgAutomationEl('EditorError').textContent=error?(message||''):'';
}
async function pgAutomationRequest(path,body,timeout){
 const opts={_quiet:true,_timeoutMs:timeout||30000};
 if(body!==undefined){opts.method='POST';opts.headers={'Content-Type':'application/json'};opts.body=JSON.stringify(body);}
 const result=await fetchJSON('/api/automation/'+path,opts);
 if(!result)throw new Error('The generator did not respond. Refresh to check its state before retrying.');
 if(result.status==='error')throw new Error(result.message||'Automation request failed');
 return result;
}
function pgAutomationSnapshot(source){
 const item=pgAutomationClone(source)||{};
 ['item_number','status','checkpoints','checkpoint','checkpoint_status','active_stage','stage_started_at','failure','warnings','recheck','hazards','hazard_capabilities','hazard_restore','device_identity','fault_injected','drift_recovery_attempts','drift_recovery_pending','series','apply-all','panel-light'].forEach(key=>delete item[key]);
 return item;
}
function pgAutomationSaveDraft(){
 try{localStorage.setItem('pgen.automation.queueDraft',JSON.stringify({queue:pgAutomation.queue,editingRunId:pgAutomation.editingRunId,firstPending:pgAutomation.firstPending}));}catch(e){}
 const ready=pgAutomationEl('Readiness');if(ready)ready.innerHTML='';
}
function pgAutomationModes(signal){
 if(typeof lgPictureModesForSignal==='function')return lgPictureModesForSignal(signal).map(mode=>typeof mode==='string'?mode:Array.isArray(mode)?mode[0]:(mode.value||mode.id));
 return signal==='dv'?['dolbyVisionCinemaBright','dolbyVisionFilmMaker']:signal==='sdr'?['cinema','filmMaker','expert1','expert2']:['hdrCinema','hdrFilmMaker'];
}
function pgAutomationModeLabel(mode,signal){
 if(typeof lgPictureModesForSignal==='function'){
  const found=lgPictureModesForSignal(signal).find(x=>x[0]===mode||x.value===mode||x.id===mode);
  if(found)return found.label||found[1]||mode;
 }
 return mode||'Choose a picture mode';
}
function pgAutomationModesChanged(){
 const signal=pgAutomationValue('Signal','sdr'),select=pgAutomationEl('PictureMode'),prior=select.value;
 const modes=pgAutomationModes(signal).filter(Boolean);
 select.innerHTML=modes.map(mode=>'<option value="'+pgAutomationEscape(mode)+'">'+pgAutomationEscape(pgAutomationModeLabel(mode,signal))+'</option>').join('');
 if(modes.includes(prior))select.value=prior;
 else select.value=modes.find(mode=>/filmmaker/i.test(mode))||modes[0]||'';
 pgAutomationModeChanged();
}
function pgAutomationModeChanged(){
 if(pgAutomation.supportedSignal!==pgAutomationValue('Signal','sdr')||pgAutomation.supportedPictureMode!==pgAutomationValue('PictureMode','')){
  pgAutomation.supportedKeys=[];pgAutomation.supportedSignal='';pgAutomation.supportedPictureMode='';
  pgAutomationRenderSettingsEditor();
 }
}
function pgAutomationSignalDefaults(){
 const signal=pgAutomationValue('Signal','sdr');
 pgAutomationEl('Gamma').value=signal==='sdr'?'bt1886':signal==='hlg'?'hlg':'st2084';
 pgAutomationEl('Gamut').value=signal==='sdr'?'bt709':signal==='dv'?'p3d65':'bt2020';
 pgAutomationEl('PanelValue').value=signal==='sdr'?80:100;
 if(signal!=='sdr')pgAutomationEl('PanelPolicy').value='fixed';
 if(signal==='hdr10')pgAutomationEl('Method').value='matrix';
 pgAutomationUpdateEditor();
}
function pgAutomationSettingMetadata(key){
 if(typeof LG_DISPLAY_CONTROL_ITEMS!=='undefined')return LG_DISPLAY_CONTROL_ITEMS.find(item=>item.key===key)||{key,label:key,type:'text'};
 return {key,label:key,type:'text'};
}
function pgAutomationSettingCandidates(){
 return typeof LG_DISPLAY_CONTROL_KEYS!=='undefined'?LG_DISPLAY_CONTROL_KEYS.slice():['brightness','contrast','backlight','oledLight','oledPixelBrightness','energySaving'];
}
function pgAutomationSettingValue(value){return value==null?'':typeof value==='object'?JSON.stringify(value):String(value);}
function pgAutomationRenderSettingsEditor(){
 const editor=pgAutomationEl('SettingsEditor'),status=pgAutomationEl('SettingsStatus');
 const pinned=pgAutomation.pinnedKeys||[];
 const checked=pgAutomation.supportedKeys.length>0;
 const keys=Array.from(new Set([...(checked?pgAutomation.supportedKeys:pgAutomationSettingCandidates()),...pinned]));
  editor.innerHTML=keys.filter(key=>!['backlight','oledLight','oledPixelBrightness'].includes(key)).map(key=>{
   const meta=pgAutomationSettingMetadata(key),value=pgAutomationSettingValue(pgAutomation.supportedValues[key]),pin=pinned.includes(key);
   let input;
   const attrs=' data-pg-automation-key="'+pgAutomationEscape(key)+'"'+(pin?'':' disabled');
   if(meta.type==='select'&&Array.isArray(meta.options)){
    const options=meta.options.slice();if(value&&!options.includes(value))options.unshift(value);
    input='<select'+attrs+'>'+options.map(option=>'<option value="'+pgAutomationEscape(option)+'"'+(String(option)===value?' selected':'')+'>'+pgAutomationEscape(option)+'</option>').join('')+'</select>';
   }else{
    input='<input'+attrs+' type="'+(meta.type==='number'?'number':'text')+'"'+(meta.min!=null?' min="'+meta.min+'"':'')+(meta.max!=null?' max="'+meta.max+'"':'')+' value="'+pgAutomationEscape(value)+'">';
   }
   return '<div class="field"><label><input type="checkbox" data-pg-automation-pin="'+pgAutomationEscape(key)+'"'+(pin?' checked':'')+' onchange="pgAutomationTogglePin(this)"> '+pgAutomationEscape(meta.label||key)+'</label>'+input+'</div>';
  }).join('');
  status.textContent=checked?pgAutomation.supportedKeys.length+' supported controls · checked for '+pgAutomationModeLabel(pgAutomation.supportedPictureMode,pgAutomation.supportedSignal):'Offline preparation: support will be checked before starting. Only ticked controls are pinned.';
 pgAutomationRenderPanelKeyOptions();
}
function pgAutomationTogglePin(el){
 const key=el.getAttribute('data-pg-automation-pin');
 pgAutomation.pinnedKeys=pgAutomation.pinnedKeys.filter(x=>x!==key);
 if(el.checked)pgAutomation.pinnedKeys.push(key);
 const input=Array.from(document.querySelectorAll('[data-pg-automation-key]')).find(x=>x.getAttribute('data-pg-automation-key')===key);
 if(input)input.disabled=!el.checked;
}
function pgAutomationRenderPanelKeyOptions(){
 const select=pgAutomationEl('PanelKey'),prior=select.value||pgAutomation.editingRecipe?.panel_light?.key||'';
 const keys=(pgAutomation.supportedKeys.length?pgAutomation.supportedKeys:['backlight','oledLight','oledPixelBrightness']).filter(key=>['backlight','oledLight','oledPixelBrightness'].includes(key));
 if(!keys.length&&prior)keys.push(prior);
 select.innerHTML='<option value="">Do not pin panel light</option>'+keys.map(key=>'<option value="'+key+'">'+pgAutomationEscape(pgAutomationSettingMetadata(key).label)+'</option>').join('');
 select.value=keys.includes(prior)?prior:'';
}
function pgAutomationReadSettingsEditor(){
 const values={};
 pgAutomation.pinnedKeys.forEach(key=>{if(pgAutomation.supportedValues[key]!=null)values[key]=pgAutomation.supportedValues[key];});
 document.querySelectorAll('[data-pg-automation-key]').forEach(input=>{
  const key=input.getAttribute('data-pg-automation-key');
  if(!pgAutomation.pinnedKeys.includes(key)){delete values[key];return;}
  if(input.value==='')throw new Error('Enter a value for '+key+' or unpin it.');
  const meta=pgAutomationSettingMetadata(key);
  if(meta.type==='number'&&(!Number.isFinite(Number(input.value))||Number(input.value)<meta.min||Number(input.value)>meta.max))throw new Error(meta.label+' must be between '+meta.min+' and '+meta.max+'.');
  values[key]=meta.type==='number'?Number(input.value):input.value;
 });
 return values;
}
async function pgAutomationLoadSupportedKeys(){
 const signal=pgAutomationValue('Signal','sdr'),pictureMode=pgAutomationValue('PictureMode',''),epoch=pgAutomation.editorEpoch;
 const button=pgAutomationEl('KeysButton');button.disabled=true;button.textContent='Reading controls…';
 try{
  const prior=pgAutomationReadSettingsEditor();
  const result=await fetchJSON('/api/lg/picture-settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({keys:pgAutomationSettingCandidates(),picture_mode:pictureMode,signal_mode:signal,category:'picture'}),_quiet:true,_timeoutMs:60000});
  if(epoch!==pgAutomation.editorEpoch||signal!==pgAutomationValue('Signal','sdr')||pictureMode!==pgAutomationValue('PictureMode',''))return;
  if(!result||result.status==='error')throw new Error(result?.message||'Could not read TV controls. Check the TV connection.');
  const current=result.picture_settings||result.settings||{};
  pgAutomation.supportedKeys=(result.supported_picture_keys||[]).filter(key=>pgAutomationSettingCandidates().includes(key));
  pgAutomation.supportedValues=Object.assign({},current,prior);
  pgAutomation.pinnedKeys=Object.keys(prior);
  pgAutomation.supportedSignal=signal;pgAutomation.supportedPictureMode=pictureMode;
  pgAutomationRenderSettingsEditor();
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{button.disabled=false;button.textContent='Read supported controls';}
}
function pgAutomationUpdateEditor(){
 const signal=pgAutomationValue('Signal','sdr'),cal=pgAutomationChecked('Cal'),post=pgAutomationChecked('Post');
 pgAutomationEl('ApplyAll').disabled=!cal;
 pgAutomationEl('QualitySection').style.display=post?'':'none';
 pgAutomationEl('Sweeps').style.display=post||pgAutomationChecked('Pre')?'':'none';
 pgAutomationEl('PanelTarget').disabled=signal!=='sdr';
 pgAutomationEl('PanelPolicy').querySelector('option[value="target"]').disabled=signal!=='sdr'||!cal;
 pgAutomationEl('PanelFixedField').style.display=pgAutomationValue('PanelPolicy','fixed')==='fixed'?'':'none';
 pgAutomationEl('Method').disabled=!cal||signal==='hdr10'||signal==='dv';
 pgAutomationEl('ShadowFix').disabled=!cal||signal!=='hdr10';
 pgAutomationEl('Residuals').disabled=!cal||signal==='dv'||signal==='hdr10'||pgAutomationValue('Method','hybrid')==='matrix';
 pgAutomationEl('CubeSize').disabled=!cal||signal==='dv';
 pgAutomationEl('LuminanceHelp').textContent=signal==='sdr'?'Fixed panel light is preserved. Target policy adjusts panel light before calibration to reach your luminance target.':'HDR and Dolby Vision use the measured peak luminance. Fixed panel light is preserved through calibration.';
 pgAutomationEl('LutHelp').textContent=!cal?'Measurement only: no reset, 3D LUT, or profile upload.':signal==='dv'?'Dolby Vision: greyscale followed by a measured panel profile upload. No 3D LUT.':signal==='hdr10'?'HDR10: matrix profiling, 3D LUT upload, and the greyscale tone-mapping handoff.':'Greyscale followed by '+pgAutomationValue('Method','hybrid')+' profiling and a 33³ TV LUT upload. Export size controls the downloadable cube.';
}
function pgAutomationNumber(id,fallback,min,max){
 const value=Number(pgAutomationValue(id,fallback));
 if(!Number.isFinite(value)||value<min||value>max)throw new Error((pgAutomationEl(id)?.labels?.[0]?.textContent||id)+' must be between '+min+' and '+max+'.');
 return value;
}
function pgAutomationRecipeFromForm(){
 const recipe=pgAutomationSnapshot(pgAutomation.editingRecipe),signal=pgAutomationValue('Signal','sdr'),settings=pgAutomationReadSettingsEditor();
 const stages={pre_readings:pgAutomationChecked('Pre'),calibration:pgAutomationChecked('Cal'),post_readings:pgAutomationChecked('Post'),apply_all:pgAutomationChecked('Cal')&&pgAutomationChecked('ApplyAll')};
 if(!stages.pre_readings&&!stages.calibration&&!stages.post_readings)throw new Error('Enable at least one stage.');
 const pre=PG_AUTOMATION_SERIES.filter(x=>pgAutomationChecked('Series'+x[0])).map(x=>x[1]);
 const post=PG_AUTOMATION_SERIES.filter(x=>pgAutomationChecked('PostSeries'+x[0])).map(x=>x[1]);
 if(stages.pre_readings&&!pre.length||stages.post_readings&&!post.length)throw new Error('Select a sweep for each enabled readings stage.');
 const panelKey=pgAutomationValue('PanelKey',''),policy=pgAutomationValue('PanelPolicy','fixed');
 if(policy==='target'&&(signal!=='sdr'||!stages.calibration||!panelKey))throw new Error('Target luminance requires SDR AutoCal and a supported panel-light control.');
 const panelValue=pgAutomationNumber('PanelValue',signal==='sdr'?80:100,0,100);
 ['backlight','oledLight','oledPixelBrightness'].forEach(key=>delete settings[key]);
 if(panelKey&&policy==='fixed')settings[panelKey]=panelValue;
 const target=pgAutomationNumber('PanelTarget',100,1,10000),formula=pgAutomationValue('Formula','deitp');
 const limits={};
 PG_AUTOMATION_SERIES.forEach(([suffix,key])=>{const prefix='Quality'+(suffix==='Grey'?'':suffix);limits[key]={avg:pgAutomationNumber(prefix+'Avg',2,0,10000),max:pgAutomationNumber(prefix+'Max',5,0,10000)};});
 const white={x:pgAutomationNumber('WhiteX',.3127,.01,.9),y:pgAutomationNumber('WhiteY',.329,.01,.9)};
 if(white.x+white.y>=1)throw new Error('White point x + y must be below 1.');
 Object.assign(recipe,{
  name:pgAutomationValue('RecipeName','Automation item'),signal_format:signal,picture_mode:pgAutomationValue('PictureMode',''),
  settings,stages,pre_series:pre,post_series:post,
  target_luminance:target,target_gamma:pgAutomationValue('Gamma','bt1886'),target_gamut:pgAutomationValue('Gamut','bt709'),
  target_delta_e:pgAutomationNumber('Delta',1,.1,100),delta_e_formula:formula,target_white:white,
  panel_light:{policy,key:panelKey,fixed_value:panelValue,target_luminance:target},
  quality:{enabled:stages.post_readings&&pgAutomationChecked('Quality'),dE_formula:formula,limits},
  patch_size:pgAutomationNumber('PatchSize',10,1,100),delay_ms:pgAutomationNumber('Delay',1000,0,30000),
  warmup_minutes:pgAutomationNumber('Warmup',0,0,240),settle_seconds:pgAutomationNumber('Settle',8,0,600),
  signal_range:pgAutomationValue('Range','2'),pattern_signal_range:pgAutomationValue('Range','2'),
  transport_signal_range:pgAutomationValue('Range','2'),rgb_quant_range:pgAutomationValue('Range','2'),
  max_bpc:pgAutomationNumber('BitDepth',10,8,10),display_type:pgAutomationValue('DisplayType','lcd'),ccss_override:pgAutomationValue('Ccss','')
 });
 recipe.calibration=Object.assign({},recipe.calibration||{},{
  target_gamma:recipe.target_gamma,target_gamut:recipe.target_gamut,target_luminance:target,target_delta_e:recipe.target_delta_e,delta_e_formula:formula,target_white:white,
  method:signal==='hdr10'?'matrix':pgAutomationValue('Method','hybrid'),solve_cube_size:Number(pgAutomationValue('CubeSize',17)),
  lattice_residuals:pgAutomationChecked('Residuals'),dark_detail:pgAutomationChecked('DarkDetail'),shadow_fix:pgAutomationChecked('ShadowFix')
 });
 return recipe;
}
function pgAutomationFillRecipe(recipe){
 recipe=recipe||{};pgAutomation.editorEpoch++;pgAutomation.editingRecipe=pgAutomationClone(recipe);
 const set=(id,value)=>{pgAutomationEl(id).value=value==null?'':value;},check=(id,value)=>{pgAutomationEl(id).checked=!!value;};
 const cal=recipe.calibration||{},panel=recipe.panel_light||{},stages=recipe.stages||{};
 set('RecipeName',recipe.name||'SDR Filmmaker');set('Signal',recipe.signal_format||'sdr');pgAutomationModesChanged();
 const mode=recipe.picture_mode||pgAutomationModes(recipe.signal_format||'sdr')[0];
 if(!Array.from(pgAutomationEl('PictureMode').options).some(x=>x.value===mode))pgAutomationEl('PictureMode').add(new Option(mode,mode));
 set('PictureMode',mode);pgAutomationModeChanged();
 pgAutomation.supportedValues=pgAutomationClone(recipe.settings||{});pgAutomation.pinnedKeys=Object.keys(recipe.settings||{});
 if(Array.isArray(recipe.supported_picture_keys)&&recipe.supported_picture_keys.length){pgAutomation.supportedKeys=recipe.supported_picture_keys.filter(key=>pgAutomationSettingCandidates().includes(key));pgAutomation.supportedSignal=recipe.signal_format;pgAutomation.supportedPictureMode=mode;}
 pgAutomationRenderSettingsEditor();
 ['Pre','Cal','Post','ApplyAll'].forEach((id,index)=>{const key=['pre_readings','calibration','post_readings','apply_all'][index];check(id,stages[key]==null?true:!!stages[key]);});
 PG_AUTOMATION_SERIES.forEach(([suffix,key])=>{
  check('Series'+suffix,(recipe.pre_series||PG_AUTOMATION_SERIES.map(x=>x[1])).includes(key));
  check('PostSeries'+suffix,(recipe.post_series||recipe.pre_series||PG_AUTOMATION_SERIES.map(x=>x[1])).includes(key));
  const limit=recipe.quality?.limits?.[key]||{},prefix='Quality'+(suffix==='Grey'?'':suffix);
  set(prefix+'Avg',limit.avg??2);set(prefix+'Max',limit.max??5);
 });
 check('Quality',recipe.quality?.enabled);
 set('PanelPolicy',panel.policy||'fixed');set('PanelKey',panel.key||'');pgAutomationRenderPanelKeyOptions();
 set('PanelValue',panel.fixed_value??panel.value??80);set('PanelTarget',panel.target_luminance??recipe.target_luminance??100);
 set('Gamma',recipe.target_gamma||cal.target_gamma||(recipe.signal_format==='sdr'?'bt1886':recipe.signal_format==='hlg'?'hlg':'st2084'));
 set('Gamut',recipe.target_gamut||cal.target_gamut||(recipe.signal_format==='sdr'?'bt709':recipe.signal_format==='dv'?'p3d65':'bt2020'));
 set('Delta',cal.target_delta_e??recipe.target_delta_e??1);set('Formula',cal.delta_e_formula||recipe.delta_e_formula||'deitp');
 set('WhiteX',cal.target_white?.x??recipe.target_white?.x??.3127);set('WhiteY',cal.target_white?.y??recipe.target_white?.y??.329);
 set('Method',recipe.signal_format==='hdr10'?'matrix':cal.method||'hybrid');set('CubeSize',cal.solve_cube_size||17);
 check('Residuals',cal.lattice_residuals);check('DarkDetail',cal.dark_detail);check('ShadowFix',cal.shadow_fix);
 set('PatchSize',recipe.patch_size??10);set('Delay',recipe.delay_ms??1000);set('Warmup',recipe.warmup_minutes??0);set('Settle',recipe.settle_seconds??8);
 set('Range',recipe.signal_range||'2');set('BitDepth',recipe.max_bpc||10);set('DisplayType',recipe.display_type||'lcd');set('Ccss',recipe.ccss_override||'');
 check('SaveAsRecipe',false);pgAutomationUpdateEditor();
}
function pgAutomationOpenEditor(target,recipe,index){
 pgAutomation.editorTarget=target||'queue';pgAutomation.editingQueueIndex=index==null?null:index;
 pgAutomationFillRecipe(recipe);
 pgAutomationEl('EditorTitle').textContent=target==='recipe'?'Configure saved recipe':index==null?'Add queue item':'Configure item '+(index+1);
 pgAutomationEl('EditorSave').textContent=target==='recipe'?'Save recipe':index==null?'Add to queue':'Save item';
 pgAutomationEl('SaveAsRecipeLabel').style.display=target==='recipe'?'none':'';
 pgAutomationEl('EditorError').textContent='';
 pgAutomationEl('Editor').showModal();
 pgAutomationEl('Editor').scrollTop=0;
}
function pgAutomationCancelEditor(){pgAutomation.editorEpoch++;pgAutomationEl('Editor').close();pgAutomation.editingQueueIndex=null;}
function pgAutomationNewRecipe(target){
 let measurement={};
 try{
  measurement={display_type:typeof getEffectiveDisplayType==='function'?getEffectiveDisplayType():'lcd',
   ccss_override:typeof getCcssOverride==='function'?getCcssOverride():'',
   delay_ms:typeof meterDelayMs==='function'?meterDelayMs():1000,patch_size:typeof getMeterPatchSize==='function'?getMeterPatchSize():10,
   refresh_rate:typeof getMeterRefreshRate==='function'?getMeterRefreshRate():'',
   low_light:typeof meterLowLightReadState==='function'?meterLowLightReadState():{},
   ...(typeof meterPatternInsertionPayload==='function'?meterPatternInsertionPayload():{})};
 }catch(e){}
 const mode=pgAutomationModes('sdr').find(x=>/filmmaker/i.test(x))||'cinema';
 pgAutomationOpenEditor(target||'queue',{...measurement,color_format:typeof getVal==='function'?getVal('color_format'):'0',name:pgAutomationModeLabel(mode,'sdr'),signal_format:'sdr',picture_mode:mode,settings:{},panel_light:{policy:'fixed',key:'backlight',fixed_value:80,target_luminance:100}});
}
async function pgAutomationSaveRecipe(){
 const button=pgAutomationEl('EditorSave');if(button.disabled)return;button.disabled=true;
 try{
  const item=pgAutomationRecipeFromForm();
  if(pgAutomation.editorTarget==='recipe'||pgAutomationChecked('SaveAsRecipe')){
   const saved=pgAutomationClone(item);if(pgAutomation.editorTarget!=='recipe')delete saved.id;
   await pgAutomationRequest('recipes',{recipe:saved});
  }
  if(pgAutomation.editorTarget!=='recipe'){
   if(pgAutomation.editingQueueIndex!=null)pgAutomation.queue.items[pgAutomation.editingQueueIndex]=item;
   else pgAutomation.queue.items.push(item);
   pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationTab('queue');
  }
  pgAutomationCancelEditor();pgAutomationNotice(pgAutomation.editorTarget==='recipe'?'Recipe saved':'Queue item saved');await pgAutomationRefresh();
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{button.disabled=false;}
}
function pgAutomationItemSummary(item){
 const signal=item.signal_format||'sdr',cal=item.calibration||{},stages=item.stages||{},panel=item.panel_light||{};
 const enabled=key=>stages[key]==null||!!stages[key];
 const pills=[signal==='dv'?'Dolby Vision':signal.toUpperCase(),pgAutomationModeLabel(item.picture_mode,signal)];
 if(enabled('pre_readings'))pills.push('Before: '+(item.pre_series||PG_AUTOMATION_SERIES).length+' sweeps');
 if(enabled('calibration'))pills.push(signal==='dv'?'Greyscale + DV profile':'Greyscale + '+(signal==='hdr10'?'matrix':cal.method||'hybrid')+' 3D LUT');
 if(enabled('calibration')&&enabled('apply_all'))pills.push('All inputs');
 if(enabled('post_readings'))pills.push('After: '+(item.post_series||PG_AUTOMATION_SERIES).length+' sweeps');
 const settings=Object.entries(item.settings||{}).map(([key,value])=>pgAutomationSettingMetadata(key).label+' '+pgAutomationSettingValue(value));
 if(panel.key&&!Object.prototype.hasOwnProperty.call(item.settings||{},panel.key)&&panel.policy!=='target')settings.push(pgAutomationSettingMetadata(panel.key).label+' '+(panel.fixed_value??80));
 const targets=[];
 if(enabled('calibration'))targets.push('dE '+(cal.target_delta_e??item.target_delta_e??1)+' ('+(cal.delta_e_formula||item.delta_e_formula||'deitp')+')');
 targets.push(signal==='sdr'?(panel.policy==='target'?'Adjust panel to ':'Target ')+(panel.target_luminance??item.target_luminance??100)+' nits':'Measured peak luminance');
 targets.push(item.target_gamma||cal.target_gamma||(signal==='sdr'?'bt1886':'st2084'));targets.push(item.target_gamut||cal.target_gamut||(signal==='sdr'?'bt709':'p3d65'));
 return '<div class="auto-pills">'+pills.map(x=>'<span class="auto-pill">'+pgAutomationEscape(x)+'</span>').join('')+'</div><div class="auto-muted">'+targets.map(pgAutomationEscape).join(' · ')+'</div><div class="auto-muted">TV: '+pgAutomationEscape(settings.join(' · ')||'No explicit pins; default hazard controls applied')+'</div>';
}
function pgAutomationRenderRecipeList(){
 const list=pgAutomationEl('RecipeList'),select=pgAutomationEl('RecipeSelect'),prior=select.value;
 select.innerHTML='<option value="">Choose a saved recipe…</option>'+pgAutomation.recipes.map((recipe,i)=>'<option value="'+i+'">'+pgAutomationEscape(recipe.name)+'</option>').join('');
 if(prior)select.value=prior;
 list.innerHTML=pgAutomation.recipes.length?pgAutomation.recipes.map((recipe,i)=>'<div class="auto-item"><span></span><div><strong>'+pgAutomationEscape(recipe.name)+'</strong>'+pgAutomationItemSummary(recipe)+'</div><div class="auto-actions"><button class="btn btn-sm btn-secondary" onclick="pgAutomationEditRecipe('+i+')">Edit</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationDuplicateRecipe('+i+')">Duplicate</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationDeleteRecipe('+i+')">Delete</button></div></div>').join(''):'<div class="auto-empty">No recipes saved yet. Create one, or save a queue item as a recipe.</div>';
}
function pgAutomationEditRecipe(index){pgAutomationOpenEditor('recipe',pgAutomation.recipes[index]);}
function pgAutomationDuplicateRecipe(index){const copy=pgAutomationSnapshot(pgAutomation.recipes[index]);delete copy.id;copy.name+=' (copy)';pgAutomationOpenEditor('recipe',copy);}
async function pgAutomationDeleteRecipe(index){
 const recipe=pgAutomation.recipes[index];if(!recipe||!confirm('Delete saved recipe “'+recipe.name+'”? Queued copies remain.'))return;
 try{await pgAutomationRequest('recipes/delete',{id:recipe.id});await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}
}
function pgAutomationQueueAdd(){
 const value=pgAutomationValue('RecipeSelect','');if(value===''){pgAutomationNotice('Choose a saved recipe or use Add item.',true);return;}
 const recipe=pgAutomation.recipes[Number(value)];if(!recipe)return;
 pgAutomation.queue.items.push(pgAutomationSnapshot(recipe));pgAutomationSaveDraft();pgAutomationRenderQueue();
}
function pgAutomationQueueLocked(index){return !!pgAutomation.editingRunId&&index<pgAutomation.firstPending;}
function pgAutomationRenderQueue(){
 pgAutomationEl('QueueName').value=pgAutomation.queue.name||'TV calibration queue';
 pgAutomationEl('QueueCount').textContent=pgAutomation.queue.items.length;
 pgAutomationEl('QueueContext').textContent=pgAutomation.editingRunId?'Editing pending items for '+pgAutomation.editingRunId+'. Active and completed items are locked.':'';
 pgAutomationEl('SavePendingButton').style.display=pgAutomation.editingRunId?'':'none';
 pgAutomationEl('StartButton').style.display=pgAutomation.editingRunId?'none':'';
 pgAutomationEl('QueueItems').innerHTML=pgAutomation.queue.items.length?pgAutomation.queue.items.map((item,i)=>{
  const locked=pgAutomationQueueLocked(i);
  return '<div class="auto-item"><span class="auto-number">'+(i+1)+'</span><div><strong>'+pgAutomationEscape(item.name||'Item '+(i+1))+'</strong>'+pgAutomationItemSummary(item)+'</div><div class="auto-actions">'+(locked?'<span class="auto-muted">'+pgAutomationEscape(item.status||'Locked')+'</span>':'<button class="btn btn-sm btn-secondary" aria-label="Move item '+(i+1)+' up" '+(i===0||pgAutomationQueueLocked(i-1)?'disabled ':'')+'onclick="pgAutomationQueueMove('+i+',-1)">↑</button><button class="btn btn-sm btn-secondary" aria-label="Move item '+(i+1)+' down" '+(i===pgAutomation.queue.items.length-1?'disabled ':'')+'onclick="pgAutomationQueueMove('+i+',1)">↓</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueEdit('+i+')">Configure</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueDuplicate('+i+')">Duplicate</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueRemove('+i+')">Remove</button>')+'</div></div>';
 }).join(''):'<div class="auto-empty"><strong>Your batch starts here</strong><p class="auto-muted">Add an item to choose its signal, picture mode, TV settings, targets, and calibration method.</p><button class="btn btn-primary" onclick="pgAutomationNewRecipe(\'queue\')">+ Add first item</button></div>';
}
function pgAutomationQueueEdit(index){if(!pgAutomationQueueLocked(index))pgAutomationOpenEditor('queue',pgAutomation.queue.items[index],index);}
function pgAutomationQueueDuplicate(index){const copy=pgAutomationSnapshot(pgAutomation.queue.items[index]);delete copy.id;copy.name+=' (copy)';pgAutomation.queue.items.splice(index+1,0,copy);pgAutomationSaveDraft();pgAutomationRenderQueue();}
function pgAutomationQueueRemove(index){if(pgAutomationQueueLocked(index))return;pgAutomation.queue.items.splice(index,1);pgAutomationSaveDraft();pgAutomationRenderQueue();}
function pgAutomationQueueMove(index,delta){const target=index+delta;if(target<0||target>=pgAutomation.queue.items.length||pgAutomationQueueLocked(index)||pgAutomationQueueLocked(target))return;const item=pgAutomation.queue.items.splice(index,1)[0];pgAutomation.queue.items.splice(target,0,item);pgAutomationSaveDraft();pgAutomationRenderQueue();}
function pgAutomationNewQueue(){
 if(pgAutomation.queue.items.length&&!confirm('Start a new draft queue? Save this queue first if you want to reuse it.'))return;
 pgAutomation.queue={name:'TV calibration queue',items:[]};pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomationSaveDraft();pgAutomationRenderQueue();
}
async function pgAutomationQueueSave(){
 try{const queue={...pgAutomation.queue,items:pgAutomation.queue.items.map(pgAutomationSnapshot)};const result=await pgAutomationRequest('queues',{queue});pgAutomation.queue.id=result.queue.id;pgAutomationSaveDraft();pgAutomationNotice('Queue saved');await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}
}
function pgAutomationRenderSavedQueues(){
 const select=pgAutomationEl('SavedQueueSelect'),prior=select.value;
 select.innerHTML='<option value="">Choose a saved queue…</option>'+pgAutomation.queues.map((queue,i)=>'<option value="'+i+'">'+pgAutomationEscape(queue.name)+' ('+(queue.items||[]).length+' items)</option>').join('');
 if(prior)select.value=prior;
}
function pgAutomationLoadQueue(){
 const value=pgAutomationValue('SavedQueueSelect',''),queue=value!==''?pgAutomation.queues[Number(value)]:null;if(!queue)return;
 if(pgAutomation.queue.items.length&&!confirm('Replace this draft with saved queue “'+queue.name+'”?'))return;
 pgAutomation.queue=pgAutomationClone(queue);pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomationSaveDraft();pgAutomationRenderQueue();
}
async function pgAutomationDeleteQueue(){
 const value=pgAutomationValue('SavedQueueSelect',''),queue=value!==''?pgAutomation.queues[Number(value)]:null;
 if(!queue||!confirm('Delete saved queue “'+queue.name+'”? Run history remains.'))return;
 try{await pgAutomationRequest('queues/delete',{id:queue.id});await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}
}
function pgAutomationRenderReadiness(result){
 const box=pgAutomationEl('Readiness');if(!result){box.textContent='Readiness request failed';return;}
 box.innerHTML='<h3 style="color:'+(result.ready?'var(--green)':'var(--red)')+'">'+pgAutomationEscape(result.message||'Readiness')+'</h3>'+(result.checks||[]).map(check=>'<div class="auto-muted" style="padding:4px 0;color:'+(check.ok?'var(--text2)':check.level==='warning'?'var(--orange)':'var(--red)')+'">'+(check.item_number!=null?'Item '+(Number(check.item_number)+1)+' · ':'')+(check.ok?'✓ ':check.level==='warning'?'Check manually: ':'✕ ')+pgAutomationEscape(check.message||check.name)+'</div>').join('');
}
async function pgAutomationReadiness(){
 const button=pgAutomationEl('ReadinessButton');button.disabled=true;button.textContent='Checking TV and meter…';
 try{pgAutomationRenderReadiness(await pgAutomationRequest('readiness',{items:pgAutomation.queue.items},300000));}catch(e){pgAutomationNotice(e.message,true);}
 finally{button.disabled=false;button.textContent='Check readiness';}
}
async function pgAutomationStart(){
 if(pgAutomation.busy)return;if(!pgAutomation.queue.items.length){pgAutomationNotice('Add at least one queue item.',true);return;}
 pgAutomation.busy=true;pgAutomationEl('StartButton').disabled=true;pgAutomationEl('StartButton').textContent='Checking and starting…';
 try{
  const result=await pgAutomationRequest('runs/start',{queue:pgAutomation.queue},300000);
  if(!result.run_id){pgAutomationRenderReadiness(result);throw new Error(result.message||'Batch did not start');}
  pgAutomationNotice('Batch started');await pgAutomationRefresh();pgAutomationTab('live');
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{pgAutomation.busy=false;pgAutomationEl('StartButton').disabled=false;pgAutomationEl('StartButton').textContent='Start batch';}
}
function pgAutomationCurrentRun(){return pgAutomation.current?.run||null;}
async function pgAutomationControl(action){
 const run=pgAutomationCurrentRun();if(!run)return;
 try{const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/control/'+action,{},300000);if(result.ready===0){pgAutomationRenderReadiness(result);pgAutomationTab('queue');throw new Error(result.message);}pgAutomationNotice(result.message);await pgAutomationPollLive();}catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationLoadActiveQueue(){
 const run=pgAutomationCurrentRun();if(!run){pgAutomationNotice('No active batch to edit.',true);return;}
 try{
  const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/edit');
  pgAutomation.queue={name:run.queue_name,items:result.items};pgAutomation.editingRunId=run.id;pgAutomation.firstPending=result.first_pending;
  pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationTab('queue');
 }catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationEditActiveQueue(){
 if(!pgAutomation.editingRunId)return;
 try{
  await pgAutomationRequest('runs/'+encodeURIComponent(pgAutomation.editingRunId)+'/edit',{first_pending:pgAutomation.firstPending,items:pgAutomation.queue.items.slice(pgAutomation.firstPending)});
  pgAutomationNotice('Pending changes saved');await pgAutomationPollLive();
 }catch(e){pgAutomationNotice(e.message+' Reload pending items if the batch has advanced.',true);}
}
function pgAutomationRenderLiveRun(run,execution){
 const status=run?.status||'idle';pgAutomationEl('State').textContent=status.replace(/-/g,' ');
 pgAutomationEl('PauseButton').disabled=status!=='running';pgAutomationEl('ResumeButton').disabled=!['paused','interrupted'].includes(status);
 pgAutomationEl('StopButton').disabled=!['starting','running','paused','interrupted','stopping'].includes(status);
 const live=pgAutomationEl('Live');
 if(!run){live.innerHTML='<div class="auto-empty">No active batch. Completed and stopped runs are in History.</div>';return;}
 const active=run.active_item!=null?Number(run.active_item):-1,items=run.items||[],worker=run.worker_status||{};
 live.innerHTML='<h3>'+pgAutomationEscape(run.queue_name||'Batch')+' · '+pgAutomationEscape(status)+'</h3>'
  +'<p class="auto-muted">'+(active>=0?'Item '+(active+1)+' of '+items.length+' · ':'')+pgAutomationEscape((run.active_stage||'Between stages').replace(/-/g,' '))+'</p>'
  +'<p>'+pgAutomationEscape(worker.current_name||worker.message||'')+(worker.total_steps?' · '+Number(worker.current_step||0)+' / '+Number(worker.total_steps):'')+'</p>'
  +(run.failure?'<p style="color:var(--red)">'+pgAutomationEscape(run.failure.message||'')+'</p>':'')
  +'<p class="auto-muted">Saved checkpoint: '+pgAutomationEscape(run.checkpoint||'none')+' · Heartbeat '+pgAutomationEscape(run.heartbeat_age==null?'pending':run.heartbeat_age+'s ago')+'</p>'
  +items.map((item,i)=>'<div class="auto-item"><span class="auto-number">'+(i+1)+'</span><strong>'+pgAutomationEscape(item.name||'Item')+'</strong><span>'+pgAutomationEscape(item.status||'Queued')+'</span></div>').join('');
}
async function pgAutomationPollLive(){
 if(pgAutomation.polling)return;pgAutomation.polling=true;
 try{
  const result=await fetchJSON('/api/automation/runs/current',{_quiet:true,_timeoutMs:8000});
  if(result&&result.status!=='error'){pgAutomation.current=result;pgAutomationRenderLiveRun(result.run,result.execution);}
 }finally{
  pgAutomation.polling=false;
  if(pgAutomation.liveTimer)clearTimeout(pgAutomation.liveTimer);
  pgAutomation.liveTimer=setTimeout(()=>{pgAutomation.liveTimer=null;pgAutomationPollLive();},3000);
 }
}
function pgAutomationHistorySummary(run,index){
 return '<div style="display:flex;justify-content:space-between;align-items:center;gap:8px;padding:8px 0;border-top:1px solid var(--border)"><span><strong>'+pgAutomationEscape(run.queue_name||'Automation queue')+'</strong><br><small style="color:var(--text2)">'+pgAutomationEscape(run.created_at_iso||run.id||'')+' · '+pgAutomationEscape(run.status||'')+'</small></span><span><button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationOpenHistory('+index+')">Open</button> <button class="btn btn-sm btn-danger" type="button" onclick="pgAutomationDeleteRun('+index+')">Delete</button></span></div>';
}

function pgAutomationRenderHistoryList(){
 const el=document.getElementById('pgAutomationHistoryList');
 if(el)el.innerHTML=pgAutomation.history.length?pgAutomation.history.map(pgAutomationHistorySummary).join(''):'No automation history.';
}

async function pgAutomationOpenHistory(index){
 const summary=pgAutomation.history[index];
 if(!summary)return;
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(summary.id),{_quiet:true,_timeoutMs:30000});
 const run=result&&result.run;
 if(!run){pgAutomationNotice((result&&result.message)||'Unable to load automation history',true);return;}
 pgAutomation.currentHistoryRunId=run.id||summary.id||'';
 const detail=document.getElementById('pgAutomationHistoryDetail');
 if(!detail)return;
 detail.innerHTML='<div style="font-weight:700;margin-bottom:8px">'+pgAutomationEscape(run.queue_name||'Automation queue')+' · '+pgAutomationEscape(run.status||'')+'</div>'
  +'<div style="color:var(--text2);margin-bottom:8px">'+pgAutomationEscape(run.failure&&run.failure.message||'')+'</div>'
  +'<div>'+((run.items||[]).map(pgAutomationHistoryItemHtml).join(''))+'</div>'
  +'<div id="pgAutomationHistoryReport" style="margin-top:10px"><span style="color:var(--text2)">Building pre and post graphs…</span></div>';
 pgAutomationBuildHistoryReport(run);
}

function pgAutomationHistoryItemHtml(item,index){
 const apply=item&&item['apply-all'];
 const quality=item&&item.quality;
 const panel=item&&item['panel-light'];
 const warningList=Array.isArray(item&&item.warnings)?item.warnings:[];
 const details=[pgAutomationEscape(item&&item.status||''),((item&&item.checkpoints)||[]).filter(x=>x&&x.status==='done').length+' checkpoints'];
 if(warningList.length)details.push(warningList.length+' warnings: '+pgAutomationEscape(warningList.map(w=>typeof w==='string'?w:[w.code,w.series,w.message].filter(Boolean).join(': ')).join(', ')));
 if(apply)details.push('Apply to all: '+pgAutomationEscape(apply.outcome||apply.status||'unverified'));
 if(quality&&quality.warnings&&quality.warnings.length)details.push('Quality limits: '+quality.warnings.length+' miss'+(quality.warnings.length===1?'':'es'));
 if(panel&&panel.warning)details.push(pgAutomationEscape(panel.warning));
 const base=item&&item.item_number!=null?item.item_number:index;
 const qualityRows=quality?.enabled?Object.entries(quality.series||{}).map(([key,result])=>'<tr><td>'+pgAutomationEscape(key)+'</td><td>'+(result.average==null?'Unavailable':Number(result.average).toFixed(2))+'</td><td>'+(result.maximum==null?'Unavailable':Number(result.maximum).toFixed(2))+'</td><td>'+(result.passed==null?'Unverified':result.passed?'Pass':'Limit missed')+'</td></tr>').join(''):'';
 return '<div style="padding:12px 0;border-top:1px solid var(--border)"><strong>Item '+(index+1)+': '+pgAutomationEscape(item&&item.name||item&&item.picture_mode||'')+'</strong>'+pgAutomationItemSummary(item)+'<p style="color:var(--text2)">'+details.join(' · ')+'</p>'+(item.failure?'<p style="color:var(--red)">'+pgAutomationEscape(item.failure.message||item.failure.stage)+'</p>':'')+(qualityRows?'<table><thead><tr><th>Sweep</th><th>Average dE</th><th>Maximum dE</th><th>Quality</th></tr></thead><tbody>'+qualityRows+'</tbody></table>':'')+'<a href="/api/automation/runs/'+encodeURIComponent(pgAutomation.currentHistoryRunId||'')+'/artifact/items/'+base+'/settings-checks.ndjson" target="_blank" style="color:var(--link)">Settings checks</a></div>';
}

async function pgAutomationBuildHistoryReport(run){
 const target=document.getElementById('pgAutomationHistoryReport');
 if(!target||typeof meterFullAutoCalBuildSnapshotReportSections!=='function')return;
 if(pgAutomation.reportBusy){pgAutomation.pendingHistoryRun=run;return;}
 pgAutomation.reportBusy=true;
 const entries=[];
 const runId=String(run&&run.id||pgAutomation.currentHistoryRunId||'');
 const seriesRequests=[];
 (run.items||[]).forEach((item,index)=>{
  const calibration=item&&item.calibration||{};
  const grey=calibration['grey-state'];
  if(grey&&Array.isArray(grey.readings)&&grey.readings.length)entries.push({title:'Item '+(index+1)+' Calibration Greyscale',snapshot:grey});
  const volume=calibration['3d-state'];
  if(volume&&Array.isArray(volume.readings)&&volume.readings.length)entries.push({title:'Item '+(index+1)+' 3D LUT measurements',snapshot:{...volume,type:'colors',points:volume.readings.length,signal_mode:item.signal_format,target_gamma:item.target_gamma}});
  ['pre','post'].forEach(stage=>{
   if(item.stages&&item.stages[stage+'_readings']!=null&&!item.stages[stage+'_readings'])return;
   (item[stage+'_series']||['greyscale-21','colors-30','saturations-24']).forEach(key=>{
    seriesRequests.push({
     title:'Item '+(index+1)+' '+(stage==='pre'?'Pre-Cal ':'Post-Cal ')+key,
     path:'/api/automation/runs/'+encodeURIComponent(runId)+'/artifact/items/'+index+'/'+stage+'/'+key+'.json'
    });
   });
  });
 });
 try{
  const snapshots=await Promise.all(seriesRequests.map(request=>fetchJSON(request.path,{_quiet:true,_timeoutMs:30000})));
  seriesRequests.forEach((request,index)=>entries.push({title:request.title,snapshot:snapshots[index]||null}));
  if(pgAutomation.currentHistoryRunId!==runId)return;
  // The shared renderer snapshots real canvases. Give its hidden workspace a
  // layout off-screen without navigating away from Automation or touching TV state.
  document.body.classList.add('pg-automation-report-render');
  let html;
  try{html=await meterFullAutoCalBuildSnapshotReportSections(entries);}
  finally{document.body.classList.remove('pg-automation-report-render');}
  if(pgAutomation.currentHistoryRunId===runId)target.innerHTML=html||'<div style="color:var(--text2)">No graph data was saved for this run.</div>';
 }catch(e){target.innerHTML='<div style="color:var(--red)">Unable to render saved graphs: '+pgAutomationEscape(e.message||e)+'</div>';}
 finally{pgAutomation.reportBusy=false;if(pgAutomation.pendingHistoryRun){const pending=pgAutomation.pendingHistoryRun;pgAutomation.pendingHistoryRun=null;pgAutomationBuildHistoryReport(pending);}}
}

async function pgAutomationDeleteRun(index){
 const run=pgAutomation.history[index];
 if(!run||!confirm('Delete this run and its saved results? This cannot be undone.'))return;
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(run.id)+'/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Unable to delete run',true);return;}
 const detail=document.getElementById('pgAutomationHistoryDetail');if(detail)detail.innerHTML='';
 await pgAutomationRefresh();
}

function pgAutomationTab(tab){
 ['recipes','queue','live','history'].forEach(name=>{const el=document.getElementById('pgAutomationTab'+name.charAt(0).toUpperCase()+name.slice(1));if(el)el.style.display=name===tab?'':'none';});
 pgAutomation.tab=tab;
 document.querySelectorAll('[data-auto-tab]').forEach(el=>el.setAttribute('aria-selected',String(el.getAttribute('data-auto-tab')===tab)));
 if(tab==='history')pgAutomationRefresh();
 if(tab==='live')pgAutomationPollLive();
}

async function pgAutomationRefresh(){
 const responses=await Promise.all([
  fetchJSON('/api/automation/recipes',{_quiet:true,_timeoutMs:5000}),
  fetchJSON('/api/automation/queues',{_quiet:true,_timeoutMs:5000}),
  fetchJSON('/api/automation/runs',{_quiet:true,_timeoutMs:5000}),
  fetchJSON('/api/automation/runs/current',{_quiet:true,_timeoutMs:5000})
 ]);
 if(responses[0]&&Array.isArray(responses[0].recipes))pgAutomation.recipes=responses[0].recipes;
 if(responses[1]&&Array.isArray(responses[1].queues))pgAutomation.queues=responses[1].queues;
 if(responses[2]&&Array.isArray(responses[2].runs))pgAutomation.history=responses[2].runs;
 pgAutomationRenderRecipeList();
 pgAutomationRenderSavedQueues();
 pgAutomationRenderQueue();
 pgAutomationRenderHistoryList();
 pgAutomation.current=responses[3];
 pgAutomationRenderLiveRun(responses[3]&&responses[3].run,responses[3]&&responses[3].execution);
 const active=responses[3]&&responses[3].run&&['starting','running','paused','stopping','interrupted'].indexOf(responses[3].run.status)>=0;
 if(active&&!pgAutomation.liveTimer)pgAutomation.liveTimer=setTimeout(async()=>{pgAutomation.liveTimer=null;await pgAutomationPollLive();},3000);
}

function pgAutomationInit(){
 if(pgAutomation.loaded)return;pgAutomation.loaded=true;
 try{const saved=JSON.parse(localStorage.getItem('pgen.automation.queueDraft')||'null');if(saved&&Array.isArray(saved.queue?.items)){pgAutomation.queue=saved.queue;pgAutomation.editingRunId=saved.editingRunId||'';pgAutomation.firstPending=saved.firstPending||0;}}catch(e){}
 pgAutomationRenderQueue();pgAutomationRenderRecipeList();pgAutomationRenderSavedQueues();
 pgAutomationRefresh();pgAutomationTab('queue');pgAutomationPollLive();
}
setTimeout(pgAutomationInit,0);
