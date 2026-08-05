# Google sign-in and Drive backup setup

Google sign-in is optional. Guest mode and local tournament hosting work without
any Google Cloud configuration. This setup is only required for backing up the
app state to the signed-in user's private Google Drive application-data folder.

The Android OAuth identity is defined by both the application package and the
certificate that signed the installed APK. Configure all credentials in the
same Google Cloud project.

## 1. Create or select a Google Cloud project

Open the [Google Cloud console](https://console.cloud.google.com/) and create a
project for MTG Tournament, or select the project already used for this app.
The Drive API, OAuth consent configuration, and Android OAuth clients described
below must all belong to this project.

## 2. Enable the Google Drive API

In **APIs & Services > Library**, find **Google Drive API** and enable it for the
selected project.

The app requests only this scope:

```text
https://www.googleapis.com/auth/drive.appdata
```

This scope gives the app access to its own hidden `appDataFolder`; it does not
grant general access to the user's Drive files.

## 3. Configure the OAuth consent screen

In **Google Auth Platform**, complete the branding, audience, and data-access
pages:

1. Add the application name and support/contact details.
2. Choose an **External** audience when ordinary consumer Google accounts must
   be able to sign in.
3. Add `https://www.googleapis.com/auth/drive.appdata` under data access.
4. If the app remains in **Testing**, add every account used for testing as a
   test user. A test account that is not listed will be refused at consent.

Do not add an account password, OAuth client secret, or any other credential to
this repository. Sign in interactively on the Android device.

## 4. Register the Android OAuth clients

Create an OAuth client of type **Android** for every certificate that can sign
the app. Every client uses this package name:

```text
com.giuseppe.mtg.mtg_tourney
```

Create the following clients for the current builds:

| Build | SHA-1 certificate fingerprint |
| --- | --- |
| Published release APK | `49:AF:39:33:33:CC:EE:F9:B2:9A:80:42:AB:61:65:D5:E1:3E:9A:BE` |
| Local debug build | `61:B2:5B:E4:F6:90:EC:49:6E:98:CE:38:2B:23:08:8E:03:5E:5D:70` |

Do not substitute the package name, omit a colon from a fingerprint, or attach
the client to a different Cloud project. Google Play services reports status
code `10` (`DEVELOPER_ERROR`) when the installed package/certificate pair does
not match an Android OAuth client.

If the app is later distributed through Google Play with **Play App Signing**,
Google signs delivered APKs with the Play app-signing key rather than the local
upload key. Copy the app-signing SHA-1 from **Play Console > Setup > App
integrity** and create another Android OAuth client for that fingerprint and the
same package name. Keep the upload/release client if APKs signed locally are
still distributed directly.

### Confirm a build's fingerprint

For a built APK, verify the certificate instead of assuming which key was used:

```powershell
keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk
```

For the default local debug keystore on Windows:

```powershell
keytool -list -v -alias androiddebugkey -keystore "$env:USERPROFILE\.android\debug.keystore" -storepass android -keypass android
```

## 5. Wait for propagation and test on Android

OAuth registration is server-side, so a correctly signed installed APK does not
need to be rebuilt just to pick up the new Android client. Changes can take
several minutes to propagate. After creating the clients:

1. Retry sign-in from the installed release APK after propagation.
2. Sign in interactively and approve the private app-data Drive permission.
3. Create or update local data, restart the app, and confirm that the state can
   be restored after signing in again.

If the old failure is cached, clear this app's storage or reinstall the same
signed APK and retry.

The current integration uses the Android OAuth client to obtain an access token
for the Drive API. It does not need an OAuth client secret, a Web OAuth client,
`serverClientId`, or a committed `google-services.json` file for this
access-token-only flow.

If a correctly registered package and fingerprint still produce status code
`10`, first recheck that the installed APK is signed by the expected certificate
and wait for Cloud configuration propagation. Reinstalling the app is usually
enough. Only on a dedicated test device, and only as a last resort for stale
Google Play services state, clear the Google Play services cache and retry;
this can require reauthorizing Google accounts on the device.

## Troubleshooting checklist

- **Status code 10 / `DEVELOPER_ERROR`:** package name, signing SHA-1, or Cloud
  project does not match the installed APK.
- **Consent says access is blocked:** add the account as a test user, or move the
  consent configuration to the appropriate publishing state.
- **Sign-in succeeds but Drive backup fails:** confirm that the Drive API is
  enabled in the same project and that `drive.appdata` is present in data access.
- **Debug works but a release APK fails:** create the release-signing Android
  client; debug and release certificates are different.
- **Direct APK works but the Play build fails:** register the Play app-signing
  SHA-1 in addition to the upload/release SHA-1.
