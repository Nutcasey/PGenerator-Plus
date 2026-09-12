var pgAutomation = {
 loaded: false,
 recipes: [],
 queues: [],
 queue: {name: 'TV calibration queue', items: []},
 current: null,
 currentHistoryRunId: '',
 history: [],
 liveTimer: null,
 reportBusy: false,
 supportedKeys: [],
 supportedValues: {},
 supportedSignal: '',
 supportedPictureMode: ''
};

function pgAutomationEscape(value){
 return String(value==null?'':value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

function pgAutomationClone(value){
 try{return JSON.parse(JSON.stringify(value));}catch(e){return null;}
}

function pgAutomationNotice(message,error){
 const el=document.getElementById('pgAutomationNotice');
 if(!el)return;
 el.textContent=message||'';
 el.style.display=message?'block':'none';
 el.style.borderColor=error?'var(--red)':'var(--border)';
 el.style.color=error?'var(--red)':'var(--text2)';
}

function pgAutomationModes(signal){
 signal=String(signal||'sdr').toLowerCase();
 if(signal==='dv') return ['dolbyVisionCinemaBright','dolbyVisionFilmMaker','dolbyVisionGame','dolbyVisionVivid','dolbyVisionStandard','dolbyVisionPersonalized'];
 if(signal==='hdr10'||signal==='hlg') return ['hdrCinema','hdrCinemaBright','hdrFilmMaker','hdrGame','hdrStandard','hdrEco','hdrVivid','hdrPersonalized'];
 return ['expert1','expert2','cinema','filmMaker','game','normal','eco','sports','vivid','personalized'];
}

function pgAutomationModesChanged(){
 const signal=document.getElementById('pgAutomationSignal');
 const select=document.getElementById('pgAutomationPictureMode');
 if(!signal||!select)return;
 const prior=select.value;
 select.innerHTML=pgAutomationModes(signal.value).map(mode=>'<option value="'+pgAutomationEscape(mode)+'">'+pgAutomationEscape(mode)+'</option>').join('');
 if(pgAutomationModes(signal.value).indexOf(prior)>=0)select.value=prior;
 if(pgAutomation.supportedSignal&&(pgAutomation.supportedSignal!==signal.value||pgAutomation.supportedPictureMode!==select.value)){
  pgAutomation.supportedKeys=[];
  pgAutomation.supportedValues={};
  pgAutomation.supportedSignal='';
  pgAutomation.supportedPictureMode='';
  pgAutomationRenderSettingsEditor();
 }
}

function pgAutomationSettingMetadata(key){
 try{
  if(typeof LG_DISPLAY_CONTROL_ITEMS!=='undefined'){
   const found=LG_DISPLAY_CONTROL_ITEMS.find(item=>item&&item.key===key);
   if(found)return found;
  }
 }catch(e){}
 return {key:key,label:key,type:'text'};
}

function pgAutomationSettingCandidates(){
 try{
  if(typeof LG_DISPLAY_CONTROL_KEYS!=='undefined'&&Array.isArray(LG_DISPLAY_CONTROL_KEYS))return LG_DISPLAY_CONTROL_KEYS.slice();
  if(typeof LG_DISPLAY_CONTROL_ITEMS!=='undefined'&&Array.isArray(LG_DISPLAY_CONTROL_ITEMS))return LG_DISPLAY_CONTROL_ITEMS.map(item=>item.key);
 }catch(e){}
 return ['brightness','contrast','blackLevel','blackLevelAdjust','backlight','oledLight','oledPixelBrightness','peakBrightness','color','colorDepth','tint','sharpness','hSharpness','vSharpness','gamma','colorTemperature','colorGamut','energySaving','dynamicContrast','dynamicColor','localDimming','noiseReduction','mpegNoiseReduction','smoothGradation','superResolution','realCinema','eyeComfortMode','blackFrameInsertion','truMotionMode','deJudder','deBlur'];
}

function pgAutomationSettingValue(value){
 if(value===null||value===undefined)return '';
 if(typeof value==='object')return JSON.stringify(value);
 return String(value);
}

function pgAutomationRenderSettingsEditor(){
 const editor=document.getElementById('pgAutomationSettingsEditor');
 const status=document.getElementById('pgAutomationSettingsStatus');
 if(!editor)return;
 if(!pgAutomation.supportedKeys.length){
  editor.innerHTML='<div style="grid-column:1/-1;color:var(--text2)">No TV-supported picture keys loaded.</div>';
  if(status&&!pgAutomation.supportedSignal)status.textContent='Connect the TV, then refresh the supported keys.';
  return;
 }
 editor.innerHTML=pgAutomation.supportedKeys.map(key=>{
  const meta=pgAutomationSettingMetadata(key);
  const label=meta.label||key;
  const value=pgAutomationSettingValue(pgAutomation.supportedValues[key]);
  if(meta.type==='select'&&Array.isArray(meta.options)){
   const options=meta.options.slice();
   if(value&&!options.some(option=>String(option)===value))options.unshift(value);
   return '<div class="field"><label>'+pgAutomationEscape(label)+'</label><select data-pg-automation-key="'+pgAutomationEscape(key)+'">'+options.map(option=>'<option value="'+pgAutomationEscape(option)+'"'+(String(option)===value?' selected':'')+'>'+pgAutomationEscape(option)+'</option>').join('')+'</select></div>';
  }
  const number=meta.type==='number';
  return '<div class="field"><label>'+pgAutomationEscape(label)+'</label><input data-pg-automation-key="'+pgAutomationEscape(key)+'" data-pg-automation-number="'+(number?'1':'0')+'" type="'+(number?'number':'text')+'"'+(meta.min!=null?' min="'+pgAutomationEscape(meta.min)+'"':'')+(meta.max!=null?' max="'+pgAutomationEscape(meta.max)+'"':'')+(meta.step!=null?' step="'+pgAutomationEscape(meta.step)+'"':'')+' value="'+pgAutomationEscape(value)+'"></div>';
 }).join('');
 if(status)status.textContent=pgAutomation.supportedKeys.length+' keys reported by the TV for '+(pgAutomation.supportedPictureMode||'this picture mode');
 pgAutomationRenderPanelKeyOptions();
}

function pgAutomationRenderPanelKeyOptions(){
 const select=document.getElementById('pgAutomationPanelKey');
 if(!select)return;
 const prior=select.value;
 if(!pgAutomation.supportedKeys.length){
  select.innerHTML='<option value="">Load TV-supported keys first</option>';
  select.value='';
  return;
 }
 select.innerHTML=pgAutomation.supportedKeys.map(key=>'<option value="'+pgAutomationEscape(key)+'">'+pgAutomationEscape(key)+'</option>').join('');
 if(pgAutomation.supportedKeys.indexOf(prior)>=0)select.value=prior;
 else if(pgAutomation.supportedKeys.indexOf('backlight')>=0)select.value='backlight';
 else if(pgAutomation.supportedKeys.indexOf('oledLight')>=0)select.value='oledLight';
 else select.value=pgAutomation.supportedKeys[0]||'';
}

function pgAutomationReadSettingsEditor(){
 const values={};
 document.querySelectorAll('[data-pg-automation-key]').forEach(input=>{
  const key=input.getAttribute('data-pg-automation-key');
  let value=input.value;
  if(input.getAttribute('data-pg-automation-number')==='1'&&value!=='')value=Number(value);
  values[key]=value;
 });
 return values;
}

async function pgAutomationLoadSupportedKeys(){
 const signal=(document.getElementById('pgAutomationSignal')||{}).value||'sdr';
 const pictureMode=(document.getElementById('pgAutomationPictureMode')||{}).value||'';
 const result=await fetchJSON('/api/lg/picture-settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({keys:pgAutomationSettingCandidates(),picture_mode:pictureMode,signal_mode:signal,category:'picture'})});
 if(!result||result.status==='error'){
  pgAutomationNotice((result&&result.message)||'Unable to read TV-supported picture keys',true);
  return;
 }
 const reported=Array.isArray(result.supported_picture_keys)?result.supported_picture_keys:[];
 const current=result.picture_settings&&typeof result.picture_settings==='object'?result.picture_settings:(result.settings&&typeof result.settings==='object'?result.settings:{});
 const prior=pgAutomation.supportedValues||{};
 pgAutomation.supportedKeys=reported.filter(key=>key&&key!=='pictureMode');
 pgAutomation.supportedValues={};
 pgAutomation.supportedKeys.forEach(key=>{pgAutomation.supportedValues[key]=Object.prototype.hasOwnProperty.call(prior,key)?prior[key]:current[key];});
 pgAutomation.supportedSignal=signal;
 pgAutomation.supportedPictureMode=pictureMode;
 const settings=document.getElementById('pgAutomationSettings');
 if(settings)settings.value=JSON.stringify(pgAutomation.supportedValues,null,2);
 pgAutomationRenderSettingsEditor();
 pgAutomationNotice('Loaded '+pgAutomation.supportedKeys.length+' picture keys reported by the TV');
}

function pgAutomationRecipeFromForm(){
 let settings={};
 if(pgAutomation.supportedKeys.length){
  settings=pgAutomationReadSettingsEditor();
  settings=Object.fromEntries(Object.entries(settings).filter(([,value])=>value!==''));
  const settingsEl=document.getElementById('pgAutomationSettings');
  if(settingsEl)settingsEl.value=JSON.stringify(settings,null,2);
 }else{
  const settingsText=(document.getElementById('pgAutomationSettings')||{}).value||'{}';
  try{settings=JSON.parse(settingsText||'{}');}catch(e){throw new Error('Picture settings JSON is invalid');}
  if(Object.keys(settings).length)throw new Error('Refresh the TV-supported keys before adding picture settings');
 }
 if(!settings||typeof settings!=='object'||Array.isArray(settings))throw new Error('Picture settings must be a JSON object');
 const checked=id=>!!((document.getElementById(id)||{}).checked);
 const series=[];
 if(checked('pgAutomationSeriesGrey'))series.push('greyscale-21');
 if(checked('pgAutomationSeriesColors'))series.push('colors-30');
 if(checked('pgAutomationSeriesSats'))series.push('saturations-24');
 if(!series.length)throw new Error('Select at least one measurement series');
 const signal=(document.getElementById('pgAutomationSignal')||{}).value||'sdr';
 const panelPolicy=(document.getElementById('pgAutomationPanelPolicy')||{}).value||'fixed';
 const panelKey=(document.getElementById('pgAutomationPanelKey')||{}).value||'';
 const panelValue=(document.getElementById('pgAutomationPanelValue')||{}).value||'';
 const panelTarget=Number((document.getElementById('pgAutomationPanelTarget')||{}).value||100);
 const qualityEnabled=checked('pgAutomationQuality');
 const qualityAverage=Math.max(0,Number((document.getElementById('pgAutomationQualityAvg')||{}).value||2));
 const qualityMaximum=Math.max(0,Number((document.getElementById('pgAutomationQualityMax')||{}).value||5));
 const qualityLimits={};
 series.forEach(key=>{qualityLimits[key]={avg:qualityAverage,max:qualityMaximum};});
 return {
  id:(pgAutomation.editingRecipe&&pgAutomation.editingRecipe.id)||undefined,
  name:(document.getElementById('pgAutomationRecipeName')||{}).value||'Automation item',
  signal_format:signal,
  picture_mode:(document.getElementById('pgAutomationPictureMode')||{}).value||'',
  settings:settings,
  stages:{pre_readings:checked('pgAutomationPre'),calibration:checked('pgAutomationCal'),post_readings:checked('pgAutomationPost'),apply_all:checked('pgAutomationApplyAll')},
  pre_series:series.slice(),
  post_series:series.slice(),
  quality:{enabled:qualityEnabled,dE_formula:'deitp',limits:qualityLimits},
  panel_light:{policy:panelPolicy,key:panelKey,fixed_value:panelValue,target_luminance:panelTarget},
  settle_seconds:Number((document.getElementById('pgAutomationSettle')||{}).value||8)
 };
}

function pgAutomationFillRecipe(recipe){
 recipe=recipe||{};
 const set=(id,value)=>{const el=document.getElementById(id);if(el)el.value=value==null?'':value;};
 const check=(id,value)=>{const el=document.getElementById(id);if(el)el.checked=!!value;};
 pgAutomation.editingRecipe=pgAutomationClone(recipe);
 set('pgAutomationRecipeName',recipe.name||'SDR calibration');
 set('pgAutomationSignal',recipe.signal_format||recipe.signal_mode||'sdr');
 pgAutomationModesChanged();
 set('pgAutomationPictureMode',recipe.picture_mode||'');
 if(pgAutomation.supportedSignal&&((pgAutomation.supportedSignal!==((document.getElementById('pgAutomationSignal')||{}).value||'sdr'))||pgAutomation.supportedPictureMode!==((document.getElementById('pgAutomationPictureMode')||{}).value||''))){
  pgAutomation.supportedKeys=[];
  pgAutomation.supportedSignal='';
  pgAutomation.supportedPictureMode='';
 }
 set('pgAutomationSettle',recipe.settle_seconds==null?8:recipe.settle_seconds);
 pgAutomation.supportedValues=pgAutomationClone(recipe.settings||{})||{};
 set('pgAutomationSettings',JSON.stringify(pgAutomation.supportedValues,null,2));
 pgAutomationRenderSettingsEditor();
 const stages=recipe.stages||{};
 check('pgAutomationPre',stages.pre_readings!==false);
 check('pgAutomationCal',stages.calibration!==false);
 check('pgAutomationPost',stages.post_readings!==false);
 check('pgAutomationApplyAll',stages.apply_all!==false);
 const series=recipe.pre_series||recipe.series||['greyscale-21','colors-30','saturations-24'];
 check('pgAutomationSeriesGrey',series.indexOf('greyscale-21')>=0);
 check('pgAutomationSeriesColors',series.indexOf('colors-30')>=0);
 check('pgAutomationSeriesSats',series.indexOf('saturations-24')>=0);
 const quality=recipe.quality||{};
 check('pgAutomationQuality',!!quality.enabled);
 const qualityDefault=quality.limits&&quality.limits['greyscale-21']||{};
 set('pgAutomationQualityAvg',qualityDefault.avg==null?2:qualityDefault.avg);
 set('pgAutomationQualityMax',qualityDefault.max==null?5:qualityDefault.max);
 const panel=recipe.panel_light||{};
 set('pgAutomationPanelPolicy',panel.policy||'fixed');
 set('pgAutomationPanelKey',panel.key||recipe.panel_light_key||'backlight');
 set('pgAutomationPanelValue',panel.fixed_value==null?(panel.value==null?'80':panel.value):panel.fixed_value);
 set('pgAutomationPanelTarget',panel.target_luminance==null?(recipe.target_luminance||100):panel.target_luminance);
 pgAutomationRenderPanelKeyOptions();
}

function pgAutomationNewRecipe(){
 pgAutomation.editingRecipe=null;
 pgAutomation.editingQueueIndex=null;
 pgAutomation.supportedKeys=[];
 pgAutomation.supportedValues={};
 pgAutomation.supportedSignal='';
 pgAutomation.supportedPictureMode='';
 pgAutomationFillRecipe({name:'SDR calibration',signal_format:'sdr',picture_mode:'cinema',settings:{},stages:{pre_readings:true,calibration:true,post_readings:true,apply_all:true},pre_series:['greyscale-21','colors-30','saturations-24'],post_series:['greyscale-21','colors-30','saturations-24'],quality:{enabled:false,dE_formula:'deitp',limits:{}},panel_light:{policy:'fixed',key:'backlight',fixed_value:80,target_luminance:100},settle_seconds:8});
}

async function pgAutomationSaveRecipe(){
 try{
  if(pgAutomation.editingQueueIndex!=null){
   const item=pgAutomationRecipeFromForm();
   pgAutomation.queue.items[pgAutomation.editingQueueIndex]=item;
   pgAutomation.editingQueueIndex=null;
   pgAutomationRenderQueue();
   pgAutomationTab('queue');
   pgAutomationNotice('Queue item updated');
   return;
  }
  const result=await fetchJSON('/api/automation/recipes',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({recipe:pgAutomationRecipeFromForm()})});
  if(!result||result.status==='error')throw new Error((result&&result.message)||'Unable to save recipe');
  pgAutomationNotice('Recipe saved');
  await pgAutomationRefresh();
 }catch(e){pgAutomationNotice(e.message||'Unable to save recipe',true);}
}

function pgAutomationRenderRecipeList(){
 const list=document.getElementById('pgAutomationRecipeList');
 const select=document.getElementById('pgAutomationRecipeSelect');
 if(select){select.innerHTML=pgAutomation.recipes.map((recipe,i)=>'<option value="'+i+'">'+pgAutomationEscape(recipe.name||recipe.id||('Recipe '+(i+1)))+'</option>').join('');}
 if(!list)return;
 list.innerHTML=pgAutomation.recipes.length?pgAutomation.recipes.map((recipe,i)=>'<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:7px 0;border-top:1px solid var(--border)"><span>'+pgAutomationEscape(recipe.name||recipe.id)+'</span><span><button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationEditRecipe('+i+')">Edit</button> <button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationDuplicateRecipe('+i+')">Duplicate</button> <button class="btn btn-sm btn-danger" type="button" onclick="pgAutomationDeleteRecipe('+i+')">Delete</button></span></div>').join(''):'<div style="color:var(--text2)">No saved recipes. Build one above, then add it to a queue.</div>';
}

function pgAutomationEditRecipe(index){pgAutomationFillRecipe(pgAutomation.recipes[index]);pgAutomationTab('recipes');}

function pgAutomationDuplicateRecipe(index){
 const source=pgAutomation.recipes[index];
 if(!source)return;
 const copy=pgAutomationClone(source)||{};
 delete copy.id;
 const modes=pgAutomationModes(copy.signal_format||'sdr');
 const alternate=modes.find(mode=>mode!==copy.picture_mode);
 if(alternate)copy.picture_mode=alternate;
 copy.name=(copy.name||'Automation item')+' (copy)';
 pgAutomation.editingRecipe=null;
 pgAutomation.supportedKeys=[];
 pgAutomation.supportedSignal='';
 pgAutomation.supportedPictureMode='';
 pgAutomationFillRecipe(copy);
 pgAutomationTab('recipes');
 pgAutomationNotice('Duplicated recipe. Choose a different TV-supported picture mode if needed.');
}

async function pgAutomationDeleteRecipe(index){
 const recipe=pgAutomation.recipes[index];
 if(!recipe||!recipe.id)return;
 const result=await fetchJSON('/api/automation/recipes/'+encodeURIComponent(recipe.id)+'/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Unable to delete recipe',true);return;}
 await pgAutomationRefresh();
}

function pgAutomationQueueAdd(){
 const select=document.getElementById('pgAutomationRecipeSelect');
 const recipe=select&&pgAutomation.recipes[Number(select.value)];
 try{pgAutomation.queue.items.push(recipe?pgAutomationClone(recipe):pgAutomationRecipeFromForm());pgAutomationRenderQueue();pgAutomationTab('queue');}
 catch(e){pgAutomationNotice(e.message||'Unable to add queue item',true);}
}

function pgAutomationRenderQueue(){
 const name=document.getElementById('pgAutomationQueueName');
 if(name)name.value=pgAutomation.queue.name||'TV calibration queue';
 const list=document.getElementById('pgAutomationQueueItems');
 if(!list)return;
 list.innerHTML=pgAutomation.queue.items.length?pgAutomation.queue.items.map((item,i)=>'<div style="display:grid;grid-template-columns:32px 1fr auto;gap:8px;align-items:center;padding:8px 0;border-top:1px solid var(--border)"><span style="color:var(--text2)">'+(i+1)+'</span><span><strong>'+pgAutomationEscape(item.name||'Item '+(i+1))+'</strong><br><small style="color:var(--text2)">'+pgAutomationEscape((item.signal_format||'sdr').toUpperCase())+' · '+pgAutomationEscape(item.picture_mode||'')+'</small></span><span><button class="btn btn-sm btn-secondary" type="button"'+(i===0?' disabled':'')+' onclick="pgAutomationQueueMove('+i+',-1)">↑</button> <button class="btn btn-sm btn-secondary" type="button"'+(i===pgAutomation.queue.items.length-1?' disabled':'')+' onclick="pgAutomationQueueMove('+i+',1)">↓</button> <button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationQueueEdit('+i+')">Edit</button> <button class="btn btn-sm btn-danger" type="button" onclick="pgAutomationQueueRemove('+i+')">Remove</button></span></div>').join(''):'<div style="color:var(--text2)">Queue is empty. Add a saved recipe or save the current recipe first.</div>';
}

function pgAutomationQueueEdit(index){pgAutomationFillRecipe(pgAutomation.queue.items[index]);pgAutomation.editingQueueIndex=index;pgAutomationTab('recipes');}

function pgAutomationQueueRemove(index){pgAutomation.queue.items.splice(index,1);pgAutomationRenderQueue();}

function pgAutomationQueueMove(index,delta){
 const target=index+delta;
 if(target<0||target>=pgAutomation.queue.items.length)return;
 const moved=pgAutomation.queue.items.splice(index,1)[0];
 pgAutomation.queue.items.splice(target,0,moved);
 pgAutomationRenderQueue();
}

async function pgAutomationQueueSave(){
 const name=document.getElementById('pgAutomationQueueName');
 if(name)pgAutomation.queue.name=name.value||'TV calibration queue';
 if(pgAutomation.editingQueueIndex!=null){
  try{const item=pgAutomationRecipeFromForm();pgAutomation.queue.items[pgAutomation.editingQueueIndex]=item;pgAutomation.editingQueueIndex=null;pgAutomationRenderQueue();pgAutomationTab('queue');}catch(e){pgAutomationNotice(e.message||'Unable to edit queue item',true);return;}
 }
 const result=await fetchJSON('/api/automation/queues',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({queue:pgAutomation.queue})});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Unable to save queue',true);return;}
 pgAutomation.queue=result.queue||pgAutomation.queue;
 pgAutomationNotice('Queue saved');
 await pgAutomationRefresh();
}

function pgAutomationRenderReadiness(result){
 const box=document.getElementById('pgAutomationReadiness');
 if(!box)return;
 if(!result){box.textContent='Readiness request failed';return;}
 const checks=result.checks||[];
 box.innerHTML='<div style="font-weight:700;margin-bottom:5px;color:'+(result.ready?'var(--green)':'var(--red)')+'">'+pgAutomationEscape(result.message||'Readiness result')+'</div>'+checks.map(check=>'<div style="padding:3px 0;color:'+(check.ok?'var(--green)':check.level==='warning'?'var(--orange)':'var(--red)')+'">'+(check.ok?'✓':'✕')+' '+pgAutomationEscape(check.message||check.name||'check')+'</div>').join('');
}

async function pgAutomationReadiness(){
 const result=await fetchJSON('/api/automation/readiness',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({items:pgAutomation.queue.items})});
 pgAutomationRenderReadiness(result);
 if(result&&result.ready&&Array.isArray(result.items))pgAutomation.queue.items=result.items;
}

async function pgAutomationStart(){
 if(!pgAutomation.queue.items.length){pgAutomationNotice('Add at least one queue item before starting',true);return;}
 const result=await fetchJSON('/api/automation/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({queue:pgAutomation.queue})});
 if(!result||result.status==='error'||!result.run_id){pgAutomationRenderReadiness(result);pgAutomationNotice((result&&result.message)||'Automation did not start',true);return;}
 pgAutomationNotice('Automation started: '+result.run_id);
 await pgAutomationRefresh();
 pgAutomationTab('live');
}

function pgAutomationCurrentRun(){return pgAutomation.current&&pgAutomation.current.run?pgAutomation.current.run:null;}

async function pgAutomationControl(action){
 const run=pgAutomationCurrentRun();
 if(!run){pgAutomationNotice('There is no active automation run',true);return;}
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(run.id)+'/control/'+action,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Automation control failed',true);return;}
 pgAutomationNotice(result.message||('Automation '+action+' requested'));
 await pgAutomationPollLive();
}

async function pgAutomationEditActiveQueue(){
 const run=pgAutomationCurrentRun();
 if(!run){pgAutomationNotice('There is no active automation run',true);return;}
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(run.id)+'/edit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({items:pgAutomation.queue.items})});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Unable to update queued items',true);return;}
 pgAutomationNotice('Pending queue items updated');
 await pgAutomationPollLive();
}

function pgAutomationRenderLiveRun(run,execution){
 const state=document.getElementById('pgAutomationState');
 const live=document.getElementById('pgAutomationLive');
 const status=run&&run.status?run.status:'idle';
 if(state){state.textContent=status.replace(/-/g,' ');state.style.color=status==='complete'?'var(--green)':status==='failed'?'var(--red)':status==='idle'?'var(--text2)':'var(--orange)';}
 if(!live)return;
 if(!run){live.textContent='No active run.';return;}
 const active=run.active_item!=null?Number(run.active_item):-1;
 const items=Array.isArray(run.items)?run.items:[];
 const activeItem=active>=0&&items[active]?items[active]:null;
 const heartbeat=Number(run.heartbeat||0);
 const heartbeatAge=run.heartbeat_age!=null?Math.max(0,Number(run.heartbeat_age)||0)+'s ago':heartbeat?Math.max(0,Math.round(Date.now()/1000-heartbeat))+'s ago':'unknown';
 const checkpoint=run.last_checkpoint||run.checkpoint||'none';
 live.innerHTML='<div style="margin-bottom:8px"><strong>'+pgAutomationEscape(run.queue_name||'Automation queue')+'</strong> · '+pgAutomationEscape(status)+' · '+pgAutomationEscape(run.id||'')+'</div>'
  +'<div style="margin-bottom:8px;color:var(--text2)">'+(active>=0?'Current item '+(active+1)+' of '+items.length+' · '+pgAutomationEscape(run.active_stage||'working'):'No active item')+(execution&&execution.pid?' · runner '+pgAutomationEscape(execution.pid):'')+'</div>'
  +'<div style="margin-bottom:8px;color:var(--text2)">Checkpoint: '+pgAutomationEscape(checkpoint)+' · Heartbeat: '+pgAutomationEscape(heartbeatAge)+'</div>'
  +'<div>'+items.map((item,i)=>'<div style="display:flex;justify-content:space-between;gap:8px;padding:5px 0;border-top:1px solid var(--border)"><span>'+(i+1)+'. '+pgAutomationEscape(item.name||item.picture_mode||'Item')+'</span><span style="color:'+(item.status==='complete'||item.status==='complete-with-warnings'?'var(--green)':item.status==='failed'?'var(--red)':'var(--text2)')+'">'+pgAutomationEscape(item.status||'queued')+(i===active?' · '+pgAutomationEscape(run.active_stage||'working'):'')+'</span></div>').join('')+'</div>'
  +'<div class="btn-row" style="margin-top:8px"><button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationEditActiveQueue()">Save pending queue edits</button></div>';
}

async function pgAutomationPollLive(){
 const result=await fetchJSON('/api/automation/runs/current',{_quiet:true,_timeoutMs:5000});
 pgAutomation.current=result;
 pgAutomationRenderLiveRun(result&&result.run,result&&result.execution);
 if(result&&result.run&&['starting','running','paused','stopping','interrupted'].indexOf(result.run.status)>=0){
  if(!pgAutomation.liveTimer)pgAutomation.liveTimer=setTimeout(async()=>{pgAutomation.liveTimer=null;await pgAutomationPollLive();},3000);
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
 if(warningList.length)details.push(warningList.length+' warnings: '+pgAutomationEscape(warningList.join(', ')));
 if(apply)details.push('Apply to all: '+pgAutomationEscape(apply.outcome||apply.status||'unverified'));
 if(quality&&quality.warnings&&quality.warnings.length)details.push('Quality limits: '+quality.warnings.length+' miss'+(quality.warnings.length===1?'':'es'));
 if(panel&&panel.warning)details.push(pgAutomationEscape(panel.warning));
 const base=item&&item.item_number!=null?item.item_number:index;
 return '<div style="padding:8px 0;border-top:1px solid var(--border)"><strong>Item '+(index+1)+': '+pgAutomationEscape(item&&item.name||item&&item.picture_mode||'')+'</strong><br><span style="color:var(--text2)">'+details.join(' · ')+'</span><br><a href="/api/automation/runs/'+encodeURIComponent(pgAutomation.currentHistoryRunId||'')+'/artifact/items/'+base+'/settings-checks.ndjson" target="_blank" style="color:var(--link)">Settings checks</a></div>';
}

async function pgAutomationBuildHistoryReport(run){
 const target=document.getElementById('pgAutomationHistoryReport');
 if(!target||typeof meterFullAutoCalBuildSnapshotReportSections!=='function')return;
 if(pgAutomation.reportBusy)return;
 pgAutomation.reportBusy=true;
 const entries=[];
 const runId=String(run&&run.id||pgAutomation.currentHistoryRunId||'');
 const seriesRequests=[];
 (run.items||[]).forEach((item,index)=>{
  const calibration=item&&item.calibration||{};
  const grey=calibration['grey-state'];
  if(grey&&Array.isArray(grey.readings)&&grey.readings.length)entries.push({title:'Item '+(index+1)+' Calibration Greyscale',snapshot:grey});
  ['pre','post'].forEach(stage=>{
   ['greyscale-21','colors-30','saturations-24'].forEach(key=>{
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
  const html=await meterFullAutoCalBuildSnapshotReportSections(entries);
  target.innerHTML=html||'<div style="color:var(--text2)">No graph data was saved for this run.</div>';
 }catch(e){target.innerHTML='<div style="color:var(--red)">Unable to render saved graphs: '+pgAutomationEscape(e.message||e)+'</div>';}
 finally{pgAutomation.reportBusy=false;}
}

async function pgAutomationDeleteRun(index){
 const run=pgAutomation.history[index];
 if(!run)return;
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(run.id)+'/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Unable to delete run',true);return;}
 const detail=document.getElementById('pgAutomationHistoryDetail');if(detail)detail.innerHTML='';
 await pgAutomationRefresh();
}

function pgAutomationTab(tab){
 ['recipes','queue','live','history'].forEach(name=>{const el=document.getElementById('pgAutomationTab'+name.charAt(0).toUpperCase()+name.slice(1));if(el)el.style.display=name===tab?'':'none';});
 if(tab==='history')pgAutomationRenderHistoryList();
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
 pgAutomationRenderQueue();
 pgAutomationRenderHistoryList();
 pgAutomation.current=responses[3];
 pgAutomationRenderLiveRun(responses[3]&&responses[3].run,responses[3]&&responses[3].execution);
 const active=responses[3]&&responses[3].run&&['starting','running','paused','stopping','interrupted'].indexOf(responses[3].run.status)>=0;
 if(active&&!pgAutomation.liveTimer)pgAutomation.liveTimer=setTimeout(async()=>{pgAutomation.liveTimer=null;await pgAutomationPollLive();},3000);
}

function pgAutomationInit(){
 if(pgAutomation.loaded)return;
 pgAutomation.loaded=true;
 pgAutomationModesChanged();
 pgAutomationNewRecipe();
 pgAutomationRefresh();
}

setTimeout(pgAutomationInit,0);
