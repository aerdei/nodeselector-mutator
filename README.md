# Mutating Admission Controllers
## 1. Configuring OpenShift
Enable MutatingAdmissionWebhook in `/etc/origin/master/master-config.yaml`:
```
admissionConfig:  
   pluginConfig:  
     MutatingAdmissionWebhook:  
       configuration:  
         apiVersion: v1  
         disable: false  
         kind: DefaultAdmissionConfig
```
Define signing certificate and key in `/etc/origin/master/master-config.yaml`:
```
kubernetesMasterConfig:
  controllerArguments:
    cluster-signing-cert-file:
    - /etc/origin/master/ca.crt
    cluster-signing-key-file:
    - /etc/origin/master/ca.key
```
Restart the master(s) after modifying the configuration file(s).
## 2. Generating certificate and key:
 Create a certificate signing request configuration:
 ```
 cat <<EOF >> ./csr.conf
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
DNS.1 = nodeselector-mutator
DNS.2 = nodeselector-mutator.nodeselector-mutator
DNS.3 = nodeselector-mutator.nodeselector-mutator.svc
EOF
 ```
Generate RSA Private key:
```
openssl genrsa -out ./server-key.pem 2048
```
Create the certificate signing request:
```
openssl req -new -key ./server-key.pem -subj "/CN=nodeselector-mutator.nodeselector-mutator.svc" -out ${tmpdir}/server.csr -config ${tmpdir}/csr.conf
```
Create and send a certificateSigningRequest to OpenShift:
```
cat <<EOF | oc create -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: nodeselector-mutator-csr
spec:
  groups:
  - system:authenticated
  request: $(cat ./server.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF
```
Verify that the CertificateSigningRequest has been successfully created:
```
oc get csr
```
Approve the CertificateSigningRequest and verify it has been signed:
```
oc certificate approve nodeselector-mutator-csr
oc get csr
```
Get the certificate:
```
serverCert=$(oc get csr nodeselector-mutator-csr -o jsonpath='{.status.certificate}')
```
## 3. Set up the mutating admission controller webserver
Import the Python 3.6 S2I image:
``` 
oc import-image python-36-rhel7 --from=registry.access.redhat.com/rhscl/python-36-rhel7 --confirm
```
Create a new buildConfig:
```
oc new-build --image-stream=python-36-rhel7 --to nodeselector-mutator --binary=true
```
Start the S2I build with the certificate, key, app.py, and requirements.txt in the current folder:
``` 
oc start-build nodeselector-mutator --from-dir=.
```
Create a new DC:
```
oc new-app nodeselector-mutator
```
Change container port to 5000 in the deploymentConfig:
```
oc patch dc nodeselector-mutator --type=json -p '[{"op": "replace", "path": "/spec/template/spec/containers/0/ports", "value":[{"containerPort":5000,"protocol":"TCP"}]}]'
```
Change port to 443 and targetPort to 5000 on the Service:
```
oc patch svc nodeselector-mutator --type=json -p '[{"op": "replace", "path": "/spec/ports", "value":[{"name":"443-5000-tcp","port":443,"targetPort":5000,"protocol":"TCP"}]}]'
```

## References        

[https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionResponse](https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionResponse)

[https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionRequest](https://godoc.org/k8s.io/api/admission/v1beta1#AdmissionRequest)

[https://docs.okd.io/latest/rest_api/apis-admissionregistration.k8s.io/v1beta1.MutatingWebhookConfiguration.html](https://docs.okd.io/latest/rest_api/apis-admissionregistration.k8s.io/v1beta1.MutatingWebhookConfiguration.html)

https://tools.ietf.org/html/rfc6902#section-4.3

