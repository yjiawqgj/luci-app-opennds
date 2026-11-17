'use strict';'require ui';'require fs';'require dom';var API_PATH='/usr/lib/opennds/opennds-cpd-api.sh';var CSS='\
.cpd-page{max-width:none;width:100%;padding:18px 4px 60px;color:var(--text,#222a31)}\
.cpd-head{padding-bottom:14px;border-bottom:1px solid var(--line,#d7dde3)}\
.cpd-head h2{font-size:18px;font-weight:650;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;margin:0}\
.cpd-head h2 .cpd-en{font-size:11.5px;font-weight:500;color:#9aa6b2}\
.cpd-desc{font-size:12.5px;color:var(--muted,#657585);margin-top:6px;line-height:1.6}\
.cpd-sec{padding:18px 0 6px}\
.cpd-sec h3{font-size:15px;font-weight:650;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;margin:0 0 6px}\
.cpd-sec h3 .cpd-en{font-size:10.5px;font-weight:500;color:#9aa6b2}\
.cpd-note{font-size:12.5px;color:var(--muted,#657585);line-height:1.65;max-width:920px}\
.cpd-warnline{font-size:12.5px;color:var(--red,#c94848);line-height:1.65}\
.cpd-warnbar{font-size:12.5px;line-height:1.6;padding:9px 12px;border:1px solid var(--amber,#b57d17);border-radius:6px;color:var(--amber,#b57d17);margin-top:8px}\
.cpd-state{font-size:11.5px;color:#9aa6b2;margin-top:8px}\
.cpd-viewer-label{margin-top:14px;font-size:12.5px;font-weight:600;color:var(--muted,#657585)}\
.cpd-viewer{margin-top:7px;max-width:100%;padding:12px 14px;border:1px solid #ccd5dd;border-radius:5px;background:#f5f7f9;box-shadow:inset 0 1px 3px rgba(28,44,58,.07)}\
.cpd-viewer pre{margin:0;background:transparent;border:0;font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:13px;line-height:1.7;color:#26323c;white-space:pre-wrap;word-break:break-all}\
.cpd-ta{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:13px;line-height:1.6;width:100%;max-width:900px;min-height:132px;padding:9px 11px;background:#fff;border:1px solid var(--line,#d7dde3);border-radius:6px;resize:vertical;color:var(--text,#222a31)}\
.cpd-ta:focus{outline:none;border-color:var(--primary,#2274a5)}\
.cpd-field{margin-top:12px}\
.cpd-field>label{display:block;font-size:13px;font-weight:600;margin-bottom:6px}\
.cpd-input{width:100%;max-width:900px;padding:8px 10px;font-size:14px;border:1px solid var(--line,#d7dde3);border-radius:6px;background:#fff;color:var(--text,#222a31)}\
.cpd-actions{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}\
.cpd-actions-right{margin-top:22px;padding-top:14px;border-top:1px solid var(--line,#d7dde3);display:flex;justify-content:flex-end;gap:8px}\
#cpd-toasts{position:fixed;right:18px;bottom:18px;z-index:600;display:flex;flex-direction:column;gap:10px;max-width:min(420px,calc(100vw - 36px))}\
.cpd-toast{background:#fff;border:1px solid #d7dde3;border-left:3px solid #2274a5;border-radius:8px;padding:11px 14px;font-size:13px;color:#222a31;box-shadow:0 6px 20px rgba(30,42,54,.12)}\
.cpd-toast.cpd-ok{border-left-color:#2e9468}\
.cpd-toast.cpd-warn{border-left-color:#b57d17}\
.cpd-toast.cpd-err{border-left-color:#c94848}\
#cpd-toasts-center{position:fixed;left:50%;bottom:26px;transform:translateX(-50%);z-index:600;pointer-events:none}\
.cpd-pill{background:rgba(28,40,52,.92);color:#fff;border-radius:999px;padding:10px 20px;font-size:13px;box-shadow:0 6px 20px rgba(30,42,54,.25);pointer-events:none;transition:opacity .25s}\
.cpd-pill.cpd-ok{background:rgba(30,94,62,.94)}\
.cpd-pill.cpd-warn{background:rgba(150,100,20,.94)}\
.cpd-pill.cpd-err{background:rgba(160,50,50,.94)}\
.cpd-statusbar{position:fixed;left:50%;top:56px;transform:translateX(-50%);z-index:700;display:none;align-items:center;gap:12px;padding:9px 14px;border-radius:8px;background:#fff;border:1px solid #d7dde3;border-left:3px solid #2274a5;box-shadow:0 6px 20px rgba(30,42,54,.16);font-size:13px;color:#222a31;max-width:min(720px,calc(100vw - 40px))}\
.cpd-statusbar.cpd-ok{border-left-color:#2e9468}\
.cpd-statusbar.cpd-warn{border-left-color:#b57d17}\
.cpd-statusbar.cpd-err{border-left-color:#c94848}\
.cpd-sb-text{flex:1 1 auto;line-height:1.5}\
.cpd-sb-count{font-family:ui-monospace,Consolas,monospace;font-size:11.5px;color:#8a97a3;min-width:22px;text-align:right}\
.cpd-sb-x{border:0;background:transparent;cursor:pointer;font-size:16px;line-height:1;color:#8a97a3;padding:0 2px}\
.cpd-sb-x:hover{color:#222a31}\
.cpd-badge{font-size:11px;color:#2e9468;margin-left:6px}\
.cpd-tab{font-family:inherit;font-size:13px;line-height:1.4;padding:9px 14px;border:0;border-bottom:2px solid transparent;background:transparent!important;cursor:pointer;color:inherit;margin-bottom:-1px;outline:none!important;box-shadow:none!important}\
.cpd-tab:hover,.cpd-tab:focus,.cpd-tab:active{background:transparent!important;outline:none!important;box-shadow:none!important;border-top:0;border-left:0;border-right:0}\
.cpd-tab.on{font-weight:700;border-bottom-color:#2274a5}\
@media (max-width:640px){.cpd-ta{font-size:16px}.cpd-actions .cbi-button,.cpd-actions .btn{flex:1 1 30%}}\
';function ensureStyle(){if(document.getElementById('cpd-style'))return;var st=document.createElement('style');st.id='cpd-style';st.textContent=CSS;document.head.appendChild(st);}
function ensureToasts(){var c=document.getElementById('cpd-toasts');if(!c){c=document.createElement('div');c.id='cpd-toasts';c.setAttribute('aria-live','polite');document.body.appendChild(c);}
return c;}
var CPD=L.Class.extend({api:function(page,subcmd,args){args=args||[];return fs.exec(API_PATH,[page,subcmd].concat(args)).then(function(res){var j=null;try{j=JSON.parse(res.stdout);}catch(e){}
if(!j){return Promise.reject({error:(res.stderr||res.stdout||'后端无输出（脚本异常）')});}
return j;},function(e){return Promise.reject({error:(e&&e.message)?e.message:'调用后端失败'});});},apiConfirmable:function(page,subcmd,args){var self=this;return self.api(page,subcmd,args).then(function(j){if(j.error==='need_confirm'){return new Promise(function(resolve){self.modal(_('openNDS 已停用'),[E('p',{},_('openNDS 当前处于停用状态。继续应用将同时启用它并重启服务：所有设备会短暂断线，'+'未认证的设备将被重新挡在门户外。确定继续？')),E('div',{'style':'margin-top:18px;display:flex;justify-content:flex-end;gap:8px'},[E('button',{'class':'btn cbi-button','click':function(){ui.hideModal();}},_('取消')),E('button',{'class':'btn cbi-button cbi-button-positive','click':function(){ui.hideModal();resolve(self.api(page,subcmd,args.concat(['confirm_enable=1'])));}},_('确认'))])]);}).then(function(j2){if(j2&&j2.enabled_by_apply===1){self.toast(_('openNDS 已同时启用'),'warn');}
return j2;});}
return j;});},showErrors:function(errors){var self=this;(errors||[]).forEach(function(e){self.toast((e.line>0?_('第 %s 行：').format(e.line):'')+e.msg,'err');});},showWarnings:function(ws){var self=this;(ws||[]).forEach(function(w){self.toast(w,'warn');});},notifyKinds:{ok:'info',warn:'warning',err:'error','':'info'},notify:function(msg,kind){var self=this;var k=self.notifyKinds[kind===undefined?'':kind]||'info';if(typeof ui.addNotification==='function'){ui.addNotification(null,E('p',{},msg),k);return true;}
return self.statusBar(msg,kind);},toast:function(msg,kind){return this.notify(msg,kind);},toastCenter:function(msg,kind){return this.notify(msg,kind);},statusBar:function(msg,kind){var self=this;var bar=document.getElementById('cpd-statusbar');if(!bar){bar=document.createElement('div');bar.id='cpd-statusbar';bar.setAttribute('role','status');document.body.appendChild(bar);}
bar.innerHTML='';bar.className='cpd-statusbar'+(kind?' cpd-'+kind:'');var txt=document.createElement('span');txt.className='cpd-sb-text';txt.textContent=msg;var cnt=document.createElement('span');cnt.className='cpd-sb-count';var x=document.createElement('button');x.type='button';x.className='cpd-sb-x';x.setAttribute('aria-label',_('关闭通知'));x.textContent='×';x.addEventListener('click',function(){self.clearNotice();});bar.appendChild(txt);bar.appendChild(cnt);bar.appendChild(x);bar.style.display='flex';if(self._sbTimer){clearInterval(self._sbTimer);self._sbTimer=null;}
var left=100;cnt.textContent=String(left);self._sbTimer=setInterval(function(){left--;if(left<=0){self.clearNotice();return;}
cnt.textContent=String(left);},1000);return true;},clearNotice:function(){var bar=document.getElementById('cpd-statusbar');if(bar){bar.style.display='none';bar.innerHTML='';}
if(this._sbTimer){clearInterval(this._sbTimer);this._sbTimer=null;}
return true;},modal:function(title,nodes){var list=Array.isArray(nodes)?nodes.filter(function(n){return n!=null;}):[nodes];return ui.showModal(title,list);},confirm:function(title,text,okText,danger,onok){var row=E('div',{'style':'margin-top:18px;display:flex;justify-content:flex-end;gap:8px'},[E('button',{'class':'btn cbi-button','click':function(){ui.hideModal();}},_('取消')),E('button',{'class':'btn cbi-button '+(danger?'cbi-button-negative':'cbi-button-positive'),'click':function(){ui.hideModal();onok();}},okText)]);return ui.showModal(title,[E('p',{},text),row]);},b64encode:function(s){return btoa(unescape(encodeURIComponent(s)));},b64decode:function(s){return decodeURIComponent(escape(atob(s)));},style:ensureStyle,pageHead:function(title,en,desc){ensureStyle();return E('div',{'class':'cpd-head'},[E('h2',{},[title,E('span',{'class':'cpd-en'},en)]),desc?E('div',{'class':'cpd-desc'},desc):E([])]);},section:function(title,en){return E('div',{'class':'cpd-sec'},[E('h3',{},[title,E('span',{'class':'cpd-en'},en)])]);},nativeNotice:function(msg,timeout){var self=this;var LC=window.L;if(!LC||typeof LC.require!=='function')return self.statusBar(msg);return LC.require('ui').then(function(ui){var p=document.createElement('p');p.textContent=msg;if(ui&&typeof ui.addTimeLimitedNotification==='function'){ui.addTimeLimitedNotification(null,p,timeout||6000,'info');}else if(ui&&typeof ui.addNotification==='function'){ui.addNotification(null,p,'info');}else{self.statusBar(msg);}}).catch(function(){self.statusBar(msg);});},notifyChanges:function(){var self=this;var LC=window.L;if(!LC||typeof LC.require!=='function')
return Promise.resolve();return LC.require('ui').then(function(ui){if(ui&&ui.changes&&typeof ui.changes.init==='function')
return ui.changes.init();if(ui&&ui.changes&&typeof ui.changes.setIndicator==='function')
return LC.require('uci').then(function(uci){return uci.changes().then(function(ch){var n=0,k;if(ch)for(k in ch)if(ch.hasOwnProperty(k))n+=(ch[k]||[]).length;ui.changes.setIndicator(n);});});}).catch(function(){});},fallbackChangeCount:function(){return Promise.resolve();},errText:function(e,fallback){if(typeof e==='number')return _('请求失败（错误码 %d）').format(e);return(e&&e.error)||(e&&e.message)||fallback||_('操作失败');},secType:function(conf){return(conf==='zone_blacklist')?'main':conf;},ensureSection:function(uci,conf,sid){if(uci.get(conf,sid))return true;var m=/^@([A-Za-z0-9_]+)(\[\d+\])?$/.exec(sid);if(m){var secs=uci.sections(conf,m[1])||[];if(secs.length)return true;uci.add(conf,m[1]);return!!uci.get(conf,sid);}
uci.add(conf,this.secType(conf),sid);return!!uci.get(conf,sid);},stageUci:function(conf,sid,opt,typ,values){var self=this;var prev=(self._stageQ||Promise.resolve()).catch(function(){});self._stageQ=prev.then(function(){return self.stageOne(conf,sid,opt,typ,values);});return self._stageQ;},stageOne:function(conf,sid,opt,typ,values){var self=this;var LC=window.L;if(!LC||typeof LC.require!=='function')
return Promise.reject({error:_('当前页面环境不支持 uci 模块')});var wrote=false;return LC.require('uci').then(function(uci){return uci.load(conf).then(function(){if(!self.ensureSection(uci,conf,sid))
throw{error:_('配置节不存在且无法新建：%s').format(conf+'.'+sid)};if(typeof uci.resolveSID==='function'&&uci.resolveSID(conf,sid)==null)
throw{error:_('配置节不存在：%s').format(conf+'.'+sid)};if(typ==='opt'){var v=(values===null||values===undefined)?'':String(values);var cur=uci.get(conf,sid,opt);var curS=(cur==null)?'':String(cur);if(curS===v)return;uci.set(conf,sid,opt,v===''?null:v);}else{var arr=(values||[]).map(function(x){return String(x);});var cv=uci.get(conf,sid,opt);var ca=Array.isArray(cv)?cv.map(String):(cv==null?[]:[String(cv)]);if(ca.length===arr.length&&ca.join('\n')===arr.join('\n'))
return;uci.set(conf,sid,opt,arr.length?arr:null);}
wrote=true;return uci.save();}).then(function(){if(!wrote)return null;return uci.changes().then(function(ch){if(ch&&ch[conf])return null;throw{error:_('配置未能写入：%s.%s.%s（会话增量里没有这条记录）').format(conf,sid,opt)};});});}).then(function(){return self.notifyChanges();},function(e){throw{error:self.errText(e,_('暂存配置失败'))};});},applyStaged:function(){var LC=window.L;if(!LC||typeof LC.require!=='function')
return Promise.reject({error:_('当前页面环境不支持 uci 模块')});return LC.require('ui').then(function(ui){if(!(ui&&ui.changes&&typeof ui.changes.apply==='function'))
throw{error:_('当前 LuCI 版本不支持原生应用流程')};ui.changes.apply(false);return{ok:1,native:1};},function(e){throw{error:this.errText(e,_('应用失败'))};}.bind(this));},revertStaged:function(){var LC=window.L;if(!LC||typeof LC.require!=='function')
return Promise.reject({error:_('当前页面环境不支持 uci 模块')});return LC.require('ui').then(function(ui){if(ui&&ui.changes&&typeof ui.changes.revert==='function')
return ui.changes.revert();throw{error:_('当前 LuCI 版本不支持原生复位')};});}});document.addEventListener('uci-applied',function(){L.require('opennds_cpd.common').then(function(m){return m.api('sys','post_apply');}).catch(function(){});});return CPD;