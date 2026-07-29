// Log in via Dex once, then screenshot + probe both new routes.
import { spawn } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const PORT = 9226
const userDir = mkdtempSync(join(tmpdir(), 'cdp-'))
const chrome = spawn('/opt/google/chrome/chrome', ['--headless=new','--no-sandbox','--disable-gpu',`--remote-debugging-port=${PORT}`,`--user-data-dir=${userDir}`,'--no-first-run','--no-default-browser-check','--hide-scrollbars','--window-size=1440,2600'], { stdio: 'ignore' })
const sleep = (ms:number)=>new Promise(r=>setTimeout(r,ms))
let nextId=1; const pending=new Map<number,(v:any)=>void>()
async function wsUrl(){for(let i=0;i<40;i++){try{const r=await fetch(`http://localhost:${PORT}/json/new?about:blank`,{method:'PUT'});if(r.ok)return (await r.json()).webSocketDebuggerUrl}catch{}await sleep(250)}throw new Error('no cdp')}

async function main(){
  const ws=new WebSocket(await wsUrl()); await new Promise(res=>ws.addEventListener('open',res,{once:true}))
  ws.addEventListener('message',(e)=>{const m=JSON.parse(e.data as string); if(m.id&&pending.has(m.id)){pending.get(m.id)!(m);pending.delete(m.id)}})
  const send=(method:string,params:any={})=>new Promise<any>((res,rej)=>{const id=nextId++;pending.set(id,(m)=>m.error?rej(new Error(JSON.stringify(m.error))):res(m.result));ws.send(JSON.stringify({id,method,params}))})
  const ev=async(x:string)=>(await send('Runtime.evaluate',{expression:x,returnByValue:true,awaitPromise:true})).result?.value
  await send('Page.enable');await send('Runtime.enable')

  // Authenticate once via /cryptography (any protected route triggers Dex).
  await send('Page.navigate',{url:'http://localhost:5173/federated-services'}); await sleep(3500)
  if(String(await ev('document.location.href')).includes('/dex')){
    await ev(`(()=>{const l=document.querySelector('input[name=login]');const p=document.querySelector('input[name=password]');if(l)l.value='demo-user@signalloom.local';if(p)p.value='demo-user';const b=document.querySelector('#submit-login');if(b)b.click();})()`)
    await sleep(4500)
  }

  const routes=[
    {url:'http://localhost:5173/federated-services',out:'/tmp/federated-services.png',want:['Federated Services','Trust Zones','Federations','payments-api','cofide-sdk-go']},
    {url:'http://localhost:5173/collusion-access',out:'/tmp/collusion-access.png',want:['Collusion','Analysis Phases','Collusion Pairs','role:flux-reconciler','Remediation Priorities']},
  ]
  const results:any[]=[]
  for(const r of routes){
    await send('Page.navigate',{url:r.url})
    let heading=''
    for(let i=0;i<30;i++){await sleep(700);heading=await ev(`document.querySelector('h1')?document.querySelector('h1').textContent:''`);if(heading)break}
    const body=String(await ev('document.body?document.body.innerText:""'))
    const nav=String(await ev(`(()=>{const n=document.querySelector('nav');return n?n.innerText:''})()`))
    const bgOk=r.url.includes('collusion')?await ev(`(()=>{const b=document.querySelector('[data-testid=ktp-graph-bg]');return b?getComputedStyle(b).backgroundImage.includes('ktp-collusion-graph'):false})()`):null
    const h=await ev('Math.min(document.body.scrollHeight,3200)')
    await send('Emulation.setDeviceMetricsOverride',{width:1440,height:Math.max(900,h),deviceScaleFactor:1,mobile:false})
    const shot=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true})
    await Bun.write(r.out,Buffer.from(shot.data,'base64'))
    results.push({url:r.url,heading,navHasFederated:nav.includes('Federated Services'),navHasCollusion:nav.includes('Collusion & Access'),present:r.want.filter(w=>body.includes(w)),bgImageApplied:bgOk,screenshot:r.out})
  }
  console.log('VERIFY_REPORT='+JSON.stringify(results,null,2))
  chrome.kill();process.exit(0)
}
main().catch(e=>{console.error('VERIFY_ERROR',e);chrome.kill();process.exit(1)})
