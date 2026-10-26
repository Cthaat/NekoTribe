"""One-time source audit: parse the explicitly supplied upstream without importing it.

Writes an audit patch, never the authority or a sibling checkout. No models load,
training, filesystem cleanup, network calls or services run during this audit.
"""
import argparse
import ast
import copy
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--upstream-root', type=Path, required=True)
options = parser.parse_args()
upstream = options.upstream_root.resolve()
project = Path(__file__).resolve().parents[2]
authority = json.loads((project / 'doc/v2.openapi.json').read_text(encoding='utf-8'))
prefix = 'AuditedSentiment'
schemas = {}
null_only = {'type': 'object', 'nullable': True, 'enum': [None]}


def ref(name):
    return {'$ref': '#/components/schemas/' + prefix + name}


def shape(annotation):
    if isinstance(annotation, ast.Name):
        primitive = {'str': 'string', 'int': 'integer', 'float': 'number', 'bool': 'boolean'}
        if annotation.id in primitive:
            return {'type': primitive[annotation.id]}
        if annotation.id == 'Any':
            return {'description': 'Unconstrained JSON value: upstream explicitly declares typing.Any.'}
        return ref(annotation.id)
    if isinstance(annotation, ast.Constant) and annotation.value is None:
        return copy.deepcopy(null_only)
    if isinstance(annotation, ast.BinOp) and isinstance(annotation.op, ast.BitOr):
        if isinstance(annotation.right, ast.Constant) and annotation.right.value is None:
            value = shape(annotation.left)
            if 'type' in value:
                value['nullable'] = True
                if 'enum' in value:
                    value['enum'].append(None)
                return value
            return {'anyOf': [value, copy.deepcopy(null_only)]}
        return {'anyOf': [shape(annotation.left), shape(annotation.right)]}
    if isinstance(annotation, ast.Subscript) and isinstance(annotation.value, ast.Name):
        name = annotation.value.id
        arguments = list(annotation.slice.elts) if isinstance(annotation.slice, ast.Tuple) else [annotation.slice]
        if name == 'list':
            return {'type': 'array', 'items': shape(arguments[0])}
        if name == 'dict':
            if not isinstance(arguments[0], ast.Name) or arguments[0].id != 'str':
                raise ValueError('Only explicit JSON string-key dictionaries are supported')
            return {'type': 'object', 'additionalProperties': shape(arguments[1])}
        if name == 'Literal':
            values = [ast.literal_eval(argument) for argument in arguments]
            return {'type': 'string', 'enum': values}
    raise ValueError('Unsupported annotation: ' + ast.dump(annotation))


model_sources = {}
for relative in ['backend/app/schemas/predict.py', 'backend/app/schemas/training.py', 'backend/app/schemas/models.py']:
    source = (upstream / relative).read_text(encoding='utf-8')
    for model in ast.parse(source).body:
        if not isinstance(model, ast.ClassDef):
            continue
        properties, required = {}, []
        for field in model.body:
            if not isinstance(field, ast.AnnAssign) or not isinstance(field.target, ast.Name):
                continue
            schema = shape(field.annotation)
            is_required = field.value is None
            if isinstance(field.value, ast.Call):
                if not isinstance(field.value.func, ast.Name) or field.value.func.id != 'Field':
                    raise ValueError('Unknown model field constructor')
                is_required = any(isinstance(arg, ast.Constant) and arg.value is Ellipsis for arg in field.value.args)
                constraints = {'min_length': 'minLength', 'max_length': 'maxLength', 'ge': 'minimum', 'le': 'maximum', 'description': 'description'}
                for keyword in field.value.keywords:
                    if keyword.arg in constraints:
                        schema[constraints[keyword.arg]] = ast.literal_eval(keyword.value)
                    elif keyword.arg == 'default':
                        schema['default'] = ast.literal_eval(keyword.value)
            elif field.value is not None and not (isinstance(field.value, ast.Constant) and field.value.value is Ellipsis):
                schema['default'] = ast.literal_eval(field.value)
            elif isinstance(field.value, ast.Constant) and field.value.value is Ellipsis:
                is_required = True
            properties[field.target.id] = schema
            if is_required or model.name not in ['PredictRequest', 'TrainingStartRequest', 'SetActiveModelRequest']:
                required.append(field.target.id)
        result = {'type': 'object', 'properties': properties}
        if required:
            result['required'] = required
        if model.name in ['PredictRequest', 'TrainingStartRequest', 'SetActiveModelRequest']:
            result['description'] = 'Upstream Pydantic request fields; extra keys are ignored by the audited default model configuration.'
        else:
            result['description'] = 'Fields serialized by the upstream response model, including default/null fields. No Nuxt v2 wrapper is added.'
        schemas[prefix + model.name] = result
        model_sources[model.name] = relative

schemas[prefix + 'ValidationIssue'] = {
    'type': 'object', 'required': ['loc', 'msg', 'type'],
    'properties': {'loc': {'type': 'array', 'items': {'anyOf': [{'type': 'string'}, {'type': 'integer'}]}}, 'msg': {'type': 'string'}, 'type': {'type': 'string'}},
    'additionalProperties': True,
    'description': 'FastAPI/Pydantic validation issue. Version-dependent input/ctx fields may also be included.'
}
schemas[prefix + 'UpstreamError'] = {'type': 'object', 'required': ['detail'], 'properties': {'detail': {'anyOf': [{'type': 'string'}, {'type': 'array', 'items': ref('ValidationIssue')}]}}}
schemas[prefix + 'HttpError'] = {
    'type': 'object', 'required': ['error', 'url', 'statusCode', 'statusMessage', 'message'],
    'properties': {'error': {'type': 'boolean', 'enum': [True]}, 'url': {'type': 'string'}, 'statusCode': {'type': 'integer'}, 'statusMessage': {'type': 'string'}, 'message': {'type': 'string'}, 'data': {'type': 'object', 'required': ['code', 'message', 'data', 'meta'], 'properties': {'code': {'type': 'number'}, 'message': {'type': 'string'}, 'data': {'anyOf': [{'type': 'object', 'properties': {'detail': {'type': 'string'}}}, copy.deepcopy(null_only)]}, 'meta': copy.deepcopy(null_only)}}},
    'description': 'Nitro production JSON error transport. Proxy createError.data contains the v2 payload; unhandled/fatal errors omit data. Development may add stack fields.'
}
for name, message in [('LoginStub', 'login stub'), ('AdminUsersStub', 'admin users stub')]:
    schemas[prefix + name] = {'type': 'object', 'required': ['message'], 'properties': {'message': {'type': 'string', 'enum': [message]}}, 'description': 'Explicitly a stub at the pinned upstream commit; no login token or real user list is implemented.'}
schemas[prefix + 'OverviewStub'] = {'type': 'object', 'required': ['total_predictions', 'score_distribution', 'average_score'], 'properties': {'total_predictions': {'type': 'integer', 'enum': [0]}, 'score_distribution': {'type': 'object', 'required': [str(i) for i in range(6)], 'properties': {str(i): {'type': 'integer', 'enum': [0]} for i in range(6)}, 'additionalProperties': False}, 'average_score': copy.deepcopy(null_only)}, 'description': 'Pinned upstream static zero-valued statistics stub, not actual accumulated statistics.'}
for name, identifier in [('CancelResult', 'job_id'), ('DeleteResult', 'model_id')]:
    schemas[prefix + name] = {'type': 'object', 'required': ['ok', identifier], 'properties': {'ok': {'type': 'boolean', 'enum': [True]}, identifier: {'type': 'string'}}}

routes = [
    ('post', '/auth/login', 'LoginStub', None, 'auth.py', [], 'stub'),
    ('post', '/predict', 'PredictResponse', 'PredictRequest', 'predict.py', ['404', '422'], 'implemented'),
    ('post', '/training/start', 'TrainingStartResponse', 'TrainingStartRequest', 'training.py', ['400', '409', '422'], 'implemented'),
    ('get', '/training/status/{jobId}', 'TrainingStatusResponse', None, 'training.py', ['404'], 'implemented'),
    ('get', '/training/jobs', 'TrainingJobListResponse', None, 'training.py', [], 'implemented'),
    ('post', '/training/cancel/{jobId}', 'CancelResult', None, 'training.py', ['404'], 'implemented'),
    ('get', '/models', 'ModelListResponse', None, 'models.py', [], 'implemented'),
    ('get', '/models/active', 'ActiveModelResponse', None, 'models.py', [], 'implemented'),
    ('put', '/models/active', 'ActiveModelResponse', 'SetActiveModelRequest', 'models.py', ['400', '404', '422'], 'implemented'),
    ('delete', '/models/{modelId}', 'DeleteResult', None, 'models.py', ['400', '404'], 'implemented'),
    ('get', '/stats/overview', 'OverviewStub', None, 'stats.py', [], 'stub'),
    ('get', '/admin/users', 'AdminUsersStub', None, 'admin.py', [], 'stub'),
]
commit = subprocess.check_output(['git', '-c', 'safe.directory=' + upstream.as_posix(), '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
operations, evidence = [], []
for method, suffix, output, body, api, statuses, behavior in routes:
    path = '/api/v2/integrations/sentiment-flow' + suffix
    operation = copy.deepcopy(authority['paths'][path][method])
    del operation['x-schema-audit-status']
    relative = 'backend/app/api/' + api
    inputs = ['backend/app/main.py', relative]
    for model in [output, body]:
        if model in model_sources:
            inputs.append(model_sources[model])
    inputs = sorted(set(inputs))
    fingerprints = {source: hashlib.sha256((upstream / source).read_bytes()).hexdigest() for source in inputs}
    operation['x-contract-audit'] = {'status': 'source-audited', 'runtimeVerification': 'pending', 'sources': ['server/api/v2/integrations/sentiment-flow/[...path].ts', 'server/middleware/auth.ts'], 'upstream': {'repository': 'SentimentFlow', 'commit': commit, 'sourceSha256': fingerprints, 'behavior': behavior}}
    operation['description'] = 'Nuxt-authenticated transparent proxy to the explicitly audited SentimentFlow commit ' + commit + '. Success and upstream errors pass through without a v2 wrapper. Nuxt credentials are stripped before upstream forwarding. Body and query parameters not declared by the upstream are ignored. Trailing-slash redirects remain within the configured upstream base and are followed. Runtime compatibility with an arbitrary remote/latest upstream is not asserted.'
    if behavior == 'stub':
        operation['description'] += ' This upstream endpoint is a stub: ' + ('static zero statistics' if output == 'OverviewStub' else 'message only; no business data/token') + '.'
    if body:
        operation['requestBody'] = {'required': True, 'content': {'application/json': {'schema': ref(body)}}}
    else:
        operation.pop('requestBody', None)
    operation['responses'] = {
        '200': {'description': 'Pinned upstream response, not a Nuxt v2 envelope.', 'content': {'application/json': {'schema': ref(output)}}},
        '401': {'description': 'Nuxt session missing or invalid; request does not reach the upstream.', 'content': {'application/json': {'schema': ref('HttpError')}}},
        **{status: {'description': 'Pinned upstream HTTPException or Pydantic validation response.', 'content': {'application/json': {'schema': ref('UpstreamError')}}} for status in statuses},
        '500': {'description': 'Nuxt configuration/internal error, upstream HTTPException (including model deletion failures), or unhandled upstream exception.', 'content': {'application/json': {'schema': {'anyOf': [ref('HttpError'), ref('UpstreamError')]}}, 'text/plain': {'schema': {'type': 'string'}}}},
        **{status: {'description': text, 'content': {'application/json': {'schema': ref('HttpError')}}} for status, text in [('502', 'Upstream failure or rejected/too many redirects.'), ('503', 'Integration disabled.'), ('504', 'Upstream timed out.')]}
    }
    operation['responses']['400'] = {'description': 'Nuxt rejects an invalid proxy path before forwarding; selected upstream handlers can also reject business input.', 'content': {'application/json': {'schema': {'anyOf': [ref('HttpError'), ref('UpstreamError')]}}}}
    operations.append({'path': path, 'method': method, 'operation': operation})
    evidence.append({'path': path, 'method': method, 'sources': operation['x-contract-audit']['sources'], 'upstream': operation['x-contract-audit']['upstream'], 'notes': 'Source-only review; upstream dependencies are unpinned in its requirements, runtime/remote image still needs verification.'})

destination = Path(__file__).with_name('sentiment-flow.json')
destination.write_text(json.dumps({'operations': operations, 'schemas': schemas, 'evidence': evidence}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
print(json.dumps({'operations': len(operations), 'schemas': len(schemas), 'upstreamCommit': commit, 'output': str(destination)}))
