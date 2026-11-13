const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync(require('path').join(__dirname, '..', 'index.html'),'utf8');
let code=[...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(m=>m[1]).find(t=>t.includes("'use strict'"));
new vm.Script(code);
code=code.replace(/\}\)\(\);\s*$/, 'globalThis.test = {S,A,VIEWS,render,priceState,pr,restoreDemoSettings,homeOf,isAdmin};})();');
const store=new Map(),app={innerHTML:'',querySelectorAll:()=>[],addEventListener(){},classList:{toggle(){}}};
const ctx={console,URLSearchParams,location:{search:''},document:{getElementById:id=>id==='app'?app:null},localStorage:{getItem:k=>store.get(k)||null,setItem:(k,v)=>store.set(k,v)},setTimeout:()=>0,clearTimeout(){},navigator:{clipboard:{writeText:async()=>{}}},matchMedia:()=>({matches:false})};
ctx.window={addEventListener(){},innerWidth:390,matchMedia:ctx.matchMedia};
vm.createContext(ctx);vm.runInContext(code,ctx);
const {S,A,VIEWS,render,priceState,pr}=ctx.test;
S.me={id:'337455479',name:'Админ',role:'admin'}; S.role='admin'; S.screen=ctx.test.homeOf('admin');render();assert(app.innerHTML.includes('Рабочие кабинеты'));
for(const role of ['manager','owner','supplier','admin']){A.viewCabinet(role);assert.equal(S.role,role);assert.equal(S.me.role,'admin');assert(app.innerHTML.includes('data-a="cabinets"')||role==='admin');A.cabinets();assert.equal(S.screen,'cabinets');}
S.demoAdmin=false;S.me={id:'1',role:'manager'};S.role='manager';A.viewCabinet('owner');assert.equal(S.role,'manager');
S.me={id:'1',role:'admin'}; S.role='owner';
for(const v of ['list','lead','newreq','supcheck','card','offer','approve','calls','reply','client','feedback','more','settings','supplier','access','cabinets']){S.screen=v;render();assert(app.innerHTML.length>0,v);}
for(const tab of ['tol','price','time','rate','reasons','kp','team','api','log']){S.stab=tab;assert(VIEWS.settings().length>0);}
const p=pr('p7');p.v=1;S.rule.medianEnabled=false;S.rule.marginEnabled=false;assert.equal(priceState('p7').k,'below');
A.togglePriceRule('marginEnabled');assert.equal(S.rule.marginEnabled,true);assert(store.has('podbor-demo-settings-v3-1'));
const saved=S.rule.marginEnabled; S.rule={median:5,margin:3};ctx.test.restoreDemoSettings();assert.equal(S.rule.marginEnabled,saved);
S.fName='Тест'; S.fPhone='89991234567'; S.fModel='Kia Test'; S.fBudget='4000000'; S.fConsent=true; A.leadCreate(); assert.equal(S.screen,'request'); assert(app.innerHTML.includes('Kia Test')); const key=S.requestKey; assert.equal(S.cls[key].phone,'79991234567');
S.fName='Дубль'; S.fPhone='+7 999 123 45 67'; S.fModel='Другая'; S.fBudget='3000000'; S.fConsent=true; A.leadCreate(); assert(S.toast.includes('уже есть'));
A.openStatus(key); A.stPick('lost'); A.stReason('Другое'); A.stSave(); assert(S.toast.includes('комментарий'));
S.draft.note='Причина'; A.stSave(); assert.equal(S.cls[key].status,'lost');
console.log('PASS: syntax, four cabinets, admin identity, non-admin guard, 18 screens, 9 settings tabs, cost floor and settings persistence');
