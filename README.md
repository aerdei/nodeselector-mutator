# Mutating Admission Controllers

## Prerequisites

### Configuring OpenShift

Enable MutatingAdmissionWebhook in `/etc/origin/master/master-config.yaml`:

```yaml
admissionConfig:  
  pluginConfig:  
    MutatingAdmissionWebhook:  
      configuration:  
        apiVersion: v1  
        disable: false  
        kind: DefaultAdmissionConfig
```

Define signing certificate and key in `/etc/origin/master/master-config.yaml`:

```yaml
kubernetesMasterConfig:
  controllerArguments:
    cluster-signing-cert-file:
    - /etc/origin/master/ca.crt
    cluster-signing-key-file:
    - /etc/origin/master/ca.key
```

Restart the master(s) after modifying the configuration file(s).

## Automated deployment

For automated deployment, use "deploy.sh".

## Manual deployment

### 1. Generating certificate and key

 Create a certificate signing request configuration:

```yaml
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
DNS.1 = nodeselector-mutator
DNS.2 = nodeselector-mutator.nodeselector-mutator
DNS.3 = nodeselector-mutator.nodeselector-mutator.svc
EOF
```

Generate RSA Private key:

```bash
openssl genrsa -out ./server-key.pem 2048
```

Create the certificate signing request:

```bash
openssl req -new -key ./server-key.pem -subj "/CN=nodeselector-mutator.nodeselector-mutator.svc" -out ./server.csr -config ./csr.conf

```

Create and send a certificateSigningRequest to OpenShift:

```yaml
oc create -f - <<EOF
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: nodeselector-mutator-csr
spec:
  groups:
  - system:authenticated
  request: $(cat ./server.csr | base64 -w0)
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF
```

Verify that the CertificateSigningRequest has been successfully created:

```bash
oc get csr
```

Approve the CertificateSigningRequest and verify it has been signed:

```bash
oc adm certificate approve nodeselector-mutator-csr
oc get csr
```

Get the certificate:

```bash
oc get csr nodeselector-mutator-csr -o jsonpath='{.status.certificate}' | openssl base64 -d -A -out ./server-cert.pem
```

### 2. Set up the mutating admission controller configuration and webserver

Export the CA bundle so we can easily inject it in our next step:

```bash
export CA_BUNDLE=$(oc get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 -w0)
```

Create the MutatingWebhookConfiguration:

```yaml
oc create -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1beta1
kind: MutatingWebhookConfiguration
metadata:
  name: nodeselector-mutator-mwc
  labels:
    app: nodeselector-mutator
webhooks:
  - name: nodeselector-mutator.openshift.com
    clientConfig:
      service:
        name: nodeselector-mutator
        namespace: nodeselector-mutator
        path: "/mutator"
      caBundle: ${CA_BUNDLE}
    rules:
      - operations: [ "CREATE", "UPDATE" ]
        apiGroups: ["*"]
        apiVersions: ["v1"]
        resources: ["deploymentconfigs"]
EOF
```

Import the Python 3.6 S2I image:

``` bash
oc import-image python-36-rhel7 --from=registry.access.redhat.com/rhscl/python-36-rhel7 --confirm
```

Create a new buildConfig:

```bash
oc new-build --image-stream=python-36-rhel7 --to nodeselector-mutator --binary=true
```

Start the S2I build with the certificate, key, app.py, and requirements.txt in the current folder:

``` bash
oc start-build nodeselector-mutator --from-dir=. -F
```

Create a new DC:

```bash
oc new-app nodeselector-mutator
```

Change container port to 5000 in the deploymentConfig:

```bash
oc patch dc nodeselector-mutator --type=json -p '[{"op": "replace", "path": "/spec/template/spec/containers/0/ports", "value":[{"containerPort":5000,"protocol":"TCP"}]}]'
```

Change port to 443 and targetPort to 5000 on the Service:

```bash
oc patch svc nodeselector-mutator --type=json -p '[{"op": "replace", "path": "/spec/ports", "value":[{"name":"443-5000-tcp","port":443,"targetPort":5000,"protocol":"TCP"}]}]'
```

## References

[https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionResponse](https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionResponse)

[https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionRequest](https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionRequest)

[https://docs.okd.io/latest/rest_api/apis-admissionregistration.k8s.io/v1beta1.MutatingWebhookConfiguration.html](https://docs.okd.io/latest/rest_api/apis-admissionregistration.k8s.io/v1beta1.MutatingWebhookConfiguration.html)

[https://tools.ietf.org/html/rfc6902](https://tools.ietf.org/html/rfc6902)

[https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG-1.10.md#other-notable-changes-6](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG-1.10.md#other-notable-changes-6)

[https://github.com/kubernetes/kubernetes/pull/64971](https://github.com/kubernetes/kubernetes/pull/64971)
