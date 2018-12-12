#!/bin/bash

PROJECT_NAME=${PROJECT_NAME:-"nodeselector-mutator"}
APP_NAME=${APP_NAME:-"nodeselector-mutator"}
SVC_NAME=${SVC_NAME:-$APP_NAME}
CSR_NAME=${CSR_NAME:-$APP_NAME}

pre_flight_check()
{
    oc new-project "$PROJECT_NAME"
    for resource in "bc" "dc" "csr"; do 
        test "$(oc auth can-i create $resource 2>&1 | head -n1 | awk '{print $1;}')" = "yes" ||
            { echo "Logged in user has no provilege to create $resource-s."; return 1; }
    done
    test "$(oc auth can-i approve csr 2>&1 | head -n1 | awk '{print $1;}')" = "yes" ||
        { echo "Logged in user has no provilege to approve csr-s."; return 1; }
    return 0
}

prepare_csr()
{
    {
        openssl genrsa -out ./server-key.pem 2048
    } ||
        echo "Cloud not create csr.conf template"
        return 1
    {
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
            DNS.1 = $SVC_NAME
            DNS.2 = $SVC_NAME.$PROJECT_NAME
            DNS.3 = $SVC_NAME.$PROJECT_NAME.svc
EOF
    } ||
    {
        echo "Cloud not create csr.conf template"
        return 1
    }
    openssl req -new -key ./server-key.pem -subj "/CN=$SVC_NAME.$PROJECT_NAME.svc" -out ./server.csr -config ./csr.conf
    {
        cat <<-EOF | oc create -f -
            apiVersion: certificates.k8s.io/v1beta1
            kind: CertificateSigningRequest
            metadata:
            name: $CSR_NAME
            spec:
            groups:
            - system:authenticated
            request: $(base64 ./server.csr | tr -d '\n')
            usages:
            - digital signature
            - key encipherment
            - server auth
EOF
    } ||
    {
        echo "Cloud not create server.csr"
        return 1
    }
    test -z "$(oc get csr "$CSR_NAME" 2>&1 | grep 'Error')" || { echo "Failed to create csr"; return 1;}
    test -z "$(oc adm certificate approve nodeselector-mutator-csr 2>&1| grep 'approved')" || { echo "Failed to approve csr"; return 1; }
    sleep 3
    test -z "$(oc get csr | grep nodeselector-mutator-csr | grep 'Issued')" || { echo "Csr was never issued."; return 1; }
    return 0
}

setup_mwc()
{
    {
        local  ca_bundle
        ca_bundle=$(oc get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 | tr -d '\n')
        cat <<EOF | oc create -f -
            apiVersion: admissionregistration.k8s.io/v1beta1
            kind: MutatingWebhookConfiguration
            metadata:
            name: $APP_NAME-mwc
            labels:
                app: $APP_NAME
            webhooks:
            - name: $APP_NAME.openshift.com
                clientConfig:
                service:
                    name: $SVC_NAME
                    namespace: $PROJECT_NAME
                    path: "/mutator"
                caBundle: $ca_bundle
                rules:
                - operations: [ "CREATE", "UPDATE" ]
                    apiGroups: ["*"]
                    apiVersions: ["v1"]
                    resources: ["deploymentconfigs"]
EOF
    } ||
    {
        echo "Cloud not create MutatingWebhookConfiguration"
        return 1
    }
}

setup_build()
{
    test -z "$(oc import-image python-36-rhel7 --from=registry.access.redhat.com/rhscl/python-36-rhel7 --confirm | grep 'The import completed successfully.')" ||
        { echo "Could not import image"; return 1; }
    test -z "$(oc new-build --image-stream=python-36-rhel7 --to "$APP_NAME" --binary=true | grep 'Success')" ||
        { echo "Could create imagestream or buildconfig"; return 1; }
    oc start-build nodeselector-mutator --from-dir=. -F
}

rollout_app()
{
    oc process -f ./openshift_template.yaml -p APP_NAME="$APP_NAME" PROJECT_NAME="$PROJECT_NAME" SVC_NAME="$SVC_NAME" | oc create -f -
}

cd "$(dirname "$0")" || exit
pre_flight_check
prepare_csr
setup_mwc
setup_build
rollout_app
