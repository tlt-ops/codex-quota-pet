; Remove only the startup entry owned by this application on uninstall.
!macro customUnInstall
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "CodexQuotaPetWatcher"
!macroend
