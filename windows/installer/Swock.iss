#ifndef BundleDir
  #define BundleDir "build/windows/installer"
#endif
#ifndef OutputDir
  #define OutputDir "build/windows/output"
#endif

[Setup]
AppId={{36DEAC90-91DB-4D15-AE16-E51B0B020D67}
AppName=Swock VPN
AppVersion=1.0.0
AppPublisher=Swock
DefaultDirName={autopf}\Swock VPN
DefaultGroupName=Swock VPN
OutputDir={#OutputDir}
OutputBaseFilename=Swock-Setup
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
PrivilegesRequired=admin
UninstallDisplayIcon={app}\Swock.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Swock VPN"; Filename: "{app}\Swock.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Swock VPN"; Filename: "{app}\Swock.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Swock.exe"; Description: "Launch Swock VPN"; Flags: postinstall nowait

[UninstallRun]
Filename: "{app}\swock_core.exe"; Parameters: "cleanup"; Flags: runhidden waituntilterminated; RunOnceId: "SwockVpnCleanup"

[UninstallDelete]
Type: filesandordirs; Name: "{commonappdata}\Swock"
