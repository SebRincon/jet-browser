"""Acceptance harness: bundled runtime + real Grok ACP + isolated Chromium DOM."""
import argparse,asyncio,base64,json,os,subprocess,sys,time
from pathlib import Path

HTML='''<!doctype html><style>body{color:white;background:#181818}article{height:270px}main{height:500px;overflow:auto}</style><main><h1>Synthetic software bookmarks</h1>
<article><a rel="bookmark" href="/posts/one"><time datetime="2026-09-28T10:00:00Z">Today</time></a><div class="author">Fixture Author</div><p>A developer released an open source mobile application for iOS and Android with accessible navigation.</p></article>
<article><a rel="bookmark" href="/posts/two"><time datetime="2026-09-27T10:00:00Z">Yesterday</time></a><p>A web design toolkit provides reusable browser components and color themes.</p></article>
<article><a rel="bookmark" href="/posts/three"><time datetime="2026-09-26T10:00:00Z">Earlier</time></a><p>Researchers published a study on evaluating AI agents that operate web browsers.</p></article></main>'''

TOPICS=['an open source iOS and Android app with accessible navigation','a browser design toolkit with reusable components and color themes','a research study on evaluating AI agents that operate web browsers','a fast command line tool for searching code, MIT licensed','a macOS menu bar utility for window tiling','typography guidance for product landing pages']
# The incident-shaped feed: enough posts to need scrolling and one review at ten.
LONG_HTML='<!doctype html><style>body{color:white;background:#181818}article{height:270px}main{height:500px;overflow:auto}</style><main><h1>Synthetic software bookmarks</h1>'+''.join(
    f'<article><a rel="bookmark" href="/posts/{n}"><time datetime="2026-09-{28-n%20:02d}T10:00:00Z">Day {n}</time></a><div class="author">Fixture Author {n}</div><p>Post {n}: {TOPICS[n%len(TOPICS)]}.</p></article>'
    for n in range(1,26))+'</main>'
TEMPLATE_PROMPT=('Organize the first 20 bookmarks on this tab with overlapping mobile, web, desktop, design, research, tools and '
    'open-source tags, a short summary, the link and the date for each. Review the first ten with me in the checkpoint; I authorize '
    'small samples there and authorize you to continue without asking me. The only tab is our synthetic fixture, not my real bookmarks.')
PAGE=HTML

class Browser:
    host_id='portable-fixture'
    active_tab_id='fixture-tab'
    supports_background=True
    online=True
    def __init__(self,ws):
        self.ws=ws;self.seq=0;self.tab_owners={};self.tabs=[{'id':'fixture-tab','url':'https://workflow.test/feed','title':'Synthetic software bookmarks'}]
    def tab(self,value=None):
        if (value or self.active_tab_id)!='fixture-tab':raise ValueError('Unknown fixture tab')
        return 'fixture-tab'
    def claim_tab(self,tid,owner):self.tab_owners[tid]=owner
    def release_tab(self,tid,owner):
        if self.tab_owners.get(tid)==owner:self.tab_owners.pop(tid)
    def tab_owner(self,tid):return self.tab_owners.get(tid)
    def cancel_queued(self):pass
    def fail_pending(self,*args):pass
    async def call(self,tab,method,params=None,**kwargs):
        if method not in {'Runtime.evaluate','Page.navigate','Fetch.enable'}:raise ValueError('Harness capability not supported: '+method)
        self.seq+=1;ident=self.seq
        await self.ws.send_json(dict(id=ident,method=method,params=params or {}))
        while True:
            msg=await self.ws.receive_json(timeout=20)
            if msg.get('method')=='Fetch.requestPaused':
                self.seq+=1
                await self.ws.send_json(dict(id=self.seq,method='Fetch.fulfillRequest',params=dict(requestId=msg['params']['requestId'],responseCode=200,responseHeaders=[dict(name='Content-Type',value='text/html')],body=base64.b64encode(PAGE.encode()).decode())))
            if msg.get('id')==ident:
                if 'error' in msg:raise RuntimeError(msg['error'])
                return msg.get('result',{})

async def main(args):
    import aiohttp
    from aiohttp import web
    from jet_browser.service import Service, create_app
    from jet_browser.paths import DATA_ROOT, PORT, RESOURCE_ROOT
    from jev_ultrafast.local_models import WORKER
    DATA_ROOT.mkdir(parents=True,exist_ok=True)
    profile=DATA_ROOT/'chromium-test'
    chrome=os.environ['JET_TEST_CHROMIUM']
    proc=subprocess.Popen([chrome,'--headless','--remote-debugging-port=0','--user-data-dir='+str(profile),'--no-first-run','--disable-background-networking','about:blank'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    service=None;runner=None;started=time.monotonic();evidence={}
    try:
        portfile=profile/'DevToolsActivePort'
        for _ in range(100):
            if portfile.exists():break
            await asyncio.sleep(.1)
        debug_port=portfile.read_text().splitlines()[0]
        async with aiohttp.ClientSession() as client:
            async with client.get(f'http://127.0.0.1:{debug_port}/json') as response:pages=await response.json()
            async with client.ws_connect(pages[0]['webSocketDebuggerUrl']) as ws:
                browser=Browser(ws)
                await browser.call(None,'Fetch.enable',{'patterns':[{'urlPattern':'*'}]})
                await browser.call(None,'Page.navigate',{'url':'https://workflow.test/feed'})
                for _ in range(50):
                    result=await browser.call(None,'Runtime.evaluate',{'expression':'document.querySelectorAll("article").length','returnByValue':True})
                    if result.get('result',{}).get('value')==(25 if args.scenario.startswith('template') else 3):break
                    await asyncio.sleep(.1)
                service=Service(DATA_ROOT);service.bridge=browser;service.share_review_samples=True
                runner=web.AppRunner(create_app(service));await runner.setup();await web.TCPSite(runner,'127.0.0.1',PORT).start()
                prompt=('Use the custom JavaScript workflow SDK for this synthetic feed. Author and run version 1 that collects exactly the first TWO bookmarks, locally assigns overlapping mobile, web, design, research tags, and locally summarizes each. Save their observed URL and posted date. Set a total limit of THREE saved records, 240 seconds, 400 calls. At two records, use run.checkpoint status review. I authorize small samples at that review and authorize you to continue without asking me. At the automatic review, inspect the saved sample, make one audited summary touch-up to a record using patch_workflow_record, then revise the SAME JavaScript workflow (expected_revision) to collect the THIRD record, scrolling if needed, and complete. Retain original scope/model/limits and previous records. This test specifically requires source revision at the checkpoint. Use SemIf qwen4b_semif_shared, workflow tools rather than collection tools. The final target is three unique saved records and a revised workflow. The only tab is our synthetic fixture, not my real bookmarks.')
                if args.scenario=='template-local':
                    # Same runtime, feed and template with no provider: code resumes the review.
                    from jet_browser import workflow_tools
                    service.workflows.on_checkpoint=lambda *_:None
                    categories=json.loads((Path(__file__).resolve().parents[1]/'backend/tests/fixtures/tagging/bookmarks-tags-v1.json').read_text())['taxonomy'] if (Path(__file__).resolve().parents[1]/'backend/tests/fixtures/tagging/bookmarks-tags-v1.json').is_file() else [{'id':'software','name':'Software','description':'Software'}]
                    saved=await workflow_tools.tool(service,'save_workflow',{'definition':{'title':'Synthetic bookmarks','tab_id':'fixture-tab','start_url':'https://workflow.test/feed','source_kind':'feed','model':'qwen4b_semif_shared','categories':categories,'limits':{'max_seconds':900,'max_calls':3000,'max_items':20},'template':{'name':'tagged_feed','options':{'first_review':10}}}})
                    await workflow_tools.tool(service,'run_workflow',{'workflow_id':saved['id']})
                else:
                    if args.scenario=='template':prompt=TEMPLATE_PROMPT
                    await service.chat(prompt)
                last=None
                while time.monotonic()-started<600:
                    rows=service.workflows.summaries(service.store.current_id)
                    summary=[{k:v for k,v in row.items() if k in {'id','revision','status','error','counters'}} for row in rows]
                    status=json.dumps({'provider':service.provider_status,'workflows':summary})
                    if status!=last:print(status,flush=True);last=status
                    if rows and rows[0]['status']=='completed' and not service.chat_busy and not service.workflows.running:break
                    if args.scenario=='template-local' and rows and rows[0]['status']=='paused' and rows[0]['error']=='checkpoint_review' and not service.workflows.running:
                        await workflow_tools.tool(service,'run_workflow',{'workflow_id':rows[0]['id']})
                    if args.scenario=='template-local' and rows and rows[0]['status'] in {'paused','failed','cancelled'} and rows[0]['error'] not in {'checkpoint_review','checkpoint_continue'} and not service.workflows.running:break
                    if service.provider_status=='error' and not service.chat_busy:break
                    await asyncio.sleep(2)
                rows=service.workflows.summaries(service.store.current_id)
                evidence={'runtime':str(RESOURCE_ROOT),'fixture':'isolated Chromium, synthetic posts','wall_seconds':round(time.monotonic()-started,2),'workflows':rows,'messages':[{'role':m['role'],'text':m['text']} for m in service.messages if m['role']=='assistant']}
                if rows:
                    evidence['records']=service.workflow_store.records(service.store.current_id,rows[0]['id'])
                records=evidence.get('records',{}).get('items',[])
                if args.scenario in {'template','template-local'}:
                    source=(service.workflows.summary(service.store.current_id,rows[0]['id'],include_source=True).get('source') or '') if rows else ''
                    records=service.workflow_store.records(service.store.current_id,rows[0]['id'],limit=100)['items'] if rows else []
                    evidence['records']={'items':records,'total':len(records)}
                    evidence['template']=source.startswith('// Jet built-in template tagged_feed')
                    evidence['grok_turns']=[{k:e['attributes'].get(k) for k in ('status','error_type')}|{'duration_ms':e.get('duration_ms')} for e in service.trace.snapshot(service.store.current_id,limit=2000)['events'] if e['event']=='grok.turn.end']
                    evidence['passed']=bool(rows and rows[0]['status']=='completed' and evidence['template'] and len(records)==20 and len({x['url'] for x in records})==20 and all(x['summary'] and x['published_at'] for x in records))
                else:
                    evidence['passed']=bool(rows and rows[0]['status']=='completed' and rows[0]['revision']>=2 and len(records)==3 and all(x['summary'] for x in records) and any(any(a.get('actor')=='grok' for a in x['audit']) for x in records))
                args.output.write_text(json.dumps(evidence,indent=2))
                print(json.dumps({'passed':evidence['passed'],'records':len(records),'revisions':rows[0]['revision'] if rows else 0}),flush=True)
    finally:
        if runner:await runner.cleanup()
        WORKER.close();proc.terminate();await asyncio.to_thread(proc.wait,10)
    if not evidence.get('passed'):raise SystemExit(1)

def cli():
    parser=argparse.ArgumentParser(description="Explicit live acceptance: synthetic browser data, real paid Grok, bundled local models. Run with bundled python/bin/python3.12.")
    parser.add_argument('--resources',type=Path,required=True,help='App Contents/Resources/jet-runtime')
    parser.add_argument('--data',type=Path,required=True,help='ISOLATED prepared model data directory; never use your live Jet data')
    parser.add_argument('--chromium',type=Path,required=True,help='Isolated Chromium test executable')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--port',type=int,default=9178)
    parser.add_argument('--scenario',choices=('custom','template','template-local'),default='custom',help='custom: Grok writes and revises JavaScript; template: the 2026-09-28 incident request (20 bookmarks, review at ten); template-local: the same template run with no provider (free)')
    args=parser.parse_args()
    resources=args.resources.resolve();data=args.data.resolve()
    if not 1024 <= args.port <= 65533:parser.error('port must leave room for the typing helper')
    if (data/'.runtime').exists() or (data/'chromium-test').exists():
        parser.error('Use a fresh isolated data directory with only prepared models')
    if not (resources/'bundle-manifest.json').is_file():parser.error('Expected packaged resources')
    args.output=args.output.resolve();args.output.parent.mkdir(parents=True,exist_ok=True)
    os.environ.update(JET_RESOURCE_ROOT=str(resources),JET_DATA_ROOT=str(data),JET_PORT=str(args.port),JET_GROK_PATH=str(resources/'bin/grok'),JET_WORKFLOW_PATH=str(resources/'bin/JetWorkflow'),JET_TEST_CHROMIUM=str(args.chromium.resolve()),TEXT_MODEL_BASE_URL=f'http://127.0.0.1:{args.port+1}/v1',TEXT_MODEL_API_KEY='local-only',TEXT_MODEL='default_model',TEXT_MODEL_REASONING='none',PYTHONNOUSERSITE='1')
    sys.path[:0]=[str(resources/'backend'),str(resources/'packages/service')]
    os.environ['PYTHONPATH']=os.pathsep.join(sys.path[:2])
    global PAGE
    PAGE=LONG_HTML if args.scenario.startswith('template') else HTML
    asyncio.run(main(args))

if __name__=='__main__':
    cli()
