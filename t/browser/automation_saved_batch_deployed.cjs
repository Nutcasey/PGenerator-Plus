// Read-only hardware-result audit. Never starts a run or sends TV/meter controls.
// node t/browser/automation_saved_batch_deployed.cjs http://PI RUN_ID
const assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const [base,id]=process.argv.slice(2);
if(!base||!id)throw new Error('Provide appliance URL and completed run ID');
(async()=>{
 const current=await(await fetch(base+'/api/automation/runs/current')).json();
 assert.equal(current.run.id,id);assert.match(current.run.status,/^complete/);
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[],results=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1000,deviceScaleFactor:2});
  await page.setRequestInterception(true);
  page.on('request',r=>{
   const path=new URL(r.url()).pathname;
   if(!['GET','HEAD'].includes(r.method())||/^\/api\/cec\/(?!status$)/.test(path))return r.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only audit"}'});
   return r.continue();
  });
  await page.goto(base,{waitUntil:'domcontentloaded',timeout:30000});
  await page.waitForFunction(()=>typeof pgAutomationShowJob==='function'&&pgAutomation.current?.run,{timeout:30000});
  await page.evaluate(()=>{pgSelectDesktopWorkspace('automation');pgAutomationTab('live')});
  for(let i=0;i<current.run.items.length;i++){
   await page.evaluate(({id,i})=>pgAutomationSelectJob('live',id,i),{id,i});
   await page.waitForFunction(i=>pgAutomation.jobViews.live?.index===i&&pgAutomation.jobViews.live?.data&&!pgAutomation.jobViews.live.loading&&!pgAutomation.reportBusy,i===0?{timeout:45000}:{timeout:30000},i);
   const groups=await page.$$eval('#pgAutomationLiveDetail select[aria-label="Measurement graphs"] option',es=>es.map(e=>e.value));
   assert.ok(groups.includes('greyscale'),'saved greyscale is available for job '+i);
   for(const group of groups){
    await page.evaluate(group=>pgAutomationGraphToggle('live','graphGroup',group),group);
    await page.waitForFunction(()=>!pgAutomation.reportBusy&&document.querySelectorAll('#pgAutomationLiveDetail img').length>0&&[...document.querySelectorAll('#pgAutomationLiveDetail img')].every(e=>e.complete&&e.naturalWidth>0),{timeout:30000});
    const images=await page.$$eval('#pgAutomationLiveDetail img',es=>es.map(e=>({width:e.naturalWidth,height:e.naturalHeight})));
    assert.ok(images.every(e=>e.width>0&&e.height>0),'decoded charts for job '+i+' '+group);
    results.push({job:i+1,name:current.run.items[i].name,group,charts:images.length});
   }
  }
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',readOnly:true,results,browserErrors:errors}));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
