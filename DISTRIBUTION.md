# Getting ARC onto your iPhone, iPad, Macs and other officials' devices

ARC is shared through **TestFlight**, Apple's free app for installing pre-release apps. One
upload covers iPhone, iPad and Mac. People open an invitation link, tap *Install*, and get
updates automatically. No App Store listing is involved.

```
Your Mac (Xcode)  ──upload──►  App Store Connect  ──►  TestFlight  ──►  iPhone · iPad · Mac
                               (Apple's servers)        (you + up to 10,000 testers)
```

| Step | Who | Time |
|---|---|---|
| 1. Join the Apple Developer Program | you, once | ~1–2 days for Apple to approve |
| 2. Create the app in App Store Connect | you, once | 10 minutes |
| 3. Build and upload | you, each release | ~20 minutes |
| 4. Install on your own devices | you | 5 minutes |
| 5. Invite other officials | you, then them | ~1 day for Apple's first beta review |

---

## Before you share: permission

The Alpine Competition Guide says no part of it may be "stored in a database or retrieval
system without the prior written permission of the publisher", and the other U.S. Ski &
Snowboard documents ask for permission to reproduce them. Installing ARC on **your own**
devices is personal use. Before you invite **other officials**, ask U.S. Ski & Snowboard
Competition Services for written permission. Something like:

> Hello, I'm an alpine official in the ___ division. I've built a free, offline app for race
> officials that answers rules questions with links to the exact page of the Alpine Competition
> Guide, the Officials' Manual and the study guides. It runs entirely on the device and isn't
> sold. I'd like to share it with about ___ officials in our division through Apple's TestFlight.
> May I include the current U.S. Ski & Snowboard documents in it? I'm happy to show you the app
> or to add any notice you'd like.

The FIS documents (ICR, Timing Booklet, …) and the OISRA rules are worth the same courtesy note
to their publishers.

---

## 1. Join the Apple Developer Program (once)

1. Go to **developer.apple.com/programs/enroll** and sign in with your Apple ID.
2. Enroll as an **individual** ($99 a year). Apple usually approves within a day or two.
3. Find your **Team ID** under *Account → Membership details* (10 characters, like `ABCDE12345`).
4. In the project folder on your Mac:
   ```sh
   cp App/Config/Local.xcconfig.example App/Config/Local.xcconfig
   open -e App/Config/Local.xcconfig        # replace ABCDE12345 with your Team ID
   ```
   This file stays on your Mac (it's git-ignored).

## 2. Create the app in App Store Connect (once)

1. Open **appstoreconnect.apple.com → Apps → + → New App**.
2. Tick **iOS** and **macOS** (one record covers iPhone, iPad and Mac).
3. Name: something unique on the App Store, such as *ARC Alpine Racing Companion*. Testers
   see this name; the home-screen name stays **ARC**.
4. Bundle ID: choose **com.hoffmannet.alpineracingcompanion**. If it isn't in the list yet, do step 3
   first; Xcode registers it during the first archive. SKU: anything, e.g. `arc-001`.

## 3. Build and upload (each release)

```sh
cd arc-alpine-racing-companion
git pull --recurse-submodules       # the code and the private document library
scripts/build_resources.sh          # rebuild the rulebook library (~3 min)
scripts/bump_build.sh               # new build number (required for every upload)
xcodegen generate
open AlpineRacingCompanion.xcodeproj
```

In Xcode:

1. Select the **AlpineRacingCompanion** project → **Signing & Capabilities**. Check that **Team** shows
   your name and *Automatically manage signing* is on. Xcode registers the app ID and the
   **Increased Memory Limit** capability, which Qwen 4B needs on iPhone and iPad.
2. **iPhone and iPad:** set the run destination (top bar) to **Any iOS Device (arm64)**, then
   **Product → Archive**. When the Organizer opens, choose **Distribute App → TestFlight &
   App Store** (called *App Store Connect* in some Xcode versions) and follow the prompts.
3. **Mac:** set the destination to **Any Mac**, then **Product → Archive** and distribute the
   same way.
4. Within about 15 minutes the builds appear in App Store Connect under **TestFlight**, and
   Apple emails you when processing finishes.

The project already includes the app icon, the privacy manifest (ARC collects no data) and
the export-compliance answer (standard HTTPS only), so uploads shouldn't stop to ask for them.

## 4. Install on your own iPhone, iPad and Macs

1. In App Store Connect → **TestFlight → Internal Testing**, create a group (e.g. *Me*), add
   yourself, and add the new builds. Internal testers don't need Apple's review.
2. On each device, install **TestFlight** from the App Store (it's in the Mac App Store too),
   sign in with the same Apple ID, and tap **Install** next to ARC.
3. First launch on each device: ARC prepares its search index (about a minute; the banner
   shows progress). Then, in **Settings → Download** (on Wi-Fi), get the 2.3 GB Qwen3 4B model
   on devices that support it. After that, everything works offline.

## 5. Invite other officials

1. In TestFlight → **External Testing**, create a group (e.g. *Division officials*) and add the
   build.
2. Fill in the test information: a short description, what to test, a feedback email, and
   any contact details or privacy-policy link App Store Connect asks for. A simple page saying
   "ARC collects no data; everything stays on your device" is enough.
3. Submit for **Beta App Review**. Apple reviews the first build of each version, usually
   within a day. Later builds of the same version are often approved automatically.
4. Turn on **Public Link** and share it by email or text. Officials install TestFlight, open
   the link, and tap **Install**. Up to 10,000 people can use one link, and you can see who's
   installed it or remove testers at any time.

### What officials need to know

- **Devices:** iPhone, iPad or Mac running iOS / iPadOS / macOS 26.
- **Written answers:** Qwen3 4B runs on iPhone 15 Pro or newer and M-series iPads and Macs
  (a 2.3 GB one-time download in Settings). Other Apple Intelligence devices use Apple's built-in
  model. Everything else gets search mode, which still shows the matching rules with page links.
- **Offline:** after the first launch (and the optional model download), no signal is needed.
- **Feedback:** take a screenshot in TestFlight to send it straight to you.

## Updates and the 90-day limit

Each TestFlight build works for **90 days**. That fits the season: when the new Competition
Guide, ICR or study guides come out, add the PDFs to the private library
(`ingest/library/documents/`, then commit and push them in that repository, not in the public
one), repeat step 3, and add the new build to your groups. Testers get it automatically.

## When something goes wrong

| Message | Fix |
|---|---|
| *Signing for "AlpineRacingCompanion" requires a development team* | Step 1.4: create `App/Config/Local.xcconfig` with your Team ID, then `xcodegen generate` again. |
| *The bundle version must be higher than the previously uploaded version* | Run `scripts/bump_build.sh`, then `xcodegen generate`, and archive again. |
| *Missing app icon* or *Invalid image… alpha channel* | Don't edit the icon in Preview; regenerate it with `docs/icon/render.js` (see `docs/icon/`). |
| *Provisioning profile doesn't include the com.apple.developer.kernel.increased-memory-limit entitlement* | In Signing & Capabilities click **+ Capability → Increased Memory Limit**, or enable it for the app ID at developer.apple.com → Identifiers. |
| ARC is missing in TestFlight on the Mac | Make sure you also archived and uploaded the **Any Mac** build (step 3.3). |
| *Rulebook unavailable* when ARC opens | `scripts/build_resources.sh` wasn't run before archiving; run it and archive again. |
| *No documents folder at …/ingest/documents* | The private library isn't checked out: `git submodule update --init` (see the README). |

## Other routes (not needed now)

- **App Store:** possible later with U.S. Ski & Snowboard's permission. It's the same upload,
  plus screenshots and Apple's full review.
- **Macs without TestFlight:** Xcode can export a notarized copy (*Distribute App → Direct
  Distribution*) to share as a download. It updates manually.
- **Free Apple ID, no program membership:** Xcode can install onto your own plugged-in iPhone,
  but the app stops working after 7 days and can't be shared, so it's only useful for a quick try.
