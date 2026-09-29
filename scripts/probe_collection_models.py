"""Explicit local-weight diagnostic. No browser or remote provider calls."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import json
import statistics
import time
from pathlib import Path
from jet_browser.collection_plan import CollectionPlan
from jet_browser.classification import classify_page
from jev_ultrafast.local_models import NativeWorker

root=Path(__file__).resolve().parents[1]
corpus=json.loads((root/'backend/tests/fixtures/collection-classification-cases.json').read_text())
out=root/'.runtime/artifacts'/('collection-classification-'+time.strftime('%Y%m%d-%H%M%S')+'.json')
out.parent.mkdir(parents=True,exist_ok=True)
report={'kind':'synthetic classification diagnostic, not a whole-browser benchmark','corpus':corpus,'models':[]}
for model in ['lfm_rlcd','qwen4b_semif_shared']:
    worker=NativeWorker()
    plan=CollectionPlan.from_request({'request':'Organize website pages by topic','title':'Diagnostic','categories':corpus['taxonomy']},start_url='https://fixture.test/',tab_id='fixture',model=model)
    rows=[];started=time.perf_counter()
    try:
        for case in corpus['cases']:
            before=time.perf_counter()
            try:
                result=classify_page(plan,case['text'],worker=worker)
                row={'id':case['id'],'expected':case['expected'],'result':result,'correct':result['label_id']==case['expected']}
            except Exception as e:
                row={'id':case['id'],'expected':case['expected'],'error_type':type(e).__name__,'correct':False}
            row['wall_ms']=round((time.perf_counter()-before)*1000,2)
            rows.append(row)
            print(model,case['id'],row.get('result',{}).get('label_id',row.get('error_type')),'correct='+str(row['correct']),'wall_ms='+str(row['wall_ms']),flush=True)
    finally:
        worker.close()
    calls=[r['wall_ms'] for r in rows[1:] if r.get('result',{}).get('model_calls')==1]
    report['models'].append({'model':model,'correct':sum(r['correct'] for r in rows),'total':len(rows),'whole_probe_ms':round((time.perf_counter()-started)*1000,2),'warm_call_median_ms':statistics.median(calls) if calls else None,'rows':rows})
    out.write_text(json.dumps(report,indent=2));out.chmod(0o600)
print('REPORT',out,flush=True)
