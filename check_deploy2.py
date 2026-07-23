"""Check deploy status with full details via SOAP API."""
import json, sys
sys.path.insert(0, '/opt/data/home/.hermes/salesforce')
from sf_auth import configure, get_access_token

with open('/opt/data/home/.hermes/salesforce/config.json') as f:
    cfg = json.load(f)
configure(cfg['client_id'], cfg['client_secret'], cfg['username'], cfg['instance_url'])
token = get_access_token()

at = token['access_token']
inst = token['instance_url']
deploy_id = '0AfPQ000001aC5J0AU'

import urllib.request

body = '<?xml version="1.0" encoding="UTF-8"?>'
body += '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"'
body += ' xmlns:met="http://soap.sforce.com/2006/04/metadata">'
body += '<soapenv:Header>'
body += '<met:SessionHeader><met:sessionId>' + at + '</met:sessionId></met:SessionHeader>'
body += '</soapenv:Header>'
body += '<soapenv:Body>'
body += '<met:checkDeployStatus>'
body += '<met:asyncProcessId>' + deploy_id + '</met:asyncProcessId>'
body += '<met:includeDetails>true</met:includeDetails>'
body += '</met:checkDeployStatus>'
body += '</soapenv:Body>'
body += '</soapenv:Envelope>'

soap_url = inst + '/services/Soap/m/62.0'
req = urllib.request.Request(
    soap_url,
    data=body.encode(),
    headers={
        'Content-Type': 'text/xml; charset=utf-8',
        'SOAPAction': '""',
    },
    method='POST'
)

try:
    with urllib.request.urlopen(req) as resp:
        xml_body = resp.read().decode()
        # Find test failures section
        idx = xml_body.find('runTestResult')
        if idx >= 0:
            print(xml_body[idx:idx+3000])
        else:
            print('No runTestResult found')
            # Last 2000 chars
            print('--- Last 2000 chars ---')
            print(xml_body[-2000:])
except urllib.error.HTTPError as e:
    print('HTTP Error:', e.code)
    print(e.read().decode()[:3000])