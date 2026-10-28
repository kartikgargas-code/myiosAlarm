import urllib.request
import json

token = "ghp_9d3BW6AEsU8qcREPPUX8pE8i5UQIYY3T7Fnx"
req = urllib.request.Request(
    'https://api.github.com/repos/kartikgargas-code/myiosAlarm/actions/runs?branch=phase1-validation&per_page=5',
    headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json'}
)
with urllib.request.urlopen(req) as response:
    data = json.load(response)
    for r in data['workflow_runs']:
        print('Run {}: {} - {}'.format(r["run_number"], r["conclusion"] or r["status"], r["head_commit"]["message"][:80]))