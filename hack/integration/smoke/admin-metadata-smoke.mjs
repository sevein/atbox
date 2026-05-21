import { mkdir } from 'node:fs/promises';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const baseUrl = process.env.ATBOX_ADMIN_URL;
const username = process.env.ATBOX_ADMIN_USERNAME || 'demo@example.com';
const password = process.env.ATBOX_ADMIN_PASSWORD || 'demo';
const screenshotPath = process.env.PLAYWRIGHT_ADMIN_SCREENSHOT;
const statePath = process.env.PLAYWRIGHT_ADMIN_STATE;
const timeoutMs = Number.parseInt(process.env.PLAYWRIGHT_TIMEOUT_MS || '20000', 10);

if (!baseUrl) {
  throw new Error('ATBOX_ADMIN_URL is required');
}

if (!screenshotPath) {
  throw new Error('PLAYWRIGHT_ADMIN_SCREENSHOT is required');
}

if (!statePath) {
  throw new Error('PLAYWRIGHT_ADMIN_STATE is required');
}

await mkdir(path.dirname(screenshotPath), { recursive: true });
await mkdir(path.dirname(statePath), { recursive: true });

function absoluteUrl(route) {
  return `${baseUrl.replace(/\/$/, '')}/${route.replace(/^\//, '')}`;
}

async function fillFirst(root, selectors, value) {
  for (const selector of selectors) {
    const locator = root.locator(selector).filter({ visible: true }).first();
    if (await locator.count()) {
      await locator.fill(value);
      return true;
    }
  }

  return false;
}

async function clickFirst(root, selectors) {
  for (const selector of selectors) {
    const locator = root.locator(selector).filter({ visible: true }).first();
    if (await locator.count()) {
      await locator.click();
      return true;
    }
  }

  return false;
}

async function clickFirstAndWait(page, root, selectors) {
  const clicked = await Promise.all([
    page.waitForLoadState('domcontentloaded', { timeout: timeoutMs }).catch(() => {}),
    clickFirst(root, selectors),
  ]);

  return clicked[1];
}

function slugFromUrl(url) {
  const parsed = new URL(url);
  const parts = parsed.pathname.split('/').filter(Boolean);
  const slug = parts[parts.length - 1];

  if (!slug || slug === 'index.php') {
    throw new Error(`Unable to infer information object slug from URL: ${url}`);
  }

  return slug;
}

const browser = await chromium.launch({ headless: true });

try {
  const page = await browser.newPage();
  const loginResponse = await page.goto(absoluteUrl('/user/login'), {
    timeout: timeoutMs,
    waitUntil: 'domcontentloaded',
  });

  if (!loginResponse || !loginResponse.ok()) {
    const status = loginResponse ? loginResponse.status() : 'no-response';
    throw new Error(`Admin login page request failed (${status})`);
  }

  let loginForm = page.locator('#main-column form').filter({
    has: page.locator('input[name="password"], input[type="password"]'),
  }).first();

  if (!(await loginForm.count())) {
    loginForm = page.locator('main form').filter({
      has: page.locator('input[name="password"], input[type="password"]'),
    }).first();
  }

  if (!(await loginForm.count())) {
    throw new Error('Unable to find admin login form');
  }

  const filledUser = await fillFirst(loginForm, [
    'input[name="email"]',
    'input[name="username"]',
    'input[name*="email" i]',
    'input[name*="user" i]',
    'input[type="email"]',
    'input[type="text"]',
  ], username);
  const filledPassword = await fillFirst(loginForm, ['input[name="password"]', 'input[type="password"]'], password);
  const nextInput = loginForm.locator('input[name="next"]').first();
  if (await nextInput.count()) {
    await nextInput.evaluate((input, value) => {
      input.value = value;
    }, absoluteUrl('/'));
  }

  if (!filledUser || !filledPassword) {
    throw new Error('Unable to find admin login fields');
  }

  await clickFirstAndWait(page, loginForm, ['button[type="submit"]', 'input[type="submit"]']);

  const passwordField = page.locator('input[name="password"], input[type="password"]').filter({ visible: true }).first();
  if (await passwordField.count()) {
    throw new Error('Admin login did not appear to succeed');
  }

  const title = `atbox admin smoke ${Date.now()}`;
  const updatedTitle = `${title} updated`;
  const identifier = `atbox-${Date.now()}`;
  const addResponse = await page.goto(absoluteUrl('/informationobject/add'), {
    timeout: timeoutMs,
    waitUntil: 'domcontentloaded',
  });

  if (!addResponse || !addResponse.ok()) {
    const status = addResponse ? addResponse.status() : 'no-response';
    throw new Error(`Information object add page request failed (${status})`);
  }

  const addForm = page.locator('#main-column form').first();
  const identityArea = page.getByRole('button', { name: /identity area/i }).first();
  if (await identityArea.count()) {
    const expanded = await identityArea.getAttribute('aria-expanded');
    if (expanded !== 'true') {
      await identityArea.click();
    }
  }

  const filledTitle = await fillFirst(addForm, [
    'input[name="title"]',
    'textarea[name="title"]',
    'input[name*="[title]" i]',
    'textarea[name*="[title]" i]',
    'input[id*="title" i]',
    'textarea[id*="title" i]',
  ], title);
  await fillFirst(addForm, [
    'input[name="identifier"]',
    'input[name*="[identifier]" i]',
    'input[id*="identifier" i]',
  ], identifier);

  if (!filledTitle) {
    throw new Error('Unable to find information object title field');
  }

  for (const select of await page.locator('select:visible').all()) {
    const current = await select.inputValue().catch(() => '');
    if (current) {
      continue;
    }

    const option = await select.locator('option[value]:not([value=""])').first();
    if (await option.count()) {
      await select.selectOption(await option.getAttribute('value'));
    }
  }

  if (!await clickFirstAndWait(page, addForm, [
    'button[type="submit"]',
    'input[type="submit"][value*="Save" i]',
    'input[type="submit"]',
  ])) {
    throw new Error('Unable to submit information object add form');
  }

  await page.goto(absoluteUrl(`/informationobject/browse?topLod=0&query=${encodeURIComponent(title)}`), {
    timeout: timeoutMs,
    waitUntil: 'domcontentloaded',
  });
  await page.screenshot({ path: screenshotPath, fullPage: true });

  if (!(await page.getByText(title, { exact: false }).count())) {
    throw new Error(`Created information object was not visible in browse results: ${title}`);
  }

  const resultLink = page.locator('a', { hasText: title }).first();
  if (!(await resultLink.count())) {
    throw new Error(`Created information object link was not visible in browse results: ${title}`);
  }

  await Promise.all([
    page.waitForLoadState('domcontentloaded', { timeout: timeoutMs }).catch(() => {}),
    resultLink.click(),
  ]);

  if (!(await page.getByText(title, { exact: false }).count())) {
    throw new Error(`Created information object title was not visible on detail page: ${title}`);
  }

  const detailUrl = page.url();
  const slug = slugFromUrl(detailUrl);

  if (!await clickFirstAndWait(page, page, [
    'a[href*="/edit"]',
    'a:has-text("Edit")',
    'button:has-text("Edit")',
    'input[type="submit"][value*="Edit" i]',
  ])) {
    throw new Error(`Unable to enter edit mode for information object: ${title}`);
  }

  const editForm = page.locator('#main-column form').first();
  const updatedTitleField = await fillFirst(editForm, [
    'input[name="title"]',
    'textarea[name="title"]',
    'input[name*="[title]" i]',
    'textarea[name*="[title]" i]',
    'input[id*="title" i]',
    'textarea[id*="title" i]',
  ], updatedTitle);

  if (!updatedTitleField) {
    throw new Error('Unable to find information object title field in edit form');
  }

  if (!await clickFirstAndWait(page, editForm, [
    'button[type="submit"]',
    'input[type="submit"][value*="Save" i]',
    'input[type="submit"]',
  ])) {
    throw new Error('Unable to submit information object edit form');
  }

  await page.goto(absoluteUrl(`/informationobject/browse?topLod=0&query=${encodeURIComponent(updatedTitle)}`), {
    timeout: timeoutMs,
    waitUntil: 'domcontentloaded',
  });

  if (!(await page.getByText(updatedTitle, { exact: false }).count())) {
    throw new Error(`Updated information object was not visible in browse results: ${updatedTitle}`);
  }

  await page.screenshot({ path: screenshotPath, fullPage: true });
  await writeFile(statePath, JSON.stringify({
    title,
    updatedTitle,
    identifier,
    slug,
    detailUrl,
  }, null, 2));

  console.log(`Admin metadata smoke updated record: ${updatedTitle}`);
} finally {
  await browser.close();
}
