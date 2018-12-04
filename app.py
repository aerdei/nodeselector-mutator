"""
A Flask application to serve as a MutatingAdmissionWebhook webserver.
"""
import json
import base64
import logging
from flask import Flask, request

APP = Flask(__name__)
APP.debug = True 

LOGGER = logging.getLogger('mutator_logger')
LOGGER.setLevel(logging.INFO)
CH = logging.StreamHandler()
CH.setLevel(logging.DEBUG)
FORMATTER = logging.Formatter(
    '%(asctime)s - %(name)s -'
    ' %(levelname)s - %(message)s')
CH.setFormatter(FORMATTER)
LOGGER.addHandler(CH)

ADMISSION_REVIEW_RESPONSE_STRING = (
    '{'
    ' "kind": "AdmissionReview",'
    '  "apiVersion": "admission.k8s.io/v1beta1",'
    '  "response": {'
    '    "uid": "",'
    '    "allowed": true,'
    '    "patchType": "JSONPatch",'
    '    "patch": ""'
    '  }'
    '}')
JSON_PATCH_ADD_STRING = (
    '['
    '  {'
    '    "op": "add",'
    '    "path": "/spec/template/spec/nodeSelector",'
    '    "value": {'
    '      "zone": "internal"'
    '    }'
    '  }'
    ']')
JSON_PATCH_ADD_BASE64 = base64.b64encode(JSON_PATCH_ADD_STRING.encode())
JSON_PATCH_REMOVE_STRING = (
    '['
    '  {'
    '    "op": "remove",'
    '    "path": "/spec/template/spec/nodeSelector/zone"'
    '  }'
    ']')
JSON_PATCH_REMOVE_BASE64 = base64.b64encode(JSON_PATCH_REMOVE_STRING.encode())


@APP.route('/mutator', methods=['GET', 'POST'])
def index():
    """Respond to AdmissionReviewRequests with a JSON patch
    to either remove or add zone:internal nodeSelector,
    based on the presence of emptyDir in the deploymentConfig. """

    resp_json = json.loads(ADMISSION_REVIEW_RESPONSE_STRING)
    req_json = json.loads(request.data)
    resp_json['response']['uid'] = req_json['request']['uid']
    spec = req_json['request']['object']['spec']['template']['spec']
    LOGGER.debug("\n Request:\n%s", json.dumps(req_json))
    if (req_json['request']['kind']['kind'] == "DeploymentConfig" and
            "volumes" in spec and
            [item for item in spec['volumes'] if "emptyDir" in item]):
        if not ("nodeSelector" in spec and
                "zone" in spec['nodeSelector'] and
                spec['nodeSelector']["zone"] == "internal"):
            LOGGER.info("[%s] DeploymentConfig %s",req_json['request']['uid'],
                         "contains emptyDir,"
                         "patching to add nodeSelector...")
            resp_json['response']['patch'] = JSON_PATCH_ADD_BASE64.decode(
            )
    elif ("nodeSelector" in spec and
          "zone" in spec['nodeSelector'] and
          spec['nodeSelector']["zone"] == "internal"):
        LOGGER.info("[%s] DeploymentConfig %s",req_json['request']['uid'],
                     "does not contain emptyDir,"
                     "patching to remove nodeSelector...")
        resp_json['response']['patch'] = JSON_PATCH_REMOVE_BASE64.decode(
        )
    LOGGER.debug("Response:\n%s", json.dumps(resp_json))
    return json.dumps(resp_json)


if __name__ == '__main__':
    APP.run(debug=True, host='0.0.0.0', ssl_context=(
        'server-cert.pem', 'server-key.pem'))
