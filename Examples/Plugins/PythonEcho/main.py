import json
import sys

request = json.loads(sys.stdin.readline())
params = request["params"]
response = {
    "jsonrpc": "2.0",
    "id": request["id"],
    "result": f"Python: {params['commandID']} / {params['query']}",
}
print(json.dumps(response), flush=True)
