import { spawn } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const PORT = 9225
const userDir = mkdtempSync(join(tmpdir(), 'cdp-'))
const chrome = spawn('/opt/google/chrome/chrome', ['--headless=new','--no-sandbox','--disable-gpu',`--remote-debugging-port=${PORT}`,`--user-data-dir=${userDir}`,'--no-first-run','--window-size=1440,2000'], { stdio: 'ignore' })
const sleep = (ms:number)=>new Promise(r=>setTimeout(r,ms))
let nextId=1; const pending=new Map<number,(v:any)=>void>()
async function wsUrl(){for(let i=0;i<40;i++){try{const r=await fetch(`http://localhost:${PORT}/json/new?about:blank`,{method:'PUT'});if(r.ok)return (await r.json()).webSocketDebuggerUrl}catch{}await sleep(250)}throw new Error('no cdp')}
async function main(){
  const ws=new WebSocket(await wsUrl()); await new Promise(res=>ws.addEventListener('open',res,{once:true}))
  ws.addEventListener('message',(e)=>{const m=JSON.parse(e.data as string); if(m.id&&pending.has(m.id)){pending.get(m.id)!(m);pending.delete(m.id)}})
  const send=(method:string,params:any={})=>new Promise<any>((res,rej)=>{const id=nextId++;pending.set(id,(m)=>m.error?rej(new Error(JSON.stringify(m.error))):res(m.result));ws.send(JSON.stringify({id,method,params}))})
  const ev=async(x:string)=>(await send('Runtime.evaluate',{expression:x,returnByValue:true,awaitPromise:true})).result?.value
  await send('Page.enable');await send('Runtime.enable')
  await send('Page.navigate',{url:'http://localhost:5173/cryptography'}); await sleep(4000)
  console.log('URL=',await ev('document.location.href'))
  console.log('FORM_HTML=',await ev(`(()=>{const f=document.querySelector('form');return f?f.outerHTML.slice(0,1200):'NO FORM: '+document.body.innerText.slice(0,300)})()`))
  chrome.kill();process.exit(0)
}
main().catch(e=>{console.error(e);chrome.kill();process.exit(1)})
