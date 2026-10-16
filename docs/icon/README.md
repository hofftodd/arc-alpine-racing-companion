# ARC app icon

`icon.html` is the design: a carved giant-slalom arc through a red gate. To regenerate the
icon after changing it:

```sh
NODE_PATH=$(npm root -g) node docs/icon/render.js /tmp/icon.png
python3 - <<'PY'
from PIL import Image
src = Image.open("/tmp/icon.png").convert("RGB")  # App Store icons must not have an alpha channel
out = "App/Resources/Assets.xcassets/AppIcon.appiconset/"
src.save(out + "AppIcon-1024.png")
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        src.resize((pt * scale,) * 2, Image.LANCZOS).save(out + f"AppIcon-mac-{pt}@{scale}x.png")
PY
```

Needs Node with Playwright (`npm install -g playwright && npx playwright install chromium`) and Pillow.
