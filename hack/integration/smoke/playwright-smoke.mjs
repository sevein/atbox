import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const url = process.env.ATBOX_URL;
const screenshotPath = process.env.PLAYWRIGHT_SCREENSHOT;
const waitSelector = process.env.PLAYWRIGHT_WAIT_SELECTOR || '#search-box-input';
const waitAfterMs = Number.parseInt(process.env.PLAYWRIGHT_WAIT_AFTER_MS || '1000', 10);
const timeoutMs = Number.parseInt(process.env.PLAYWRIGHT_TIMEOUT_MS || '20000', 10);

if (!url) {
  throw new Error('ATBOX_URL is required');
}

if (!screenshotPath) {
  throw new Error('PLAYWRIGHT_SCREENSHOT is required');
}

await mkdir(path.dirname(screenshotPath), { recursive: true });

const browser = await chromium.launch({ headless: true });

try {
  const page = await browser.newPage();
  const response = await page.goto(url, {
    timeout: timeoutMs,
    waitUntil: 'domcontentloaded',
  });

  if (!response || !response.ok()) {
    const status = response ? response.status() : 'no-response';
    throw new Error(`Landing page request failed (${status}) for ${url}`);
  }

  await page.waitForSelector(waitSelector, { timeout: timeoutMs });
  await page.waitForTimeout(waitAfterMs);
  await page.screenshot({ path: screenshotPath, fullPage: true });

  console.log(`Saved screenshot: ${screenshotPath}`);
} finally {
  await browser.close();
}
