import 'dart:convert';

/// Diagnostic observers only; no account, token, message body or error payload.
String refreshDiagnostics(String origin) =>
    '''
(()=>{
 if(window!==window.top || location.origin!==${jsonEncode(origin)})return;
 const emit=(kind,value)=>{
  if(window.flutter_inappwebview?.callHandler)window.flutter_inappwebview.callHandler('ssgDiagnostic',kind,value);
 };
 const timeout=window.setTimeout;
 window.setTimeout=function(fn,delay,...args){
  if(typeof fn==='function'){
   const source=Function.prototype.toString.call(fn);
   if(/location\\.reload\\(/.test(source)){
    emit('reload-timer',String(delay));
    const original=fn;
    fn=function(...xs){emit('reload-timer-fired',String(delay));return original.apply(this,xs)};
   }
  }
  return timeout.call(this,fn,delay,...args);
 };
 const allowed=new Set(['updateAuthKeyUnregistered','updateConnectionTimeoutReload','requestGlobal','requestReconnectApi']);
 const scan=(data,depth=0)=>{
  if(typeof data==='string'){
   for(const code of ['AUTH_KEY_UNREGISTERED','SESSION_REVOKED','SESSION_EXPIRED','AUTH_KEY_DUPLICATED','AUTH_KEY_INVALID','USER_DEACTIVATED','USER_DEACTIVATED_BAN'])if(data.includes(code))emit('rpc-error',code);
   return;
  }
  if(!data || typeof data!=='object' || depth>6)return;
  if(Array.isArray(data)){data.slice(0,10).forEach(x=>scan(x,depth+1));return}
  if(data.type==='ssgRefreshDiagnostic' && typeof data.code==='string' && data.code.length<300)emit('worker-init-error',data.code);
  for(const key of ['type','@type','eventName'])if(allowed.has(data[key]))emit('worker-event',data[key]);
  for(const key of ['message','errorMessage','code']){
   if(['AUTH_KEY_UNREGISTERED','SESSION_REVOKED','SESSION_EXPIRED','AUTH_KEY_DUPLICATED','AUTH_KEY_INVALID','USER_DEACTIVATED','USER_DEACTIVATED_BAN','UNAUTHORIZED'].includes(data[key]))emit('rpc-error',data[key]);
  }
  if(data.httpCode===401)emit('rpc-status','401');
  if(data.code===401)emit('rpc-status','401');
  for(const key of ['payloads','update','updates','result','data','payload','args','error','event'])scan(data[key],depth+1);
 };
 if(window.Worker){
  window.Worker=new Proxy(window.Worker,{construct(target,args,newTarget){
   const worker=Reflect.construct(target,args,newTarget);
   worker.addEventListener('message',e=>scan(e.data));
   const post=worker.postMessage;
   worker.postMessage=function(data,...rest){
    for(const item of data?.payloads??[data])if(item?.type==='initApi')emit('init-session-present',String(!!item.args?.[0]?.sessionData));
    return post.call(this,data,...rest);
   };
   return worker;
  }});
 }
 const error=console.error;
 console.error=function(...args){
  for(const arg of args){
   if(arg && typeof arg==='object'){
    for(const key of ['name','message','errorMessage','code']){
     const text=String(arg[key]??'');
     // Report known public protocol/error categories only.
     for(const category of ['AUTH_KEY_UNREGISTERED','SESSION_REVOKED','AUTH_KEY_DUPLICATED','RPCError','TypeError','SecurityError','DataCloneError','NetworkError','AbortError','ChunkLoadError'])if(text.includes(category))emit('error-category',category);
    }
   }
  }
  return error.apply(this,args);
 };
})();
''';

const workerRefreshDiagnostics = '''
(()=>{
 const original=console.error;
 console.error=function(...args){
  const codes=[];
  for(const a of args){
   if(a && typeof a==='object'){
    for(const k of ['code','httpCode','errorMessage','name']){
     const v=String(a[k]??'');
     if(/^[A-Z][A-Z0-9_]{1,60}\$/.test(v)||/^[1-5][0-9]{2}\$/.test(v)||['TypeError','SecurityError','RPCError','Error'].includes(v))codes.push(k+':'+v);
    }
   }
  }
  if(codes.length) self.postMessage({payloads:[{type:'ssgRefreshDiagnostic',code:codes.join(',')}]});
  return original.apply(this,args);
 };
})();
''';
