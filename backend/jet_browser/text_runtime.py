"""Controller-owned bundled typing helper; never spawned by CEF."""
import asyncio
import os
import socket
from contextlib import suppress

import aiohttp


class TextRuntime:
    def __init__(self, data_root, resource_root, port):
        self.data_root, self.resource_root, self.port = data_root, resource_root, port + 1
        self.process = None
        self.lock = asyncio.Lock()

    async def ensure(self):
        python = self.resource_root / 'python/bin/python3.12'
        if not python.is_file():
            return  # Development launcher owns its existing helper.
        async with self.lock:
            if self.process is None or self.process.returncode is not None:
                model = self.data_root / 'models/qwen08b'
                if not (model / 'config.json').is_file():
                    raise ValueError('Download the typing model in Setup to use the assistant')
                with socket.socket() as sock:
                    try:
                        sock.bind(('127.0.0.1', self.port))
                    except OSError:
                        raise ValueError('The local typing port is occupied; another Jet may be running') from None
                env = dict(os.environ, PYTHONPATH=str(self.resource_root / 'packages/text'), PYTHONNOUSERSITE='1', HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1')
                with (self.data_root / '.runtime/text.log').open('ab') as log:
                    self.process = await asyncio.create_subprocess_exec(
                        str(python), '-m', 'mlx_lm', 'server', '--model', str(model),
                        '--host', '127.0.0.1', '--port', str(self.port), '--chat-template-args',
                        '{"enable_thinking":false}', '--temp', '0', '--max-tokens', '1024', '--log-level', 'WARNING',
                        env=env, stdin=asyncio.subprocess.DEVNULL, stdout=log, stderr=log)
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=1)) as client:
                for _ in range(120):
                    if self.process.returncode is not None:
                        raise ValueError('Local typing model failed to start; see Diagnostics')
                    try:
                        async with client.get(f'http://127.0.0.1:{self.port}/health') as response:
                            if response.status == 200:
                                return
                    except (aiohttp.ClientError, TimeoutError):
                        pass
                    await asyncio.sleep(.25)
            raise ValueError('Local typing model is still starting; try again shortly')

    async def close(self):
        if self.process is not None and self.process.returncode is None:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 5)
            except TimeoutError:
                with suppress(ProcessLookupError):
                    self.process.kill()
                await self.process.wait()
