// Operate the assembled UI with local API fixtures; no appliance requests.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const puppeteer=require('puppeteer'),{execFileSync}=require('node:child_process');
const repo=path.resolve(__dirname,'../..'),root=repo+'/usr/share/PGenerator/';
const html=execFileSync('perl',['-I.','-Iusr/share/PGenerator','-e','require "webui.pm"; require "lg.pm"; print main::webui_html();'],{cwd:repo,maxBuffer:8*1024*1024}).toString();
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:390,height:844,hasTouch:true,isMobile:true});
  await page.setRequestInterception(true);
  page.on('request',r=>{
   const url=new URL(r.url());
   if(url.pathname==='/')return r.respond({contentType:'text/html',body:html});
   if(url.pathname.startsWith('/assets/')){
    const file=root+path.basename(url.pathname);
    if(fs.existsSync(file))return r.respond({contentType:file.endsWith('.js')?'application/javascript':'text/css',body:fs.readFileSync(file)});
   }
   r.respond({contentType:'application/json',body:JSON.stringify({status:'ok',run:null,queues:[],runs:[],recipes:[],items:[],settings:{},picture_settings:{},readings:[],connected:false})});
  });
  await page.goto('http://pgen.invalid/',{waitUntil:'networkidle0'});
  await page.waitForFunction(()=>!document.documentElement.hasAttribute('data-pg-booting'));
  for(const width of [320,390,844,1440]){
   await page.setViewport({width,height:1000,hasTouch:true,isMobile:width<1000});
   await page.evaluate(()=>{pgSetLayoutPreference('tablet');pgAutomationTab('queue');});
   await new Promise(r=>setTimeout(r,300));
   const check=await page.evaluate(()=>({zoom:document.querySelector('meta[name=viewport]').content,font:getComputedStyle(document.querySelector('input[type=text],select')).fontSize}));
   assert.ok(!/maximum-scale|user-scalable/.test(check.zoom));
   assert.ok(parseFloat(check.font)>=16);
   console.log('Operated assembled UI at '+width+'px: '+JSON.stringify(check));
  }
  await page.evaluate(()=>{
   document.body.insertAdjacentHTML('afterbegin','<details id="scrollProbe" class="auto-section-running" open data-pg-live><summary>Readings</summary><div id="tableProbe" tabindex="0" style="position:relative;height:180px;overflow:auto"><table>'+Array.from({length:26},(_,i)=>'<tr data-ire="'+(i*4)+'" style="height:32px"><td>'+i+'</td></tr>').join('')+'</table></div></details>');
   window.meterLiveMark=()=>({ire:80});pgAutomationMarkLiveTableRow();
  });
  await new Promise(r=>setTimeout(r,80));
  assert.ok(await page.$eval('#tableProbe',e=>e.scrollTop>100));
  // A scripted scroll pauses follow only when the browser dispatches the
  // scroll event on a later frame. Await that event, not a fixed sleep: on a
  // loaded runner the polls can otherwise win and scroll back (608 !== 0).
  const userScroll=(sel,top)=>page.$eval(sel,(e,top)=>new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>reject(new Error('no scroll event from #'+e.id)),2000);
   e.addEventListener('scroll',()=>{clearTimeout(timer);resolve();},{once:true});
   e.scrollTop=top;
  }),top);
  await userScroll('#tableProbe',0);
  await page.evaluate(()=>{for(let i=0;i<12;i++)pgAutomationMarkLiveTableRow();});
  assert.equal(await page.$eval('#tableProbe',e=>e.scrollTop),0);
  assert.equal(await page.$eval('#scrollProbe button',e=>e.hidden),false);
  await page.click('#scrollProbe button');
  await new Promise(r=>setTimeout(r,80));
  assert.ok(await page.$eval('#tableProbe',e=>e.scrollTop>100));
  assert.equal(await page.$eval('#scrollProbe button',e=>e.hidden),true);
  console.log('Manual table scrolling survives 12 live polls and resumes explicitly');
  await page.evaluate(()=>{
   document.querySelector('#scrollProbe').remove();
   window.tableFixture=(section,table)=>'<details id="'+section+'" class="auto-section-running" data-section-key="m:calibration:grey" open data-pg-live><summary>Readings</summary><div id="'+table+'" tabindex="0" style="position:relative;height:180px;overflow:auto"><table>'+Array.from({length:26},(_,i)=>'<tr data-ire="'+(i*4)+'" style="height:32px"><td>'+i+'</td></tr>').join('')+'</table></div></details>';
   document.body.insertAdjacentHTML('afterbegin','<div id="liveSlot">'+tableFixture('scrollProbe','tableProbe')+'</div><div id="observerSlot">'+tableFixture('observerProbe','observerTable')+'</div>');
   window.realJobTarget=pgAutomationJobTarget;window.realJobViews=pgAutomation.jobViews;
   pgAutomationJobTarget=view=>document.querySelector(view==='live'?'#liveSlot':'#observerSlot');
   pgAutomation.jobViews={live:{},calibration:{}};
   pgAutomationMarkLiveTableRow();
  });
  await new Promise(r=>setTimeout(r,80));
  assert.equal(await page.$$eval('.auto-live-row',els=>els.length),2,'both visible views highlight their own latest reading');
  assert.ok(await page.$eval('#tableProbe',e=>e.scrollTop>100));
  assert.ok(await page.$eval('#observerTable',e=>e.scrollTop>100));
  await userScroll('#tableProbe',0);
  await page.evaluate(()=>{
   // Width and DPR changes replace these sections in the real graph renderer.
   document.querySelector('#liveSlot').innerHTML=tableFixture('scrollProbe','tableProbe');
   document.querySelector('#observerSlot').innerHTML=tableFixture('observerProbe','observerTable');
   pgAutomationMarkLiveTableRow();
  });
  await new Promise(r=>setTimeout(r,80));
  assert.equal(await page.$eval('#tableProbe',e=>e.scrollTop),0,'rebuilding a section retains its paused follow choice');
  assert.ok(await page.$eval('#observerTable',e=>e.scrollTop>100),'other view continues following independently');
  assert.equal(await page.$eval('#scrollProbe button',e=>e.hidden),false);
  assert.equal(await page.$$eval('#scrollProbe button',els=>els.length),1,'rebuild creates one resume control');
  await page.click('#scrollProbe button');
  assert.ok(await page.$eval('#tableProbe',e=>e.scrollTop>100));
  await page.evaluate(()=>{pgAutomationJobTarget=realJobTarget;pgAutomation.jobViews=realJobViews;});
  console.log('Simultaneous views follow independently and retain their choices after section replacement');
  await page.setViewport({width:390,height:844,hasTouch:true,isMobile:true});
  await new Promise(r=>setTimeout(r,250));
  await page.evaluate(()=>{window.resizeSeen=[];window.addEventListener('resize',e=>resizeSeen.push({label:!!e.pgHeightOnlyTabletResize,trusted:e.isTrusted}));});
  await page.setViewport({width:390,height:650,hasTouch:true,isMobile:true});
  await new Promise(r=>setTimeout(r,250));
  await page.evaluate(()=>window.dispatchEvent(new Event('resize')));
  const resize=await page.evaluate(()=>resizeSeen);
  assert.ok(resize.some(e=>e.trusted&&e.label));
  assert.ok(resize.some(e=>!e.trusted&&!e.label));
  console.log('Height-only resize reaches other listeners, synthetic resize stays unlabelled');
  assert.deepEqual(errors,[]);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
