#!flask/bin/python
import os
import sys
import json
import uuid
import base64
from flask import Flask, request, Response, g

app = Flask(__name__)
app.debug = True

patchJSONadd = '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"zone":"internal"}}]'
patchAddBase64 = base64.b64encode(patchJSONadd.encode())
patchJSONremove = '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":""}]'
#patchJSONremove = '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{}}]'


@app.route('/mutator', methods=['GET', 'POST', 'PATCH'])
def index():
    responseJSON = json.loads(
        '{"kind": "AdmissionReview","apiVersion": "admission.k8s.io/v1beta1","response": {"uid": "","allowed": true,"patchType": "JSONPatch","patch":""}}')
    requestJSON = json.loads(request.data)
    responseJSON['response']['uid'] = requestJSON['request']['uid']
    spec = requestJSON['request']['object']['spec']['template']['spec']
    print("\n Request: \n", json.dumps(requestJSON), "\n")
    if (requestJSON['request']['kind']['kind'] == "DeploymentConfig" and
        "volumes" in spec and
            [item for item in spec['volumes'] if "emptyDir" in item]):
        if not ("nodeSelector" in spec and
                "zone" in spec['nodeSelector'] and
                "internal" == spec['nodeSelector']["zone"]):
            print (
                "DeploymentConfig contains emptyDir, patching to add nodeSelector...")
            responseJSON['response']['patch'] = patchAddBase64.decode()
    elif ("nodeSelector" in spec and
          "zone" in spec['nodeSelector'] and
          "internal" == spec['nodeSelector']["zone"]):
        print (
            "DeploymentConfig does not contain emptyDir, patching to remove nodeSelector...")
        requestNodeSelector = spec['nodeSelector']
        del requestNodeSelector['zone']
        patchJSONremoveLoads = json.loads(patchJSONremove)
        patchJSONremoveLoads[0]['value'] = requestNodeSelector
        print ("Patch: ", json.dumps(patchJSONremoveLoads))
        responseJSON['response']['patch'] = base64.b64encode(
            json.dumps(patchJSONremoveLoads).encode()).decode()
    print("\n Response: \n", json.dumps(responseJSON), "\n")
    return json.dumps(responseJSON)


if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', ssl_context=(
        'server-cert.pem', 'server-key.pem'))
