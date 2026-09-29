import os
"""Native batch adapters for the four installed models; no generated-text fallback."""
import json
from pathlib import Path
import sys
import time
from contracts import labels, label_answer, lfm_schema, normalize_answer, semif_row, text

ROOT=Path(os.environ.get("JET_DATA_ROOT", Path(__file__).resolve().parents[2]))
sys.path.insert(0,str(ROOT))
MODES=('jev_hosted','lfm_rlcd','qwen4b_semif_shared','laya_mlx')

def unsupported(reason):
    return {'valid':False,'label':None,'probabilities':None,'confidence':None,'score':None,'unsupported':reason}

class Runtime:
    def __init__(self,mode):
        self.mode=mode;started=time.perf_counter()
        if mode=='lfm_rlcd':
            from run import load_engine
            self.engine=load_engine();self.model='LFM2.5-350M@9e6c6ccf47cd318696e137d381a7ded8fe4df09f'
        elif mode=='laya_mlx':
            from laya_runtime import load_agent, MODEL_ID, REVISION
            self.agent=load_agent();self.model=f'{MODEL_ID}@{REVISION}'
        elif mode=='qwen4b_semif_shared':
            from semif_phase1 import mlx_backend
            self.backend=mlx_backend
            self.loaded=mlx_backend.load_model(str(ROOT/'models/qwen4b'),'851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a')
            self.model='Qwen3.5-4B@851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a'
        elif mode=='jev_hosted':
            import httpx
            key_file=Path.home()/'.config/lfm-rlcd/typesafe.key'
            if key_file.stat().st_mode&0o077:raise PermissionError('Credential must be owner-only')
            self._key=key_file.read_text().strip()
            self.client=httpx.Client(base_url='https://api.typesafe.ai',headers={'Authorization':f'Bearer {self._key}'},timeout=60)
            self.model='jev-1.13.0'
        else:raise ValueError(mode)
        self.load_ms=(time.perf_counter()-started)*1000

    def prepare(self,request):
        state,questions=request['state'],request['questions']
        prepared={'request':request,'unsupported':{},'audit':{},'mapped':None}
        if self.mode=='laya_mlx':
            from laya_runtime import audit_prompt
            supported={}
            for key,q in questions.items():
                try:
                    self.agent.prepare(state,{key:q})
                    prepared['audit'][key]=audit_prompt(self.agent,state,{key:q})[key]
                    supported[key]=q
                except (ValueError,AssertionError)as error:prepared['unsupported'][key]=unsupported(f'Native Laya prompt rejected: {error}')
            prepared['mapped']=supported
        elif self.mode=='qwen4b_semif_shared':
            from semif_phase1.direct import encode_prompt
            from semif_phase1.shared import _state_prefix
            model,tok,metadata=self.loaded;rows=[];direct=[]
            for key,q in questions.items():
                row=semif_row(key,state,q)
                try:
                    encoded=encode_prompt(tok,row,16384);prefix=_state_prefix(tok,row['state'])
                    prepared['audit'][key]={'input_tokens':len(encoded[0]),'max_len':16384,'truncated':False}
                    (rows if prefix and encoded[0][:len(prefix)]==prefix and len(encoded[0])>len(prefix)else direct).append(row)
                except ValueError as error:prepared['unsupported'][key]=unsupported(str(error))
            prepared['mapped']={'shared':rows,'direct':direct}
        elif self.mode=='lfm_rlcd':
            schema=lfm_schema(questions);context=text(state)
            ids=self.engine.encode(self.engine.prompt(context,schema))
            limit=self.engine.model.config.max_position_embeddings
            if len(ids)+256>limit:
                prepared['unsupported']={k:unsupported(f'Full batch input {len(ids)} tokens exceeds model window {limit}')for k in questions}
            prepared['mapped']={'context':context,'schema':schema}
            prepared['audit']={k:{'input_tokens':len(ids),'max_len':limit,'truncated':False}for k in questions}
        return prepared

    def predict(self,prepared):
        request=prepared['request'];questions=request['questions'];answers=dict(prepared['unsupported']);raw={};usage={};status=200
        started=time.perf_counter()
        if self.mode=='jev_hosted':
            response=self.client.post('/v1/systemone',json={**request,'model':self.model})
            status=response.status_code
            try:raw=response.json()
            except ValueError:raw={'error':'Non-JSON HTTP response'}
            if status==400 and isinstance(raw.get('detail'),dict) and raw['detail'].get('error_type')=='max_tokens_exceeded':
                # An intentional capacity probe is a measured unsupported input,
                # not an infrastructure outage. Preserve the HTTP response.
                return {'answers':{k:unsupported('Hosted context limit exceeded')for k in questions},'raw':raw,'usage':{},'status':status,
                        'latency_ms':(time.perf_counter()-started)*1000,'model':self.model,'context_audit':{}}
            if status!=200:
                raise RuntimeError(f'Hosted HTTP {status}: '+json.dumps(raw)[:500].replace(self._key,'[REDACTED]'))
            if raw.get('model') not in (None,self.model):raise ValueError('Hosted model identity changed')
            usage=raw.get('usage',{})
            for key,q in questions.items():
                try:answers[key]=normalize_answer(q,raw['answers'][key])
                except (ValueError,KeyError,TypeError)as e:answers[key]=unsupported(f'Invalid native answer: {e}')
        elif self.mode=='lfm_rlcd' and not answers:
            raw=self.engine.constrained(**prepared['mapped']);self.engine.sync()
            output=json.loads(raw['text']);usage={'input_tokens':raw['prompt_tokens'],'output_tokens':0}
            answers={key:label_answer(q,output[key])for key,q in questions.items()}
        elif self.mode=='laya_mlx' and prepared['mapped']:
            raw=self.agent.predict(request['state'],prepared['mapped']);usage=raw['usage']
            for key,q in prepared['mapped'].items():answers[key]=normalize_answer(q,raw['answers'][key])
        elif self.mode=='qwen4b_semif_shared':
            model,tok,metadata=self.loaded;records=[];timing={}
            if prepared['mapped']['shared']:
                rows,timing=self.backend.score_shared(model,tok,prepared['mapped']['shared'],metadata,max_tokens=16384);records.extend(rows)
            for row in prepared['mapped']['direct']:records.append(self.backend.score(model,tok,row,metadata,max_tokens=16384))
            raw={'answers':records,'timing':timing,'direct_prefix_fallbacks':[r['id']for r in prepared['mapped']['direct']]}
            for row in records:
                key=row['id'];q=questions[key];p=dict(zip(row['option_ids'],row['probabilities']))
                native={'type':q['type'],'probabilities':p}
                if q['type']=='noul':native['noul']=p['true']
                elif q['type']=='choice':native['choice']=max(p,key=p.get)
                else:native['score']=sum(int(k)*v for k,v in p.items())
                answers[key]=normalize_answer(q,native)
            usage={'input_tokens':sum(r['input_tokens']for r in records),'output_tokens':0}
        return {'answers':answers,'raw':raw,'usage':usage,'status':status,'latency_ms':(time.perf_counter()-started)*1000,'model':self.model,'context_audit':prepared['audit']}
