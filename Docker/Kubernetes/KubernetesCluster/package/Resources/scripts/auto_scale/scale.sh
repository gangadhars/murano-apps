#!/bin/bash
# This file is invoked by autoscale service/metrics file
# This script scales nodes UP/Down by calling murano action IDs

# Arguments:
# $1 - up/down
# $2 - gce (optional)

# To schedule a Murano action we need to know Openstack IP,
# tenantname, username and password etc. Get those details from
# $data_file.
# Request a token using openstack api for Authentication purpose
# Get the environment ID by using enviroment name.
# Get the services of that environment using environemnt id
# Extract the available action IDs from the services of that environment
# Now schedule the action ID based on argument received

action=$1
gce=$2

if [ "$action" == "up" ] || [ "$action" == "down" ]
then
    if [  -z $gce ]
    then
       echo "Scaling $action .."
    elif [ $gce == "gce" ]
    then
       echo "Scaling $action gce.."
    else
       echo "Unknow parameter: $gce"
       exit 0
    fi
else
  echo "Unknown action: $action"
  exit 0
fi

data_file="/etc/autoscale/autoscale.conf"
env_name=$(awk -F "=" '/^env_name/ {print $2}' $data_file)
OPENSTACK_IP=$(awk -F "=" '/^OPENSTACK_IP/ {print $2}' $data_file)
tenant=$(awk -F "=" '/^tenant/ {print $2}' $data_file)
username=$(awk -F "=" '/^username/ {print $2}' $data_file)
password=$(awk -F "=" '/^password/ {print $2}' $data_file)
header="Content-type: application/json"

# to check http or https
function check-ssl()
{
    # $1 - IP-ADDR and $2 - PORT
    IP=$1
    PORT=$2
    echo | openssl s_client -connect $IP:$PORT 2>/dev/null | openssl x509 -noout -hash &> /dev/null
    if [ $? -eq 0 ] ; then
        echo "https"
    else
        echo "http"
    fi
}

PORT_KEYSTONE=5000
PORT_MURANO=8082
proto=$(check-ssl $OPENSTACK_IP $PORT_KEYSTONE)
KEYSTONE_URL="$proto://$OPENSTACK_IP:$PORT_KEYSTONE"
proto=$(check-ssl $OPENSTACK_IP $PORT_MURANO)
MURANO_URL="$proto://$OPENSTACK_IP:$PORT_MURANO"


# Get Keystone token
token=$(curl -s -k -d '{ "auth": {"tenantName": "'"$tenant"'", "passwordCredentials": {"username": "'"$username"'", "password": "'"$password"'"}}}' -H "$header" $KEYSTONE_URL/v2.0/tokens | jq --raw-output '.access.token.id')
if [ -z $token ]; then
    echo "Token Error"
    exit 1
fi
echo "Token: $token"
# Get the k8s environment ID.
envs=$(curl -s -k -H "X-Auth-Token: $token" $MURANO_URL/v1/environments)
total_envs=$(echo $envs | jq ".environments |  length")
count=0
while [ $count -lt $total_envs ]; do
    name=$(echo $envs | jq --raw-output ".environments[$count].name")
    if [ $env_name == $name ] ; then
        env_id=$(echo $envs | jq --raw-output ".environments[$count].id")
        break
    fi
    let count=count+1
done

if [ -z "$env_id" ] ; then
    echo "$env_name not found"
    exit 1
fi

echo "Env ID: $env_id"
services=$(curl -s -k -H "X-Auth-Token: $token" $MURANO_URL/v1/environments/$env_id/services)

# Get action Id's in easy and dirty way
scaleUp=$(echo $services | grep -o '[a-z0-9-]*_scaleNodesUp')
scaleDown=$(echo $services | grep -o '[a-z0-9-]*_scaleNodesDown')
scaleGceUp=$(echo $services | grep -o '[a-z0-9-]*_addGceNode')
scaleGceDown=$(echo $services | grep -o '[a-z0-9-]*_deleteGceNode')

if [ -z $gce ] && [ $action == "up" ] ; then
    echo "Action ID: $scaleUp"
    task=$(curl -s -k -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d '{"autoscale": "True"}' $MURANO_URL/v1/environments/$env_id/actions/$scaleUp)
elif [ -z $gce ] && [ $action == "down" ] ; then
    echo "Action ID: $scaleDown"
    task=$(curl -s -k -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d '{"autoscale": "True"}' $MURANO_URL/v1/environments/$env_id/actions/$scaleDown)
elif [ $gce == "gce" ] && [ $action == "up" ]; then
    echo "Action ID: $scaleGceUp"
    task=$(curl -s -k -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d '{"autoscale": "True"}' $MURANO_URL/v1/environments/$env_id/actions/$scaleGceUp)
elif [ $gce == "gce" ] && [ $action == "down" ]; then
    echo "Action ID: $scaleGceDown"
    task=$(curl -s -k -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d '{"autoscale": "True"}' $MURANO_URL/v1/environments/$env_id/actions/$scaleGceDown)
fi

task_id=$(echo $task | jq --raw-output ".task_id" 2> /dev/null)
if [ $? -ne 0 ] ; then
    #echo "error: $task"
    echo "Another deployment is going on.."
    exit 1
fi

if [ ! $task_id ]; then
    echo "Another deployment is going on.."
    exit 1
fi


echo "Task ID: $task_id"

echo "Waiting for task to complete.."

# function that checks task complition. 0 if finish, 1 otherwise
function finish_task {
   result=$(curl -s -k -H "X-Auth-Token: $token" $MURANO_URL/v1/environments/$env_id/actions/$task_id)
   if [ "$(echo $result | jq ".isException")" == null ] ; then
       echo "1"
   else
       echo "0"
   fi
}

# polling for task complition
while true; do
  stat=$(finish_task)
  if [ $stat == "0" ] ; then
    result=$(curl -s -k -H "X-Auth-Token: $token" $MURANO_URL/v1/environments/$env_id/actions/$task_id)
    if [ "$(echo $result | jq ".isException")" == "false" ] ; then
       echo "Done"
       exit 0
    else
       echo "Exception: $(echo $result | jq ".result")"
       exit 1
    fi
  fi
  sleep 1
done
