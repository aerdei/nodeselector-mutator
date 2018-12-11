"""
A Flask application to serve as a MutatingAdmissionWebhook webserver.
"""
import base64
import json
import logging

from flask import Flask, Response, request, Request

JSON_PATCH_ADD_BASE64 = base64.b64encode(
    json.dumps([{
        'op': 'add',
        'path': '/spec/template/spec/nodeSelector',
        'value': {
            'zone': 'internal'
        }
    }]).encode()).decode()
JSON_PATCH_REMOVE_BASE64 = base64.b64encode(
    json.dumps([{
        'op': 'remove',
        'path': '/spec/template/spec/nodeSelector/zone'
    }]).encode()).decode()
BAD_REQUEST_RESPONSE = Response(
    json.dumps({
        'message':
        "Request is not an AdmissionReviewRequest"
        "that the server can interpret."
    }),
    status=400,
    mimetype='application/json')


def _mutate(app, req: Request) -> Response:
    """Respond to AdmissionReviewRequests with a JSON patch
    to either remove or add zone:internal nodeSelector,
    based on the presence of emptyDir in the deploymentConfig."""
    try:
        req = json.loads(request.data)
    except json.decoder.JSONDecodeError:
        app.logger.error(
            "%s", "Received an invalid request. "
            "It is either not AdmissionReviewRequest, or it is invalid.")
        return BAD_REQUEST_RESPONSE
    app.logger.debug("Request:%s", json.dumps(req))
    if (req.get('request', {}).get('kind', {}).get('kind',
                                                   {}) == "DeploymentConfig"
            and 'uid' in req.get('request', {})
            and 'spec' in req.get('request', {}).get('object', {}).get(
                'spec', {}).get('template', {})):
        resp = {
            'kind': 'AdmissionReview',
            'apiVersion': 'admission.k8s.io/v1beta1',
            'response': {
                'uid': '',
                'allowed': True
            }
        }
        resp['response']['uid'] = req['request']['uid']
        spec = req['request']['object']['spec']['template']['spec']
        if (any('emptyDir' in item for item in spec.get('volumes', {})) and
                spec.get('nodeSelector', {}).get('zone', "") != "internal"):
            app.logger.info(
                "%s", "[" + req['request']['uid'] + "] " +
                "DeploymentConfig contains emptyDir, "
                "patching to add nodeSelector...")
            resp['response']['patchType'] = "JSONPatch"
            resp['response']['patch'] = JSON_PATCH_ADD_BASE64
        elif (not any('emptyDir' in item for item in spec.get('volumes', {}))
              and spec.get('nodeSelector', {}).get('zone', "") == "internal"):
            app.logger.info(
                "%s", "[" + req['request']['uid'] + "] " +
                "DeploymentConfig does not contain emptyDir, "
                "patching to remove nodeSelector...")
            resp['response']['patchType'] = "JSONPatch"
            resp['response']['patch'] = JSON_PATCH_REMOVE_BASE64
    else:
        app.logger.error(
            "%s", "Received an invalid request. "
            "It is either not AdmissionReviewRequest, or it is invalid.")
        return BAD_REQUEST_RESPONSE

    app.logger.debug("Response:%s", json.dumps(resp))
    return json.dumps(resp)


def build_mutator() -> Flask:
    """
    Build and return WSGI webserver
    """
    app = Flask(__name__)
    gunicorn_logger = logging.getLogger('gunicorn.error')
    app.logger.handlers = gunicorn_logger.handlers
    # pylint: disable=no-member
    app.logger.setLevel(gunicorn_logger.level)

    @app.route('/mutator', methods=['POST'])
    # pylint: disable=unused-variable
    def mutate():
        return _mutate(app, request)

    return app
