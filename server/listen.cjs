const WebSocket=require("ws"), crypto=require("crypto");
const KEY=Buffer.from("ZPNwJuhkRxBZOXKldwtWRI3M/vqjhQIgkPAz7kuWyD4=","base64");
const ws=new WebSocket("ws://118.89.71.154:443");
function dec(b64){const b=Buffer.from(b64,"base64");const d=crypto.createDecipheriv("aes-256-gcm",KEY,b.subarray(0,12));
  d.setAuthTag(b.subarray(12,28));return JSON.parse(Buffer.concat([d.update(b.subarray(28)),d.final()]).toString());}
ws.on("open",()=>ws.send(JSON.stringify({t:"join",room:"0cb126b06eed8375",role:"client"})));
ws.on("message",raw=>{
  let m; try{m=JSON.parse(raw.toString())}catch{return}
  if(m.t!=="data"||!m.enc)return;
  let msg; try{msg=dec(m.enc)}catch{return}
  if(msg.type==="sent") console.log(`[${new Date().toLocaleTimeString()}] sent回执: ok=${msg.ok} error="${msg.error||""}" id=${(msg.id||"").slice(0,8)}`);
  if(msg.type==="agentState") console.log(`[${new Date().toLocaleTimeString()}] agentState: ${msg.state} @ ${(msg.cwd||"").split("/").pop()}`);
});
setTimeout(()=>{console.log("(监听结束)");process.exit(0);},100000);
