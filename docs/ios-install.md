# Installing the iPhone app (Mewt Photos for iOS)

The app shows on the iPhone as **Mewt Photos** with a violet "m" icon.

**After the rename (one time):** the app has a new identity, so AltStore installs it as a separate app and it has to be paired
again. Delete the old copy from the iPhone once the new one works. The PC keeps all its history: the server moves its data
folder (`%LOCALAPPDATA%\MewtPhotos`) and database over by itself the first time it starts. The Safari page on the phone also
asks to pair once more. In iCloud Drive, builds now live in a `MewtPhotos` folder.

The native iPhone app is built on GitHub, not on a Mac, and installed from Windows with **AltStore** using a free Apple ID.
It is a personal tool for one iPhone and one PC. This guide covers the one-time setup and the regular refresh.

For what each build contains and which ones passed on a phone, see [iOS build log](ios-builds.md).

## What you need

- A Windows 11 PC running the Mewt Photos backup app (see [Windows setup](setup-windows.md)).
- An iPhone on iOS 18 or later.
- A free Apple ID. A paid Apple Developer membership is not needed.
- The iPhone and the PC on the same Wi-Fi network.
- The latest `MewtPhotos.ipa` file. The builds are stored in iCloud Drive (`MewtPhotos\MewtPhotos.ipa`) or in the
  `MewtPhotos-ipa` download of the latest run of the `ios-build` workflow on GitHub.

## One-time setup

1. **Install Apple's software on the PC.** AltServer needs Apple's iCloud and iTunes components. Install them from
   Apple's website, not the Microsoft Store, because the Store versions do not work with AltServer. Restart the PC after
   installing.
2. **Install AltServer.** Download it from the AltStore website and run it. It sits in the notification area of the taskbar.
3. **Install AltStore on the iPhone.** With the iPhone connected to the PC by cable, choose AltServer from the taskbar, then
   **Install AltStore**, and pick your iPhone. Enter your free Apple ID when asked. AltServer signs AltStore with that ID.
4. **Trust the developer profile on the iPhone** if iOS asks. Settings → General → VPN & Device Management → your Apple ID → Trust.
5. **Turn on Developer Mode** on the iPhone if iOS asks for it (Settings → Privacy & Security → Developer Mode).

AltStore's own install steps change with its releases. If a step here no longer matches the screen, follow AltStore's current
instructions for the same step.

## Installing Mewt Photos

1. Open **AltStore** on the iPhone and go to **My Apps**.
2. Tap **+** and choose the `MewtPhotos.ipa` file. Copy it to the iPhone first if you can only see it on the PC: in iCloud
   Drive it appears in the Files app under iCloud Drive → MewtPhotos.
3. Wait for the install to finish. The app appears on the Home Screen.
4. Open Mewt Photos and pair it with the PC, as in [Windows setup](setup-windows.md).

## Keeping it working (every 7 days)

A free Apple ID signs an app for 7 days. After that the app stops opening until it is refreshed.

- Keep **AltServer** running on the PC and the iPhone on the same Wi-Fi.
- In AltStore on the iPhone, go to **My Apps** and tap **Refresh All**. Doing this once a week keeps the app working.
- A refresh keeps the app's data on the phone. The backup itself lives on the PC and is not affected.

## Limits of a free Apple ID

- Only a few apps can be installed this way at the same time. Remove an app you no longer use from AltStore to free a slot.
- Each new build replaces the old one. Install the latest `MewtPhotos.ipa` over the existing app rather than deleting it first.
- If the app stops opening and refresh fails, check that AltServer is running and that the iPhone is on the same network.
  If it still fails, see [Troubleshooting](troubleshooting.md).

## Privacy

Do not put your Apple ID or its password in a file in this repository, in a commit, or in an issue. AltServer stores the
sign-in on the PC; the iPhone only holds the signed app.
