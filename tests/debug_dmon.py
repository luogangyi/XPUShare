
def parse_dmon(filename):
    data = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print("Error: dmon.log not found")
        return []

    for line in lines:
        line = line.strip()
        if line.startswith('#') or 'sm' in line:
            continue
        parts = line.split()
        if len(parts) < 2: continue
        
        # Format: gpu sm mem ...
        gpu_idx = parts[0]
        if gpu_idx != '0': continue
        
        try:
            sm_util = int(parts[1])
            data.append(sm_util)
        except (ValueError, IndexError):
            pass
    return data

data = parse_dmon('tests/dmon.log')
print(f"Total samples for GPU 0: {len(data)}")

# Calculate rolling average or blocks
window = 10
for i in range(0, len(data), window):
    chunk = data[i:i+window]
    if not chunk: continue
    avg = sum(chunk) / len(chunk)
    print(f"Time {i}-{i+len(chunk)}s: Avg={avg:.1f}% | Values={chunk}")

# Try to match the test phases
# The test expects: 
# Phase 1 (Init): 100%
# Phase 2 (30% limit): ~30%
# Phase 3 (80% limit): ~80%
# Phase 4 (No limit): 100%

print("\nAnalysis:")
# Heuristic-based phase detection or just fixed windows based on known script timing
# Script: 10s wait, 30s (30%), 10s wait, 30s (80%), 10s wait, 10s (100%)
# Total ~100s.
# 
if len(data) >= 90:
    # Phase 1: 30% limit (approx 15s to 45s)
    p2 = data[15:45]
    print(f"Phase 30% (Samples 15-45): Avg = {sum(p2)/len(p2):.1f}%")
    
    # Phase 2: 80% limit (approx 55s to 85s)
    p3 = data[55:85]
    print(f"Phase 80% (Samples 55-85): Avg = {sum(p3)/len(p3):.1f}%")

