import urllib.request, json
try:
    req = urllib.request.Request('https://api.github.com/repos/kartikgargas-code/myiosAlarm/actions/runs?branch=phase1-validation&per_page=10')
    with urllib.request.urlopen(req) as response:
        data = json.load(response)
        for r in data['workflow_runs']:
            run_num = r['run_number']
            conclusion = r['conclusion'] or 'in_progress'
            name = r['name']
            commit = r['head_commit']['id'][:7]
            created = r['created_at']
            print(f'Run #{run_num}: {conclusion} - {name} - {commit} - {created}')
except Exception as e:
    print(f'Error: {e}')