# Get Token Function
getToken() {
tokenJSON=`curl -k --silent --max-time $timeout --location --request POST https://$hostname:$port/tsws/10.0/api/authenticate/login \
--header 'Content-Type: application/x-www-form-urlencoded' \
--data-urlencode username=$username \
--data-urlencode password=$password \
--data-urlencode tenantName=* `
exitCode=$?; if [ "$exitCode" != "0" ]; then echo ${FUNCNAME[0]} Curl Failed ; exit 1; fi  
token=`echo $tokenJSON | jq -r '.response.authToken' `
if [ "$token" == "null" ] ; then echo ${FUNCNAME[0]} JSON Extract Failed ; exit 1 ; fi 
}

# Get List of Patrol Agents
getListOfPatrolAgents() {
patrolAgentJSON=`curl -k --silent --max-time $timeout --location --request POST "https://$hostname:$port/tsws/10.0/api/unifiedadmin/Server/details" \
--header "Authorization: authToken $token" -H 'content-type:application/json' -d'{}' `
exitCode=$?; if [ "$exitCode" != "0" ]; then echo ${FUNCNAME[0]} Curl Failed ; exit 1; fi   

patrolAgentList=`echo $patrolAgentJSON | jq -r '.response.serverList[].integrationServiceDetails[]' | jq -r '.patrolAgentDetails[] | "\(.hostname)/\(.agentPort)" ' 2>/dev/null `
exitCode=$?; if [ "$exitCode" != "0" ];  then echo ${FUNCNAME[0]} JSON Extract Failed ; exit 1 ; fi 
}


# Get Monitoring Studio License Usage on a Patrol Agent
# Requires $patrolAgent in the format fqdn/port  e.g. patrolagent1.sentrytest.com/3181
# Returns monitoringStudioLicenseCount.  If null then the KM is not installed
getMonitoringStudioLicenseCount() {
local monitoringStudioLicenseCountJSON=`curl -k --silent --max-time $timeout --location --request GET "https://$hostname:$port/tsws/10.0/api/studio/$1/rest/namespace/X_HOST/numInstances" \
--header "Authorization: authToken $token"`
exitCode=$?; if [ "$exitCode" != "0" ]; then echo ${FUNCNAME[0]} Curl Failed $1 ; return 1; fi 

local monitoringStudioLicenseCount=`echo $monitoringStudioLicenseCountJSON | jq -r '.value'`
echo ${monitoringStudioLicenseCount%.*}
}


# Get Hardware License Usage on a Patrol Agent
# Requires $patrolAgent in the format fqdn/port  e.g. patrolagent1.sentrytest.com/3181
# Returns hardwareLicenseCount.  If null then the KM is not installed
getHardwareLicenseCount() {
local hardwareLicenseCountJSON=`curl -k --silent --max-time $timeout --location --request GET "https://$hostname:$port/tsws/10.0/api/studio/$1/rest/namespace/MS_HW_KM/HardwareSentry/Count-Host" \
  --header "Authorization: authToken $token"`
exitCode=$?; if [ "$exitCode" != "0" ]; then echo ${FUNCNAME[0]} Curl Failed $1 ; return 1; fi 
local hardwareLicenseCount=`echo $hardwareLicenseCountJSON | jq -r '.value'`
echo ${hardwareLicenseCount%.*}
}

# Get Hardware Inventories directly from a Patrol Agent
# Requires $patrolAgent in the format fqdn/port  e.g. patrolagent1.sentrytest.com/3181
getHardwareInventories() {
# Get the Monitoring Studio KM Version (To ensure it's installed)
local monitoringStudioVersionJSON=`curl -k --silent --max-time $timeout --location --request GET "https://$hostname:$port/tsws/10.0/api/studio/$1/rest/agent" \
  --header "Authorization: authToken $token"`
local monitoringStudioVersion=`echo $monitoringStudioVersionJSON | jq -r .studioVersion.string`
if [[ $monitoringStudioVersion =~ ^1 ]]; 
  then echo $1 has Monitoring Studio GUI $monitoringStudioVersion installed
  else echo $1 does not have Monitoring Studio GUI installed or is not responding; 
  fi

# Get the Hardware KM Version (To ensure it's compatible.)
local hardwareVersionJSON=`curl -k --silent --max-time $timeout --location --request GET "https://$hostname:$port/tsws/10.0/api/studio/$1/rest/config/SENTRY/HARDWARE/currentVersion" \
  --header "Authorization: authToken $token" -H 'Accept:application/json'`
local hardwareVersion=`echo $hardwareVersionJSON | jq -r '.[].value'`
if [ "$hardwareVersion" == "null" ]
  then echo $1 does not have Hardware KM installed; return 1
  fi
if [[ $hardwareVersion =~ (^10.[2-9]) || $hardwareVersion =~ (^1[1-9]) ]]; 
  then echo $1 has Hardware KM $hardwareVersion installed
  else echo $1 has Hardware KM $hardwareVersion installed which is not compatible; return 1
  fi
  
# Get an Inventory of Systems Monitored by Hardware KM
local hostListJSON=`curl -k --silent --max-time $timeout --location --request GET "https://$hostname:$port/tsws/10.0/api/studio/$1/rest/namespace/MS_HW_MAIN/instances" \
  --header "Authorization: authToken $token" `
local hostList=`echo $hostListJSON | jq -r '.value'`
exitCode=$?; if [ "$exitCode" != "0" ]; then echo ${FUNCNAME[0]} HostList Curl Failed $1 ; return 1; fi 
if [ "$hostList" == "null" ]; then echo $1 is not monitoring any hosts ; return 1; fi 
# Create a Directory to Store Hardware Inventories
mkdir -p ./HardwareInventory/$1
# For Each Monitored System do an Inventory
for host in $hostList
  do
  if [ "$host" != "null" ] 
    then 
    local hostInventoryJSON=`curl -k --silent --max-time $timeout --location --request GET "https://$hostname:$port/tsws/10.0/api/studio/$1/rest/mshw/report/$host" \
        --header "Authorization: authToken $token"`
    echo $hostInventoryJSON > ./HardwareInventory/$1/${host//\~/-}.json
    local hostType=`echo $hostInventoryJSON | jq -r '.[] | select (.className=="MS_HW_ENCLOSURE") | .name' `
    if [ "$hostType" != "" ]
       then 
       echo $1 Monitors $host which is a $hostType
       else 
       echo $1 Monitors $host which does not have an enclosure.  Suspect monitoring not working correctly.
       fi
    fi
  done
}

#
# Initialization
#

# Assign Arguments to variables
username=$1
hostname=$2
port=$3
timeout=$4

# Pre-set Arguments instead
#TSPS Rest Credentials
#username=
#password=
#hostname=
#port=
#timeout=10

# TSPS Password - Prompt if not already set
if [ -z "$password" ]
  then 
  echo -n Password:
  read -s password
  echo
  fi

#
# Main
#

# Get Token
getToken
# echo $token

# Get List of Patrol Agent
getListOfPatrolAgents
# echo $patrolAgentList


# Get Hardware KM License Count-Host
for patrolAgent in $patrolAgentList 
  do 
  hardwareLicense=`getHardwareLicenseCount $patrolAgent`
  if [[ $hardwareLicense =~ ^[0-9]+$ ]]
    then
	echo "$patrolAgent $hardwareLicense"
    totalhardwareLicense=$((totalhardwareLicense+hardwareLicense))
	else
	echo "$patrolAgent KM_not_installed"
	fi
  done
echo "Total Hardware: $totalhardwareLicense"


# Get Monitoring Studio License Count-Host
for patrolAgent in $patrolAgentList 
  do 
  monitoringStudioLicense=`getMonitoringStudioLicenseCount $patrolAgent`
  if [[ $monitoringStudioLicense =~ ^[0-9]+$ ]]
    then
	echo "$patrolAgent $monitoringStudioLicense"
    totalMonitoringStudioLicense=$((totalMonitoringStudioLicense+monitoringStudioLicense))
	else
	echo "$patrolAgent KM_not_installed"
	fi
  done
echo "Total Monitoring Studio: $totalMonitoringStudioLicense"

# Get Hardware Inventories
for patrolAgent in $patrolAgentList 
  do 
  getHardwareInventories $patrolAgent
  done
  