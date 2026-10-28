import urllib.request
import json

token = "ghp_9d3BW6AEsU8qcREPPUX8pE8i5UQIYY3T7Fnx"
run_id = 40733562736
job_id = 122975988233

# Get logs for the failed job
req = urllib.request.Request(
    'https://api.github.com/repos/kartikgargas-code/myiosAlarm/actions/jobs/{}/logs'.format(job_id),
    headers={'Accept': 'application/vnd.github+json', 'Authorization': 'Bearer {}'.format(token)}
)
with urllib.request.urlopen(req) as response:
    logs = response.read().decode('utf-8')
    # Print last 300 lines
    lines = logs.split('\n')
    for line in lines[-300:]:
        print(line)