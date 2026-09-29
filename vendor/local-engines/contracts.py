"""Shared exact-label contracts. Missing probabilities/confidence stay missing."""
import json
import math

def text(value):
    return value if isinstance(value,str) else json.dumps(value,ensure_ascii=False,allow_nan=False)

def labels(question):
    kind=question['type']
    if kind=='noul':return ['false','true']
    if kind=='choice':return list(question['criteria'])
    if kind=='score':return [str(i)for i in range(len(question['criteria']))]
    raise ValueError(f'Unknown type {kind}')

def normalize_answer(question,answer):
    kind=question['type'];options=labels(question)
    if answer.get('type')!=kind:raise ValueError('Native answer type differs from question')
    if kind=='noul':
        p=answer.get('noul')
        if type(p)not in (int,float) or not math.isfinite(p) or not 0<=p<=1:raise ValueError('Invalid Noul')
        probabilities={'false':1-p,'true':p}
    else:probabilities=answer.get('probabilities')
    if not isinstance(probabilities,dict) or set(probabilities)!=set(options):raise ValueError('Distribution label mismatch')
    if any(type(v)not in (float,int) or not math.isfinite(v) or not 0<=v<=1 for v in probabilities.values()):raise ValueError('Invalid probabilities')
    total=sum(probabilities.values())
    if abs(total-1)>0.02:raise ValueError('Distribution does not sum to one within native rounding tolerance')
    normalized={k:probabilities[k]/total for k in options}
    label=max(options,key=normalized.__getitem__)
    if kind=='choice' and answer.get('choice')not in options:raise ValueError('Invalid choice label')
    confidence=answer.get('confidence')
    if confidence is not None and (type(confidence)not in (int,float)or not math.isfinite(confidence)or not 0<=confidence<=1):raise ValueError('Invalid native confidence')
    score=answer.get('score')if kind=='score'else None
    if score is not None and (type(score)not in (int,float)or not math.isfinite(score)or not 0<=score<=len(options)-1):raise ValueError('Invalid expected score')
    return {'label':label,'probabilities':normalized,'probabilities_as_returned':probabilities,'confidence':confidence,
            'score':score,'normalization_applied':abs(total-1)>1e-12,'valid':True}

def label_answer(question,value):
    label=('true'if value else'false')if type(value)is bool else str(value)
    if label not in labels(question):raise ValueError('Output label outside allowed values')
    return {'label':label,'probabilities':None,'probabilities_as_returned':None,'confidence':None,'score':None,'valid':True,'normalization_applied':False}

def lfm_schema(questions):
    properties={}
    for name,q in questions.items():
        description=text(q['instructions'])+'\nCriteria: '+text(q.get('criteria'))
        properties[name]={'type':'boolean','description':description}if q['type']=='noul'else{'type':'string','enum':labels(q),'description':description}
    return {'type':'object','properties':properties,'required':list(properties),'additionalProperties':False}

def semif_row(name,state,question):
    options=labels(question);criteria=question.get('criteria')
    if question['type']=='noul':
        # SemIf's author uses true, false order for binary questions.
        options=['true','false'];descriptions={k:(criteria or{}).get(k,f'The proposition is {k}.')for k in options}
    elif question['type']=='score':descriptions=dict(zip(options,criteria))
    else:descriptions=criteria if isinstance(criteria,dict)else dict.fromkeys(criteria)
    return {'id':name,'state':{'text':state}if isinstance(state,str)else state,'question':text(question['instructions']),
            'options':[{'id':k,'description':k+': '+(text(descriptions[k])if descriptions[k] is not None else k)}for k in options]}
