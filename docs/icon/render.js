// Renders icon.html to a 1024x1024 PNG. Usage: NODE_PATH=$(npm root -g) node docs/icon/render.js <out.png>
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  await page.goto('file://' + path.join(__dirname, 'icon.html'));
  await page.screenshot({ path: process.argv[2], omitBackground: false });
  await browser.close();
})();
