// Minimal Supabase query adapter for the disposable Postgres used by workflow-browser.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');

function sql(statement, params = {}, setup = false) {
  assert(process.env.PGHOST?.startsWith('/tmp/podbor-pg-sock-'), 'Use the private workflow test socket');
  const args = ['-XAtq', '-v', 'ON_ERROR_STOP=1'];
  for (const [k,v] of Object.entries(params)) args.push('-v', k + '=' + (typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v)));
  return execFileSync('psql', args, { input: (setup ? '' : 'set role service_role;\n') + statement, encoding:'utf8' }).trim();
}
function dbRead(stmt,data){const value=sql(stmt,data);return value?JSON.parse(value):null;}
function ident(value){assert.match(value,/^[a-z_][a-z0-9_]*$/);return value;}
function rpc(name,data={}) {
  assert.match(name,/^(crm_|workflow_|bot_)\w+$/);
  const args=Object.entries(data).map(([k,v])=>ident(k)+' => '+(v==null?'null':" :'"+k+"'"));
  if(name==='workflow_claim_sources')return dbRead("select coalesce(jsonb_agg(to_jsonb(j)), '[]') from workflow_claim_sources() j;");
  return dbRead('select to_jsonb('+name+'('+args.join(',')+'));',data);
}
function from(table) {
  ident(table);
  let mode='select',values={},columns='*',order='',limit='';
  const params={},filters=[];
  function bind(v){if(v===null)return 'null';const key='v'+Object.keys(params).length;params[key]=v;return ":'"+key+"'";}
  function filter(k,op,v){filters.push(ident(k)+op+bind(v));return query;}
  function run(single=false){
    try {
      const where=filters.length?' where '+filters.join(' and '):'';
      const keys=Object.keys(values).map(ident);
      let stmt;
      if(mode==='select')stmt='select '+columns+' from '+table+where+order+limit;
      else if(mode==='update')stmt='update '+table+' set '+keys.map(k=>k+'='+bind(values[k])).join(',')+where+' returning '+columns;
      else if(mode==='delete')stmt='delete from '+table+where+' returning '+columns;
      else{
        stmt='insert into '+table+' ('+keys.join(',')+') values ('+keys.map(k=>bind(values[k])).join(',')+')';
        if(mode==='upsert'){assert.equal(table,'bot_context');stmt+=' on conflict(user_id) do update set '+keys.filter(k=>k!=='user_id').map(k=>k+'=excluded.'+k).join(',');}
        stmt+=' returning '+columns;
      }
      const rows=dbRead("with records as ("+stmt+") select coalesce(jsonb_agg(to_jsonb(records)),'[]') from records;",params);
      return Promise.resolve({data:single?(rows[0]??null):rows,error:null});
    }catch(error){return Promise.resolve({data:null,error:{message:String(error.stderr||error.message)}});}
  }
  const query={
    select(cols='*'){columns=cols==='*'?'*':cols.split(',').map(k=>ident(k.trim())).join(',');return query;},
    eq(k,v){return filter(k,'=',v);},gt(k,v){return filter(k,'>',v);},
    order(k,o={}){order=' order by '+ident(k)+(o.ascending===false?' desc':' asc');return query;},
    limit(n){assert(Number.isSafeInteger(n)&&n>=0);limit=' limit '+n;return query;},
    insert(v){mode='insert';values=v;return query;},update(v){mode='update';values=v;return query;},
    delete(){mode='delete';return query;},upsert(v){mode='upsert';values=v;return query;},
    single(){return run(true);},maybeSingle(){return run(true);},then(ok,fail){return run().then(ok,fail);}
  };
  return query;
}
const db={from,rpc:async(name,args)=>{try{return {data:rpc(name,args),error:null};}catch(e){return {data:null,error:{message:String(e.stderr||e.message)}};}}};
module.exports={sql,dbRead,rpc,db};
