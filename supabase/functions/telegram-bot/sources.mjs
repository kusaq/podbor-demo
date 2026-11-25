import { boundedBytes } from './core.mjs';

export async function searchSource(job, accounts, fetcher=fetch) {
  const account=accounts[job.company] || {};
  const stock=job.source==='stock';
  if (stock ? !account.stock_token : !account.market_url) return {state:'unconfigured',results:[]};
  const url=stock ? new URL('https://api.moysklad.ru/api/remap/1.2/report/stock/all') : new URL(account.market_url);
  if (url.protocol!=='https:' || url.username || url.password) throw Error('bad_source_config');
  const model=job.model.replace(/[^\p{L}\p{N} .-]/gu,' ').trim();
  if (!model) return {state:'ready',results:[]};
  if (stock) {
    url.searchParams.set('filter','search='+model+';stockMode=positiveOnly');
    url.searchParams.set('limit','100');
  } else url.searchParams.set('model',model);
  const token=stock ? account.stock_token : account.market_token;
  const response=await fetcher(url,{headers:{Accept:'application/json','Accept-Encoding':'gzip',...(token?{Authorization:'Bearer '+token}:{})},redirect:'error',signal:AbortSignal.timeout(10000)});
  const payload=JSON.parse(new TextDecoder().decode(await boundedBytes(response,1500000)));
  if (!Array.isArray(payload.rows)) throw Error('bad_feed');
  const results=[];
  for (const row of payload.rows) {
    if (!row || typeof row.name!=='string' || !row.name.trim() || (stock && !(row.stock-row.reserve>0))) continue;
    const purchase=stock?Number(row.price)/100:Number(row.price);
    if (!stock && !['RUB','CNY','JPY','USD','EUR'].includes(row.currency||'RUB')) continue;
    results.push({title:row.name.slice(0,200),purchase:Number.isFinite(purchase)&&purchase>0?purchase:null,currency:stock?'RUB':String(row.currency||'RUB'),term:stock?'В наличии':String(row.term||'').slice(0,180),link:!stock&&/^https:\/\//i.test(row.url||'')?String(row.url).slice(0,1000):null});
    if (results.length===100) break;
  }
  return {state:'ready',results};
}
