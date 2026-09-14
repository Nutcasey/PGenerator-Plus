// Read-only Calibration workspace follows automation, not manual cached sweeps.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1000});
  await page.setContent('<div id="meterCard"><button id="manualStart" onclick="window.manualWrites++">Start manual</button></div>'+fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.html'),'utf8'));
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.js'),'utf8').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  await page.evaluate(()=>{
   window.manualWrites=0;window.calls=[];window.rendered=[];
   window.data={status:'ok',run_id:'observer-run',run_status:'running',active_stage:'greyscale-done',fetched_at:Date.now()/1000,item:{name:'SDR Filmmaker',signal_format:'sdr',status:'running'},checks:[],snapshots:[{key:'greyscale-21',phase:'pre',snapshot:{readings:[{Y:999}]}}],live:{key:'grey',phase:'calibration',snapshot:{readings:[{Y:100}],target_gamma:'bt1886'}}};
   window.fetchJSON=async(url,options)=>{calls.push({url,method:options?.method||'GET'});return JSON.parse(JSON.stringify(data));};
   window.meterFullAutoCalBuildSnapshotReportSections=async entries=>{rendered=entries;return '<p>'+entries.map(e=>e.title+' Y='+e.snapshot.readings[0].Y).join(' | ')+'</p>';};
   pgAutomation.current={run:{id:'observer-run',status:'running',active_item:0,active_stage:'greyscale-done',items:[{name:'SDR Filmmaker'},{name:'HDR Filmmaker'}],worker_status:{current_name:'Reading 2.3%',current_step:33,total_steps:34}}};
   pgAutomation.liveSelection={runId:'observer-run',index:1};pgAutomation.followLive=false;
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  const ready=()=>page.waitForFunction(()=>pgAutomation.jobViews.calibration?.data&&!pgAutomation.jobViews.calibration.loading&&!pgAutomation.reportBusy);
  await ready();
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.calibration.index),0,'follows active job independently of Automation inspection selection');
  assert.equal(await page.$eval('#meterCard',el=>el.inert&&getComputedStyle(el).display==='none'),true,'manual calibration controls are hidden and inert');
  assert.deepEqual(await page.evaluate(()=>rendered.map(e=>e.snapshot.readings[0].Y)),[100],'live 1D data replaces pre-read graphs');
  assert.match(await page.$eval('#pgAutomationCalibrationProgress',el=>el.textContent),/Job 1 of 2.*Reading 2.3%.*33 \/ 34/,'current job and worker progress are visible');
  assert.equal(await page.$eval('#pgAutomationCalibrationBadge',el=>el.textContent),'Automation active · Read only','active automation ownership is clearly labelled');
  await page.evaluate(()=>{pgAutomation.current.run.status='paused';pgAutomationSyncCalibrationView(pgAutomation.current.run);});
  assert.equal(await page.$eval('#pgAutomationCalibrationBadge',el=>el.textContent),'Automation paused · Read only','badge does not imply a paused batch is actively calibrating');
  await page.evaluate(()=>{pgAutomation.current.run.status='running';pgAutomationSyncCalibrationView(pgAutomation.current.run);});
  await page.evaluate(()=>pgAutomationReleaseCalibrationView());
  assert.equal(await page.$eval('#meterCard',el=>el.inert),true,'cannot unlock manual controls during a batch');
  await page.evaluate(()=>{
   pgAutomation.current.run.active_stage='volume-done';data.active_stage='volume-done';data.live={key:'3d',phase:'calibration',snapshot:{readings:[]}};
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-graphs]',el=>el.textContent),/No measurements for the current stage/,'new stage waits without relabelling old graphs');
  await page.evaluate(async()=>{data.live.snapshot.readings=[{Y:200}];await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);});
  assert.match(await page.evaluate(()=>rendered[0].title),/Live calibration · 3D LUT/,'3D stage automatically selects profile charts');
  assert.equal(await page.evaluate(()=>rendered[0].snapshot.type),'colors','profile uses shared colour chart renderer');
  await page.evaluate(()=>{
   pgAutomation.current.run.active_stage='post-readings-done';data.active_stage='post-readings-done';data.live={key:'saturations-24',phase:'post',snapshot:{readings:[{Y:300}]}};
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.match(await page.evaluate(()=>rendered[0].title),/After \(measuring\).*Saturation/,'post-read stage follows the active sweep');
  await page.evaluate(async()=>{
   const original=fetchJSON;fetchJSON=async()=>{throw new Error('Network lost');};
   await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);fetchJSON=original;
  });
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-error]',el=>el.textContent),/last received, not confirmed current/,'lost connection labels old measurements stale');
  assert.equal(await page.$eval('#meterCard',el=>el.inert),true,'connection loss does not unlock controls');
  await page.evaluate(()=>{
   pgAutomation.current.run.active_item=1;pgAutomation.current.run.active_stage='greyscale-done';data.active_stage='greyscale-done';data.item={name:'HDR Filmmaker',signal_format:'hdr10'};data.live={key:'grey',phase:'calibration',snapshot:{readings:[{Y:400}]}};
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.calibration.index),1,'automatically follows the next job');
  assert.deepEqual(await page.evaluate(()=>rendered.map(e=>e.snapshot.readings[0].Y)),[400],'previous job graphs do not leak');
  assert.deepEqual(await page.evaluate(()=>{
   const d={run_status:'running',active_stage:'volume-done',item:{signal_format:'dv'},snapshots:[{phase:'pre',key:'colors-30',snapshot:{readings:[{Y:999}]}}],live:{phase:'calibration',key:'dv-profile',snapshot:{readings:[{Y:123}]}}};
   const live=pgAutomationCalibrationSnapshots(d);d.active_stage='volume-settings-verified';
   return {key:live[0].key,readings:live[0].snapshot.readings.length,between:pgAutomationCalibrationSnapshots(d).length};
  }),{key:'dv-profile',readings:1,between:0},'Dolby Vision follows its profile and verification stages never borrow pre-read graphs');
  await page.evaluate(()=>{
   pgAutomation.current.run.status='complete';pgAutomation.current.run.active_item=2;pgAutomation.current.run.active_stage='item-complete';data.run_status='complete';data.active_stage='item-complete';data.live=null;data.snapshots=[{key:'greyscale-21',phase:'post',snapshot:{readings:[{Y:500}]}}];
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-graphs]',el=>el.textContent),/After.*500/,'terminal state retains final results');
  assert.equal(await page.$eval('#pgAutomationCalibrationBadge',el=>el.textContent),'Automation complete · Read only','finished results are not labelled as active automation');
  await page.setViewport({width:390,height:844});
  assert.equal(await page.$eval('#pgAutomationCalibrationCard',el=>el.scrollWidth<=el.clientWidth+1),true,'observer fits narrow screens');
  await page.click('#pgAutomationCalibrationRelease');
  assert.equal(await page.$eval('#meterCard',el=>el.inert),false,'manual controls restored only after terminal run and explicit return');
  assert.equal(await page.$eval('#pgAutomationCalibrationCard',el=>el.style.display),'none','observer closes cleanly');
  assert.equal(await page.evaluate(()=>manualWrites),0,'observation never triggers manual calibration');
  assert.equal(await page.evaluate(()=>calls.every(c=>c.method==='GET'&&/^\/api\/automation\/runs\/observer-run\/jobs\/[01]$/.test(c.url))),true,'observer fetches job data only, never worker-control endpoints');
  assert.deepEqual(errors,[]);
  console.log('Calibration automation observer checks passed');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
