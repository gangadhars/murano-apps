#!/usr/bin/env python

# Copyright 2015 Google Inc. All Rights Reserved.
# Copyright 2016 Vedams Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

'''This file create/deletes GCE instance
To create: compute_api.py --action=insert --zone=<zone> <inst-name>
To delete: compute_api.py --action=delete --zone=<zone> <inst-name>
'''

import argparse
import json
import sys
import time
from apiclient import discovery
from oauth2client.client import GoogleCredentials

# GCE service account private key file location
CREDENTIALS_FILE = "/etc/autoscale/MuranoAppDevelopment.json"


def list_instances(compute, project, zone):
    result = compute.instances().list(project=project, zone=zone).execute()
    return result['items']


def create_instance(compute, project, zone, name):
    source_disk_image = \
        "projects/ubuntu-os-cloud/global/images/ubuntu-1404-trusty-v20151113"
    machine_type = "zones/%s/machineTypes/n1-standard-1" % zone
    id_rsa = open('/root/.ssh/id_rsa.pub', 'r').read()
    script = 'echo "' + id_rsa[:-2] + '" >> ~/.ssh/authorized_keys'

    conf = {
        "name": name,
        "machineType": machine_type,
        "disks": [
            {
                "type": "PERSISTENT",
                "boot": True,
                "mode": "READ_WRITE",
                "autoDelete": True,
                "deviceName": name,
                "initializeParams": {
                    "sourceImage": source_disk_image,
                    "diskSizeGb": "10"
                }
            }
        ],
        "networkInterfaces": [
            {
                "network": "global/networks/default",
                "accessConfigs": [
                    {
                        "name": "External NAT",
                        "type": "ONE_TO_ONE_NAT"
                    }
                ]
            }
        ],
        "description": "Murano Kubernetes application node",
        "metadata": {
            "items": [
                {
                    "key": "startup-script",
                    "value": script
                }
            ]
        }
    }

    return compute.instances().insert(
        project=project,
        zone=zone,
        body=conf).execute()


def delete_instance(compute, project, zone, name):
    return compute.instances().delete(
        project=project,
        zone=zone,
        instance=name).execute()


def wait_for_operation(compute, project, zone, operation):
    while True:
        result = compute.zoneOperations().get(
            project=project,
            zone=zone,
            operation=operation).execute()

        if result['status'] == 'DONE':
            if 'error' in result:
                raise Exception(result['error'])
            return result

        time.sleep(4)


def external_ip(compute, project, zone, instance_name):
    instances = list_instances(compute, project, zone)
    for instance in instances:
        if instance['name'] == instance_name:
            ip = instance['networkInterfaces'][0]['accessConfigs'][0]['natIP']
            return ip


def main(action, zone, instance_name):
    credentials = GoogleCredentials.from_stream(CREDENTIALS_FILE)
    compute = discovery.build('compute', 'v1', credentials=credentials)

    with open(CREDENTIALS_FILE) as jsonfile:
        data = json.load(jsonfile)
    project = data["project_id"]

    if action == "insert":
        operation = create_instance(compute, project, zone, instance_name)
        wait_for_operation(compute, project, zone, operation['name'])
        print(external_ip(compute, project, zone, instance_name))
    elif action == "delete":
        operation = delete_instance(compute, project, zone, instance_name)
        wait_for_operation(compute, project, zone, operation['name'])
    else:
        print("Unknow action")
        sys.exit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        '--action',
        help='Action to perform insert|delete')
    parser.add_argument(
        '--zone',
        default='us-central1-f',
        help='Compute Engine zone to deploy to.')
    parser.add_argument(
        'name', help='New instance name.')

    args = parser.parse_args()
    if args.action != "insert" and args.action != "delete":
        print ("Unknow action")
        sys.exit(1)

    main(args.action, args.zone, args.name)
