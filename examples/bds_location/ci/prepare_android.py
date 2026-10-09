from pathlib import Path
# Run from project root after `flutter create --platforms=android --org=app.local --project-name=bds_location .`.
p = Path('android/app/src/main/AndroidManifest.xml')
s = p.read_text().replace('<manifest xmlns:android="http://schemas.android.com/apk/res/android">', '''<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" tools:node="remove" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" tools:node="remove" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" tools:node="remove" />
    <uses-permission android:name="android.permission.INTERNET" tools:node="remove" />''')
s = s.replace('android:label="bds_location"', 'android:label="BDS定位" android:allowBackup="false"')
p.write_text(s)
