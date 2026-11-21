#ifndef MyAppVersion
  #error MyAppVersion is required.
#endif
#ifndef SourceDir
  #error SourceDir is required.
#endif
#ifndef OutputBaseFilename
  #error OutputBaseFilename is required.
#endif
#ifndef BinaryVersion
  #define BinaryVersion "0.0.0"
#endif
#ifndef ChineseMessagesFile
  #define ChineseMessagesFile "compiler:Languages\ChineseSimplified.isl"
#endif

[Setup]
AppId=NekoTribe
AppName=NekoTribe
AppVersion={#MyAppVersion}
AppPublisher=NekoTribe
AppPublisherURL=https://github.com/Cthaat/NekoTribe
DefaultDirName={localappdata}\Programs\NekoTribe
DefaultGroupName=NekoTribe
DisableDirPage=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\nekotribe.exe
VersionInfoVersion={#BinaryVersion}
VersionInfoProductName=NekoTribe
VersionInfoProductTextVersion={#MyAppVersion}
OutputBaseFilename={#OutputBaseFilename}
WizardStyle=modern
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "{#ChineseMessagesFile}"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\NekoTribe"; Filename: "{app}\nekotribe.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\NekoTribe"; Filename: "{app}\nekotribe.exe"; WorkingDir: "{app}"; Tasks: desktopicon
