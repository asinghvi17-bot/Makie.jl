// node shoot.mjs URL OUTPREFIX — a screenshot of the WGLMakie page's canvas (headless Chromium, SwiftShader WebGL). Env: PW_MODULE, PLAYWRIGHT_BROWSERS_PATH.
const { chromium } = await import(process.env.PW_MODULE);
const [url, outPrefix] = process.argv.slice(2);
const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const p = await b.newPage({ viewport: { width: 640, height: 450 }, deviceScaleFactor: 1 });
p.on('pageerror', (e) => console.error('[pageerror]', e.message));
await p.goto(url);
await p.waitForSelector('canvas', { timeout: 180000 });
await p.waitForTimeout(5000);
const rect = await p.evaluate(() => { const r = document.querySelector('canvas').getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; });
await p.screenshot({ path: `${outPrefix}.png`, clip: rect });
console.log('shot', JSON.stringify(rect));
await b.close();
