#!/bin/bash
set -eu 

project_name="nodeselector-mutator"
app_name="nodeselector-mutator"
auto_yes=false

# Function for deploying a mutating admission controller
ocp_deploy() {
    echo "This will deploy the mutator with the name $app_name into the project $project_name"
    handle_confirm || exit 1
    # Check your privileges
    for resource in "bc" "dc" "csr"; do 
        oc auth can-i -q create "$resource" ||
                { echo "Logged in user has no privilege to create $resource-s."; return 1; }
    done
    oc auth can-i -q approve csr ||
        { echo "Logged in user has no privilege to approve csr-s."; return 1; }
    # Create OpenShift project
    oc new-project "$project_name"
    # Generate private key
    openssl genrsa -out ./server-key.pem 2048
    # Create certificate signing request config template
    cat <<EOF > ./csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
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
    oc create -f - <<EOF
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
    "request": "$(base64 -w0 ./server.csr)",
    "usages": [
      "digital signature",
      "key encipherment",
      "server auth"
    ]
  }
}
EOF
    # Check if csr has been created
    oc get csr "$app_name" || { echo "Failed to create csr"; return 1; }
    # Approve csr
    oc adm certificate approve "$app_name" || { echo "Failed to approve certificate signing request"; return 1; }
    # Get certificate
    local try=1
    while [[ "$try" -le 3 ]]; do
        csrcert="$(base64 -d <<<$(oc get csr $app_name -o jsonpath='{.status.certificate}'))"
        openssl x509 <<<"$csrcert" -noout && { echo "$csrcert">./server-cert.pem; break; } || { sleep 1; let try++; }
    done
    [[ "$try" -le 3 ]] || { echo "Certificate is incorrect or was never issued."; return 1; }
    # Get the CA bundle
    ca_bundle=$(oc get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 -w0)
    # Create MutatingWebhookConfiguration in OpenShift
    oc create -f - <<EOF
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
    # Create imagestream
    oc create imagestream python-36-rhel7 ||
        { echo "Could not create imagestream"; return 1; }
    # Import the Python 3.6 S2I image
    oc import-image python-36-rhel7 --from=registry.access.redhat.com/rhscl/python-36-rhel7 ||
        { echo "Could not import image"; return 1; }
    # Create a new buildConfig for building the mutating webhook
    oc new-build --image-stream=python-36-rhel7 --to "$app_name" --binary=true ||
        { echo "Could not create imagestream or buildconfig"; return 1; }
    # Start the build and follow it
    oc start-build "$app_name" --from-dir=. -F ||
        { echo "Could not start build"; return 1; }
    # Process the template for creating deploymentConfig and service
    oc process -f ./openshift_template.yaml -p APP_NAME="$app_name" -p PROJECT_NAME="$project_name" | oc create -f - ||
        { echo "Could not process templates"; return 1; }
}

# Function for deleting files and OpenShift resources created by the script
ocp_purge() {
    print_delete
    handle_confirm || exit 1
    oc delete mutatingwebhookconfiguration "$app_name"-mwc || true
    oc delete project "$project_name" || true
    oc delete csr "$app_name" || true
    rm -fv ./csr.conf
    rm -fv ./server-key.pem
    rm -fv ./server-cert.pem
}

# Print the usage message
print_usage() {
    cat <<EOF
Usage: $0 COMMAND

Deploy a mutating admission controller on OpenShift

Commands:
  deploy              Create the files and deploy the OpenShift resources
  purge               Delete the files and OpenShift resources

Options:
  --project-name=nodeselector-mutator       OpenShift project where the resources should be deployed
  --app-name=nodeselector-mutator           Application name. Will apply to buildconfig, deploymentconfig, and service
  --confirm                                 Do not prompt for confirmation
  --help                                    Print usage
EOF
}

# Digest options
set_opts() {
    local deploy=false
    local purge=false

    [[ "$#" -gt 0 ]] || { print_usage; exit 1; }
    if [[ "$1" = "deploy" ]]; then
        deploy=true
    elif [[ "$1" = "purge" ]]; then
        purge=true
    else
        echo "Unknown command \"$1\""
        exit 1
    fi
    shift
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --app-name=*)
                app_name="${1#*=}"
                shift 1
                ;;
            --project-name=*)
                project_name="${1#*=}"
                shift 1
                ;;
            --confirm)
                auto_yes=true
                shift 1
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                echo "Wrong option \"$1\""
                print_usage
                exit 1
        esac
    done
    "$deploy" && ocp_deploy
    "$purge" && ocp_purge
}

handle_confirm() {
    if [[ "$auto_yes" != true ]]; then
        read -rp "Type \"y\" to continue... " answer
        if [[ "${answer,}" != "y" ]]; then
            echo "Cancelling deployment"
            return 1
        else
            return 0
        fi
    fi
}

print_delete() {
    cat <<EOF
This will delete the following resources:
    csr.conf
    server-key.pem
    server-cert.pem
    OpenShift project "$project_name"
    OpenShift mutatingwebhookconfiguration "${app_name}-mwc"
    OpenShift csr "$app_name"
EOF
}

# Set dir to script's
cd "$(dirname $0)" || exit
# Handle script commands and options
set_opts "$@"
