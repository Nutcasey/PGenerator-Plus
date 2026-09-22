// Offline report operation: advance readings, fold/reopen, resume and change jobs.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../../usr/share/PGenerator')+'/';
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1000});
  await page.setContent(fs.readFileSync(root+'webui-automation.html','utf8'));
  await page.addScriptTag({content:fs.readFileSync(root+'webui-automation.js','utf8').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  const workspace=fs.readFileSync(root+'webui-workspace.js','utf8');
  await page.addScriptTag({content:workspace.match(/async function meterFullAutoCalBuildSnapshotReportSections\([^]*?\n\}/)[0]});
  await page.addScriptTag({content:workspace.match(/function meterLiveResolveStatusMark\([^]*?\n\}/)[0]});
  await page.evaluate(()=>{
   window.draws=[];window.fetches=0;
   Object.assign(window,{meterActiveSeriesKey:'manual',_selectedColorReadingName:null,_colorDetailPinned:false,meterCurrentPatchStep:null,meterSelectedThumbIre:null,
    meterSeriesCache:{},meterFullAutoCalCloneValue:structuredClone,meterSeriesSnapshotHasReadings:s=>!!s.readings?.length,
    meterRecoverSeries:s=>{window.meterSeriesSteps=s.steps;window.meterReadings=s.readings;},
    meterRestoreSeriesFromCache:()=>{window.meterSeriesSteps=[{name:'manual 50%',ire:50}];window.meterReadings=[];},
    meterPrepareCurrentSeriesForReport:async()=>{},meterPersistSeriesCache:()=>{},
    meterTargetChromaticityForReading:()=>({x:.3127,y:.329}),meterReadingIsRealMeasurement:r=>r.Y!=null,
    meterLiveMarkSet:mark=>{window.liveMark=mark;},meterLiveMark:()=>window.liveMark});
   window.data={status:'ok',run_id:'review',run_status:'running',active_stage:'greyscale-done',fetched_at:Date.now()/1000,
    item:{name:'SDR',signal_format:'sdr',status:'running'},checks:[],snapshots:[],
    live:{key:'grey',phase:'calibration',snapshot:{steps:[{name:'5%',ire:5},{name:'10%',ire:10}],readings:[{name:'5%',ire:5,Y:1}]}}};
   window.fetchJSON=async()=>{fetches++;return structuredClone(data);};
   window.meterBuildCurrentSeriesReportSection=(title,opts={})=>{
    const count=meterReadings.length,average=meterReadings.reduce((sum,r)=>sum+r.Y,0)/count;
    if(!opts.summaryOnly)draws.push({key:opts.key,count});
    return '<section class="report-section" data-report-key="'+opts.key+'"><div class="report-section-meta">'+count+' readings captured</div><div class="report-summary"><div class="report-stat"><span class="report-stat-label">Average ΔE</span><span class="report-stat-value">'+average+'</span></div></div>'+(opts.summaryOnly?'':'<div class="report-chart-card" data-chart-key="rgb-balance"><div class="report-chart-title">RGB balance</div><div data-rendered-count="'+count+'">Chart</div></div>')+'</section>';
   };
   pgAutomation.current={run:{id:'review',status:'running',active_item:0,active_stage:'greyscale-done',items:[data.item],worker_status:{current_name:'10%',current_step:2,total_steps:26}}};
   pgAutomation.tab='live';pgAutomationEl('TabLive').style.display='';pgAutomationRenderLiveRun(pgAutomation.current.run);
  });
  await page.waitForFunction(()=>pgAutomation.jobViews.live?.data&&!pgAutomation.reportBusy&&!pgAutomation.jobViews.live.loading);
  const snapshot=()=>page.evaluate(()=>({verdict:document.querySelector('[data-job-verdict]').textContent,count:document.querySelector('[data-rendered-count]')?.dataset.renderedCount,draws}));
  assert.equal((await snapshot()).verdict,'1Average ΔE1Readings');
  assert.deepEqual(await page.evaluate(()=>({ire:liveMark.ire,phase:liveMark.phase,manual:meterSeriesSteps[0].name})),{ire:10,phase:'pending',manual:'manual 50%'},'marker uses the report series after manual globals are restored');
  // A partially rebuilt section must remain renderable when its body returns.
  assert.deepEqual(await page.evaluate(async()=>{
   const section=document.querySelector('details.auto-section-running'),body=section.querySelector('.auto-section-body');
   delete section.dataset.chartsReady;body.remove();
   await pgAutomationRenderSectionCharts('live',section);
   const skipped={busy:section.dataset.chartsBusy||'',reportBusy:pgAutomation.reportBusy};
   section.append(body);
   await pgAutomationRenderSectionCharts('live',section);
   return {skipped,ready:section.dataset.chartsReady,count:body.querySelector('[data-rendered-count]').dataset.renderedCount};
  }),{skipped:{busy:'',reportBusy:false},ready:'1',count:'1'},'missing body releases both render paths and the restored body renders');
  assert.deepEqual(await page.evaluate(async()=>{
   const section=document.querySelector('details.auto-section-running'),render=meterFullAutoCalBuildSnapshotReportSections;
   delete section.dataset.chartsReady;
   meterFullAutoCalBuildSnapshotReportSections=async()=>{throw new Error('simulated chart failure');};
   try{await pgAutomationRenderSectionCharts('live',section);}finally{meterFullAutoCalBuildSnapshotReportSections=render;}
   const failed={busy:section.dataset.chartsBusy||'',reportBusy:pgAutomation.reportBusy,ready:section.dataset.chartsReady||'',message:section.textContent.includes('simulated chart failure')};
   await pgAutomationRenderSectionCharts('live',section);
   return {failed,ready:section.dataset.chartsReady};
  }),{failed:{busy:'',reportBusy:false,ready:'',message:true},ready:'1'},'renderer exceptions release both busy flags and allow retry');
  assert.deepEqual(await page.evaluate(async()=>{
   const section=document.querySelector('details.auto-section-running'),style=document.body.style;
   const original=style.setProperty;let injected=false;
   style.setProperty('--automation-report-width','975px');
   delete section.dataset.chartsReady;
   style.setProperty=function(...args){
    if(!injected&&args[0]==='--automation-report-width'){injected=true;throw new Error('simulated setup failure');}
    return original.apply(this,args);
   };
   try{await pgAutomationRenderSectionCharts('live',section);}finally{style.setProperty=original;}
   const failed={busy:section.dataset.chartsBusy||'',reportBusy:pgAutomation.reportBusy,
    width:style.getPropertyValue('--automation-report-width'),rendering:document.body.classList.contains('pg-automation-report-render'),
    message:section.textContent.includes('simulated setup failure')};
   await pgAutomationRenderSectionCharts('live',section);
   style.removeProperty('--automation-report-width');
   return {failed,ready:section.dataset.chartsReady};
  }),{failed:{busy:'',reportBusy:false,width:'975px',rendering:false,message:true},ready:'1'},'setup exceptions release both busy flags, restore layout and allow retry');
  await page.evaluate(()=>{window.sectionBefore=document.querySelector('details.auto-section-running');});
  await page.evaluate(async()=>{data.live.snapshot.readings.push({name:'10%',ire:10,Y:3});await pgAutomationFetchJob('live',pgAutomation.jobViews.live);});
  await page.waitForFunction(()=>!pgAutomation.reportBusy);
  assert.equal((await snapshot()).verdict,'2Average ΔE2Readings','headline updates with measured charts');
  assert.equal((await snapshot()).count,'2');
  assert.equal(await page.evaluate(()=>liveMark.phase),'settled','new measurement settles the marker');
  assert.equal(await page.evaluate(()=>sectionBefore===document.querySelector('details.auto-section-running')),true,'refresh retains the section DOM');
  await page.click('details.auto-section-running > summary');
  await page.waitForFunction(()=>!document.querySelector('details.auto-section-running').open);
  await page.evaluate(async()=>{data.live.snapshot.readings.push({name:'15%',ire:15,Y:8});await pgAutomationFetchJob('live',pgAutomation.jobViews.live);});
  await page.click('details.auto-section-running > summary');
  await page.waitForFunction(()=>document.querySelector('details.auto-section-running').open&&!pgAutomation.reportBusy&&document.querySelector('[data-rendered-count]').dataset.renderedCount==='3');
  assert.equal((await snapshot()).verdict,'4Average ΔE3Readings','folded section still updates the headline');
  assert.equal((await snapshot()).count,'3','reopening draws the measurements received while folded');
  await page.evaluate(async()=>{
   data.checks=[{key:'brightness',verified:false,expected:50,observed:55,result:'mismatch'}];
   await pgAutomationFetchJob('live',pgAutomation.jobViews.live);
  });
  assert.match((await snapshot()).verdict,/1 unverified/,'new setting failures refresh the headline without new measurements');
  await page.setViewport({width:390,height:844});
  await page.evaluate(async()=>{
   data.run_status='stopped';data.item.status='stopped';data.live=null;
   pgAutomation.current.run.status='stopped';
   await pgAutomationFetchJob('live',pgAutomation.jobViews.live);
  });
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.live.settled),true);
  const before=await page.evaluate(()=>fetches);
  await page.evaluate(()=>{
   pgAutomation.current.run.status='running';data.run_status='running';data.item.status='running';
   data.live={key:'grey',phase:'calibration',snapshot:{steps:[{name:'10%',ire:10}],readings:[{name:'10%',ire:10,Y:5}]}};
   pgAutomation.jobViews.live.lastFetch=0;
   pgAutomationShowJob('live','review',0);
  });
  await page.waitForFunction(()=>!pgAutomation.jobViews.live.loading&&!pgAutomation.reportBusy);
  assert.ok(await page.evaluate(n=>fetches>n,before),'resumed job leaves the frozen terminal cache');
  await page.evaluate(()=>{
   pgAutomation.current.run.active_item=1;
   pgAutomation.current.run.worker_status.current_name='10%';
   pgAutomationSyncLiveMark();
  });
  assert.equal(await page.evaluate(()=>liveMark),null,'another job cannot borrow matching patch names from the previous job');
  assert.equal(await page.$('details[data-pg-live]'),null,'previous job charts stop receiving live overlays');
  assert.deepEqual(errors,[]);
  console.log('PASS missing-body/setup/renderer recovery, report headlines, folded charts, restored marker context and resumed jobs');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
