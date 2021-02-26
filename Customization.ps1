$fslogixURI = "https://aka.ms/fslogix_download"
# Download and expand the installer
New-Item -Name "Customizations" -ItemType Directory -Path "C:\" -Force
$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile("https://aka.ms/fslogix_download","C:\Customizations\fslogix.zip")
Expand-Archive -Path C:\Customizations\fslogix.zip -DestinationPath C:\Customizations\fslogix
Start-Process "C:\Customizations\fslogix\x64\Release\FSLogixAppsSetup.exe" -ArgumentList "/install /quiet /norestart"
Remove-Item "C:\Customizations" -Recurse -Force