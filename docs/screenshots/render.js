const { chromium } = require('playwright');
(async () => {
  const dir = process.argv[2];
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  for (const screen of ['chat', 'menu', 'pdf', 'library']) {
    await page.goto(`file://${dir}/mockups.html?screen=${screen}`);
    await page.waitForTimeout(300);
    await page.locator(`#${screen}`).screenshot({ path: `${dir}/${screen}.png` });
  }
  await browser.close();
})();
