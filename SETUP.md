# Flutter Setup & Testing Guide
## Pick List Tracker — Windows Development Setup

---

## Step 1 — Install Flutter SDK

**Method 1: Using VS Code (Recommended & Easiest)**
1. Install **Visual Studio Code** if you haven't already.
2. Open VS Code, go to the Extensions tab (`Ctrl+Shift+X`).
3. Search for and install the **Flutter** extension.
4. Press `Ctrl+Shift+P` to open the Command Palette.
5. Type `Flutter: New Project` and hit Enter.
6. A prompt will appear in the bottom right corner saying "Could not find a Flutter SDK. Please ensure flutter is installed and in your PATH...". Click **Download SDK**.
7. Select a folder to install Flutter (e.g. `C:\dev`).
8. Wait for the download and installation to complete. VS Code will automatically add Flutter to your PATH and set everything up.

**Method 2: Manual Installation**
1. Go to **https://docs.flutter.dev/get-started/install/windows** or download directly:  
   **https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.24.0-stable.zip**
2. Extract to a folder **without spaces or special characters**, e.g.: `C:\flutter`
3. Add Flutter to your PATH:
   - Open **Start → Search → "Environment Variables"**
   - Under **User Variables → Path → Edit → New**
   - Add: `C:\flutter\bin`
   - Click OK on all dialogs
4. Restart any open terminal/VSCode windows.

**Verify installation:**
```powershell
flutter --version
# Should print: Flutter 3.x.x ...

flutter doctor
# Run this and fix any red X items it reports
```
---

## Step 2 — Install Android Studio (for emulator / USB debug)

1. Download from **https://developer.android.com/studio**
2. Install with default settings (includes Android SDK)
3. Run `flutter doctor` again — it should show ✅ for Android toolchain

### Accept Android SDK licenses:
```powershell
flutter doctor --android-licenses
# Press 'y' to accept each one
```

---

## Step 3 — Get Project Dependencies

Open a terminal in the project folder:
```powershell
cd "d:\MY_PROJECTS\Picklist Tracker"
flutter pub get
```

If it fails with "pubspec.yaml not found" — make sure you're in the right folder.

---

## Step 4A — Run on PC (Windows Desktop, fastest for testing)

> Fastest way — no Android device needed. Runs as a native Windows app.

```powershell
cd "d:\MY_PROJECTS\Picklist Tracker"
flutter run -d windows
```

> **Note:** File picker dialogs will open Windows file picker. Excel files work exactly the same.  
> SQLite database is stored in your AppData folder.

---

## Step 4B — Run on Android Emulator

1. Open Android Studio → **Device Manager** → Create a new tablet device  
   Recommended: **Pixel Tablet API 34** (10-inch portrait)

2. Start the emulator (press ▶ Play button)

3. Run:
   ```powershell
   flutter run
   # Flutter auto-detects the running emulator
   ```

---

## Step 4C — Run on a Physical Android Tablet (recommended for real testing)

1. On the tablet: **Settings → About → tap "Build Number" 7 times** to enable Developer Options
2. **Settings → Developer Options → USB Debugging → Enable**
3. Connect tablet to PC via USB
4. Accept the "Allow USB debugging?" dialog on the tablet

5. Verify tablet is detected:
   ```powershell
   flutter devices
   # Should show your tablet name
   ```

6. Run:
   ```powershell
   flutter run
   ```

---

## Step 5 — Build APK for distribution

Once you're happy with the testing:
```powershell
flutter build apk --release
```

Output: `build\app\outputs\flutter-apk\app-release.apk`

Copy this APK to the tablet via USB, USB drive, or network share, then install it.

---

## Useful Dev Commands

| Command | What it does |
|---------|-------------|
| `flutter run` | Run in debug mode with hot-reload |
| `flutter run --release` | Run release build (no debug overlay) |
| `flutter run -d windows` | Run as Windows desktop app |
| `flutter hot-reload` | Press `r` in terminal while running |
| `flutter hot-restart` | Press `R` in terminal while running |
| `dart run test/run_tests.dart` | Run the core logic verification tests |
| `flutter build apk` | Build debug APK |
| `flutter build apk --release` | Build release APK |

---

## Common Issues

**`flutter doctor` shows "Android licenses not accepted"**  
→ Run: `flutter doctor --android-licenses` and press `y`

**`flutter run` shows "No devices found"**  
→ Either start emulator first, or connect a tablet via USB with USB debugging on

**File picker shows no Excel files**  
→ On emulator: copy `.xlsx` files to the emulator first via `Device File Explorer` in Android Studio  
→ On device: copy Excel files to the tablet's Downloads folder via USB

**App crashes on start**  
→ Run `flutter run` (not `--release`) and check the terminal for error output

---

## Where is the SQLite database?

- **Windows:** `%APPDATA%\com.example.picklist_tracker\`
- **Android:** `/data/data/com.example.picklist_tracker/databases/`  
  (accessible via Android Studio → Device File Explorer)

---

## Future: Export to Network Folder

Planned (not yet implemented). Options:
1. **SMB network share** — mount a `\\SERVER\Share` path and write the exported `.xlsx` directly there
2. **Auto-copy to fixed path** — admin configures an output folder path; on export, file is also copied there
3. **FTP/SFTP** — push to a server on the same network

This will be a new **Export Settings** tab in AdminScreen.
