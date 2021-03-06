[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# Assign Arguments to variables
$username=$args[0]
$hostname=$args[1]
$port=$args[2]
$timeout=$args[3]

# Pre-set Arguments instead
# TSPS Rest Credentials
$username="admin"
$password="admin"
$hostname="tsps-test"
$port="8043"
$timeout="10"


if (!$password) 
  {
  $password = Read-Host "Enter a Password"
  }

# Get-Token Function
# Used by functions so should be first in script
function Get-Token
{
$body = @{ 
  'username'=$username
  'password'=$password
  'tenantName'='*'
  }
$tokenJSON = Invoke-RestMethod -TimeoutSec $timeout -Method Post -Uri "https://${hostname}:${port}/tsws/10.0/api/authenticate/login" -Body $body 
if($?) {
  $Script:token = $tokenJSON.response.authToken
  }
}

# Get a List of Agents
# Requires Get-Token to be run first
function Get-ListOfAgents {
$patrolAgentJSON = Invoke-RestMethod -TimeoutSec $timeout -Method Post -Uri "https://${hostname}:${port}/tsws/10.0/api/unifiedadmin/Server/details" -Headers @{Authorization = "authToken $token"}  -ContentType "application/json" -Body "{}" 
if($?) {
  $Script:patrolAgentList = foreach($patrolAgent in $patrolAgentJSON.response.serverList.integrationServiceDetails.patrolAgentDetails) {
    if ( $patrolAgent ) {
	  echo "$($patrolAgent.hostname)/$($patrolAgent.agentPort)" 
      }
    }
  }
}

# Get Monitoring Studio License Count
# Requires Get-ListOfAgents and Get-Token to be run first
function Get-MonitoringStudioLicenseCount {
$ErrorActionPreference = 'SilentlyContinue'
$monitoringStudioLicenseCountTotal = 0
ForEach ($patrolAgent in $patrolAgentList){
  $monitoringStudioLicenseCount = ""
  $monitoringStudioLicenseCount = Invoke-RestMethod -TimeoutSec $timeout -Method Get -Uri "https://${hostname}:${port}/tsws/10.0/api/studio/${patrolAgent}/rest/namespace/X_HOST/numInstances" -Headers @{Authorization = "authToken $token"}
  if($?) { 
    if ( $monitoringStudioLicenseCount.value ) {
	  # We got a license count, so print
	  echo "$patrolAgent $($monitoringStudioLicenseCount.value)" 
	  $monitoringStudioLicenseCountTotal = $monitoringStudioLicenseCountTotal + $($monitoringStudioLicenseCount.value)
	  }
	else {
		echo "$patrolAgent Monitoring Studio GUI Not Installed"
      }
	}
  else {
    echo "$patrolAgent Monitoring Studio KM Not Responding" 
	# If a query fails, we have to go back and get a new token
    Get-Token
	}
  }
echo "Total Monitoring Studio License Count: $monitoringStudioLicenseCountTotal"
}

# Get Hardware License Count
# Requires Get-ListOfAgents and Get-Token to be run first
function Get-HardwareLicenseCount {
$ErrorActionPreference = 'SilentlyContinue'
$hardwareLicenseCountTotal = 0
ForEach ($patrolAgent in $patrolAgentList){
  $hardwareLicenseCount = ""
  $hardwareCount = Invoke-RestMethod -TimeoutSec $timeout -Method Get -Uri "https://${hostname}:${port}/tsws/10.0/api/studio/${patrolAgent}/rest/namespace/MS_HW_KM/HardwareSentry/Count-Host" -Headers @{Authorization = "authToken $token"}
  if($?) { 
    echo "$patrolAgent $($hardwareCount.value)" 
	$hardwareLicenseCountTotal = $hardwareLicenseCountTotal + $($hardwareCount.value)
	}
  else {
    echo "$patrolAgent Hardware KM Not Installed or Not Responding" 
	# If a query fails, we have to go back and get a new token
    Get-Token
	}
  }
echo "Total Hardware Sentry License Count: $hardwareLicenseCountTotal"
}

# Get Hardware Inventories
# Requires Get-ListOfAgents and Get-Token to be run first
function Get-HardwareInventories {
$ErrorActionPreference = 'SilentlyContinue'
ForEach ($patrolAgent in $patrolAgentList){
  # Get the Monitoring Studio KM Version (To ensure it's installed)
  $monitoringStudioVersion = ""
  $monitoringStudioVersion = Invoke-RestMethod -TimeoutSec $timeout -Method Get -Uri "https://${hostname}:${port}/tsws/10.0/api/studio/${patrolAgent}/rest/agent" -Headers @{Authorization = "authToken $token"} 
  # If a query fails, we have to go back and get a new token
  if(!$?) { 
     Get-Token
    }
  if( $monitoringStudioVersion.studioVersion.string -match '^1' ) {
    echo "$patrolAgent has Monitoring Studio GUI $($monitoringStudioVersion.studioVersion.string) installed"
    } else {
	echo "$patrolAgent does not have Monitoring Studio GUI installed or is not responding $($monitoringStudioVersion.studioVersion.string)"
	# skip everything else for this Patrol Agent
	continue
	}
  # Get the Hardware KM Version (To ensure it's compatible.)
  $hardwareVersion = ""
  $hardwareVersion = Invoke-RestMethod -TimeoutSec $timeout -Method Get -Uri "https://${hostname}:${port}/tsws/10.0/api/studio/${patrolAgent}/rest/config/SENTRY/HARDWARE/currentVersion" -Headers @{Authorization = "authToken $token"; "accept"="application/json" }
  # If a query fails, we have to go back and get a new token
  if(!$?) { 
     Get-Token
    }
  if ( $hardwareVersion.value -eq "" ) {
    echo "$patrolAgent does not have Hardware KM installed"
	# skip everything else for this Patrol Agent
	continue	
    } 
  elseif ( $hardwareVersion.value -match '^10.[2-9]' -Or $hardwareVersion.value -match '^1[1-9]' ) {
	echo "$patrolAgent has Hardware KM $($hardwareVersion.value) installed"
    }
  else {
    echo "$patrolAgent has Hardware KM $($hardwareVersion.value) installed, which is not compatible"
	# skip everything else for this Patrol Agent
	continue
    }
	
  # Ok, we're happy suitable versions of the Monitoring Studio KM and Hardware KM are installed.
  # Get a Monitored Host List
  if(!(test-path .\Hardware-Inventories )) { New-Item -ItemType Directory -Force -Path ./Hardware-Inventories | Out-Null }
  $hardwareHostListCSV = ""
  $hardwareHostListCSV = Invoke-RestMethod -TimeoutSec $timeout -Method Get -Uri "https://${hostname}:${port}/tsws/10.0/api/studio/${patrolAgent}/rest/namespace/MS_HW_MAIN/instances" -Headers @{Authorization = "authToken $token"; "accept"="application/json" }
  # If a query fails, we have to go back and get a new token
  if(!$?) { 
    Get-Token
    }
  if ($hardwareHostListCSV.value -eq "") { 
    echo "$patrolAgent is not monitoring any hardware hosts"
	# skip everything else for this Patrol Agent
	continue	
    }
  # The hostlist is a list inside the value, so we need to convert it to an object list PowerShell likes
  $hardwareHostList = $hardwareHostListCSV.value  |  ConvertFrom-Csv -Header 'value'
  ForEach ( $hardwareHost in $hardwareHostList ) { 
    if ($hardwareHost.value -eq "") { continue }
    $hardwareHostValue = $hardwareHost.value
	$hardwareHostInventory=Invoke-RestMethod -TimeoutSec $timeout -Method Get -Uri "https://${hostname}:${port}/tsws/10.0/api/studio/${patrolAgent}/rest/mshw/report/$hardwareHostValue" -Headers @{Authorization = "authToken $token"}
	# If a query fails, we have to go back and get a new token
    if(!$?) { 
       Get-Token
      }    
	# Create a folder for this Agent Instance and Output json Inventory File
	if(!(test-path .\Hardware-Inventories\$patrolAgent )) { New-Item -ItemType Directory -Force -Path ./Hardware-Inventories/$patrolAgent | Out-Null }
	$hardwareHostInventory | ConvertTo-Json | Out-File .\Hardware-Inventories\$hardwareHostValue.json
	$hardwareName = $hardwareHostInventory | Where-Object className -eq "MS_HW_ENCLOSURE" | ForEach-Object {$_.name}
	if ($hardwareName) {
	  echo "$patrolAgent Monitors $hardwareHostValue which is a $hardwareName"
	  }
	else {
	  echo "$patrolAgent Monitors $hardwareHostValue does not have an enclosure.  Suspect monitoring not working correctly."
	  }
    }
  }
}

#
#
# Main Section
#
#


Get-Token
# echo $token

Get-ListOfAgents
# echo $patrolAgentList

Get-MonitoringStudioLicenseCount
Get-HardwareLicenseCount
Get-HardwareInventories