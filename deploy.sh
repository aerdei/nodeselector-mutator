#!/bin/bash
set -eu 

project_name="nodeselector-mutator"
app_name="nodeselector-mutator"
auto_yes=false

# Function for deploying a mutating admission controller
ocp_deploy() {
    # Check your privileges
    for resource in "bc" "dc" "csr"; do 
        [[ "$(oc auth can-i create $resource 2>&1 | head -n1 | awk '{print $1;}')" = "yes" ]] ||
                { echo "Logged in user has no privilege to create $resource-s."; return 1; }
    done
    [[ "$(oc auth can-i approve csr 2>&1 | head -n1 | awk '{print $1;}')" = "yes" ]] ||
            { echo "Logged in user has no privilege to approve csr-s."; return 1; }
    # Create OpenShift project
    oc new-project "$project_name"
    # Generate private key
    openssl genrsa -out ./server-key.pem 2048
    # Create certificate signing request config template
    cat <<-EOF > ./csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = $app_name
DNS.2 = $app_name.$project_name
DNS.3 = $app_name.$project_name.svc
EOF
    # Create certificate signing request
    openssl req -new -key ./server-key.pem -subj "/CN=$app_name.$project_name.svc" -out ./server.csr -config ./csr.conf
    # Create csr in OpenShift
    cat <<-EOF | oc create -f -
{
  "apiVersion": "certificates.k8s.io/v1beta1",
  "kind": "CertificateSigningRequest",
  "metadata": {
    "name": "$app_name"
  },
  "spec": {
    "groups": [
      "system:authenticated"
    ],
    "request": "$(base64 ./server.csr | tr -d '\n')",
    "usages": [
      "digital signature",
      "key encipherment",
      "server auth"
    ]
  }
}
EOF
    # Check if csr has been created
    [[ ! "$(oc get csr "$app_name" 2>&1 | grep -q 'Error')" ]] || { echo "Failed to create csr"; return 1; }
    # Approve csr
    [[ "$(oc adm certificate approve "$app_name" 2>&1 | grep -q 'approved')" ]] || { echo "Failed to approve certificate signing request"; return 1; }
    # Sleep a couple of seconds so that the csr can be issued
    sleep 3
    # Check if csr has been issued
    [[ "$(oc get csr | grep "$app_name" | grep -q 'Issued')" ]] || { echo "Csr was never issued."; return 1; }
    # Get the server certificate
    oc get csr "$app_name" -o jsonpath='{.status.certificate}' | openssl base64 -d -A -out ./server-cert.pem
    # Get the CA bundle
    ca_bundle=""
    ca_bundle=$(oc get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 | tr -d '\n')
    # Create MutatingWebhookConfiguration in OpenShift
    cat <<EOF | oc create -f -
{
  "apiVersion": "admissionregistration.k8s.io/v1beta1",
  "kind": "MutatingWebhookConfiguration",
  "metadata": {
    "name": "${app_name}-mwc",
    "labels": {
      "app": "$app_name"
    }
  },
  "webhooks": [
    {
      "name": "${app_name}.openshift.com",
      "clientConfig": {
        "service": {
          "name": "$app_name",
          "namespace": "$project_name",
          "path": "/mutator"
        },
        "caBundle": "$ca_bundle"
      },
      "rules": [
        {
          "operations": [
            "CREATE",
            "UPDATE"
          ],
          "apiGroups": [
            "*"
          ],
          "apiVersions": [
            "v1"
          ],
          "resources": [
            "deploymentconfigs"
          ]
        }
      ]
    }
  ]
}
EOF
    # Import the Python 3.6 S2I image
    [[ "$(oc import-image python-36-rhel7 --from=registry.access.redhat.com/rhscl/python-36-rhel7 --confirm | grep -q 'The import completed successfully.')" ]] ||
            { echo "Could not import image"; return 1; }
    # Create a new buildConfig for building the mutating webhook
    [[ "$(oc new-build --image-stream=python-36-rhel7 --to "$app_name" --binary=true | grep -q 'Success')" ]] ||
            { echo "Could not create imagestream or buildconfig"; return 1; }
    # Start the build and follow it
    oc start-build "$app_name" --from-dir=. -F
    # Process the template for creating deploymentConfig and service
    oc process -f ./openshift_template.yaml -p APP_NAME="$app_name" -p PROJECT_NAME="$project_name" | oc create -f -
}

# Function for deleting files and OpenShift resources created by the script
ocp_purge() {
    oc delete mutatingwebhookconfiguration "$app_name"-mwc || true
    oc delete project "$project_name" || true
    oc delete csr "$app_name" || true
    rm -fv ./csr.conf
    rm -fv ./server-key.pem
    rm -fv ./server-cert.pem
}

# Print the usage message
print_usage() {
    cat <<-EOF
Usage: deploy.sh COMMAND

Deploy a mutating admission controller on OpenShift

Commands:
  deploy              Create the files and deploy the OpenShift resources
  purge               Delete the files and OpenShift resources

Options:
  --project-name      OpenShift project where the resources should be deployed
                      Default: nodeselector-mutator
  --app-name          Application name. Will apply to buildconfig, deploymentconfig, and service
                      Default: nodeselector-mutator
  --confirm           Do not prompt for confirmation
  --help              Print usage
EOF
}

# Digest options
set_opts() {
    shift
    while [[ "$#" -gt 0 ]]
        do
        case "$1" in
            --app-name)
                app_name="$2"
                shift 2
                ;;
            --project-name)
                project_name="$2"
                shift 2
                ;;
            --confirm)
                auto_yes=true
                shift
                ;;
            --help)
                print_usage
                shift
                ;;
            *)
                echo "Wrong option \"$1\""
                print_usage
                exit 1
        esac
    done
}

# Set dir to script's
cd "$(dirname "$0")" || exit
# Handle script commands and options
[[ "$#" -gt 0 ]] || { print_usage; exit 1; }
if [[ "$1" = "deploy" ]]; then
    set_opts "$@"
    echo "This will deploy the mutator with the name $app_name into the project $project_name"
    if [[ "$auto_yes" != true ]]; then
        read -rp "Type \"y\" to continue... " answer
        if [[ "${answer,,}" = "y" ]]; then
            ocp_deploy
        fi
    else
        ocp_deploy
    fi
elif [[ "$1" = "purge" ]]; then
    set_opts "$@"
    cat <<-EOF
This will delete the following resources:
    csr.conf
    server-key.pem
    server-cert.pem
    OpenShift project "$project_name"
    OpenShift mutatingwebhookconfiguration "${app_name}-mwc"
    OpenShift csr "$app_name"
EOF
    if [[ "$auto_yes" != true ]]; then
        read -rp "Type \"y\" to continue... " answer
        if [[ "${answer,,}" = "y" ]]; then
            ocp_purge
        fi
    else
        ocp_purge
    fi
else
    echo "Unknown command \"$1\""
    print_usage
    exit 1
fi
